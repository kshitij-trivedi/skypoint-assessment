-- =====================================================================
-- 4. JSON redemption feed -> flattened, queryable table
-- One RAW row = one member document with an array of redemptions. LATERAL FLATTEN explodes it to
-- one row per transaction. Latest feed_date wins per txn_id (PENDING -> COMPLETED arrives later).
-- =====================================================================
CREATE OR REPLACE PROCEDURE OPS.SP_LOAD_REDEMPTIONS()
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE v_in NUMBER; v_ok NUMBER; v_bad NUMBER; v_run_ts TIMESTAMP_NTZ;
BEGIN
  v_run_ts := CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
  BEGIN TRANSACTION;

  -- The INSERT (DML) consumes the stream; this run's rows are then read back by stg_load_ts.
  INSERT INTO STG.STG_REDEMPTION
    (member_id, feed_date, txn_id, txn_date, partner, miles_redeemed, status, errors, src_file_name, src_row_number,
     payload, txn, stg_load_ts)
  WITH flat AS (
  SELECT
    -- Native flat-file ids join as-is. Feeds with local counter ids (Excel: AUS-1, IND-1) send source_country,
    -- so the key is namespaced exactly like the profile side (see 01b_excel_feeds.sql).
    IFF(NULLIF(TRIM(r.payload:member_id::STRING),'') IS NULL, NULL,
        IFF(NULLIF(TRIM(r.payload:source_country::STRING),'') IS NULL,
            TRIM(r.payload:member_id::STRING),
            UPPER(TRIM(r.payload:source_country::STRING)) || '-' || TRIM(r.payload:member_id::STRING))) AS member_id,
    TRY_TO_DATE(r.payload:feed_date::STRING, 'YYYYMMDD')                  AS feed_date,
    r.payload:feed_date::STRING                                           AS raw_feed_date,
    NULLIF(TRIM(f.value:txn_id::STRING),'')                               AS txn_id,
    TRY_TO_DATE(f.value:txn_date::STRING, 'YYYYMMDD')                     AS txn_date,
    f.value:txn_date::STRING                                              AS raw_txn_date,
    f.value:partner::STRING                                               AS partner,
    TRY_TO_NUMBER(f.value:miles_redeemed::STRING, 38, 2)                  AS miles_redeemed,   -- scale 2: 12.5 must fail, not round
    f.value:miles_redeemed::STRING                                        AS raw_miles,
    UPPER(f.value:status::STRING)                                         AS status,
    r.src_file_name, r.src_row_number, r.payload AS payload, f.value AS txn
  FROM RAW.STRM_REDEMPTION_FEED r,
       LATERAL FLATTEN(INPUT => r.payload:redemptions, OUTER => FALSE) f    -- members with [] simply yield no rows
  ),
  checked AS (
  SELECT t.*, ARRAY_CONSTRUCT_COMPACT(
      IFF(member_id IS NULL,                                              'E_MANDATORY_MEMBER_ID', NULL),
      IFF(txn_id IS NULL,                                                 'E_MANDATORY_TXN_ID', NULL),
      IFF(raw_feed_date IS NOT NULL AND feed_date IS NULL OR raw_feed_date IS NULL, 'E_INVALID_FEED_DATE', NULL),
      IFF(raw_txn_date IS NOT NULL AND txn_date IS NULL,                  'E_INVALID_TXN_DATE', NULL),
      IFF(miles_redeemed IS NULL OR miles_redeemed <= 0 OR miles_redeemed <> FLOOR(miles_redeemed)
          OR miles_redeemed >= 1e12,                                      'E_INVALID_MILES', NULL),   -- fact is NUMBER(12,0)
      IFF(LENGTH(member_id) > 18 OR LENGTH(txn_id) > 50 OR LENGTH(partner) > 100, 'E_LENGTH_EXCEEDED', NULL),
      IFF(status IS NULL OR status NOT IN ('COMPLETED','PENDING','CANCELLED','REVERSED'), 'E_UNKNOWN_STATUS', NULL),
      IFF(txn_date > feed_date,                                           'E_TXN_AFTER_FEED_DATE', NULL)
    ) AS errors
  FROM flat t
  )
  SELECT member_id, feed_date, txn_id, txn_date, partner, miles_redeemed, status, errors, src_file_name, src_row_number,
         payload, txn, :v_run_ts
  FROM checked;

  INSERT INTO DQ.DQ_REJECT_REDEMPTION (payload, txn, error_codes, src_file_name, src_row_number)
    SELECT payload, txn, errors, src_file_name, src_row_number
    FROM STG.STG_REDEMPTION WHERE stg_load_ts = :v_run_ts AND ARRAY_SIZE(errors) > 0;

  MERGE INTO CORE.FACT_REDEMPTION t USING (
      SELECT * FROM STG.STG_REDEMPTION WHERE stg_load_ts = :v_run_ts AND ARRAY_SIZE(errors) = 0
      QUALIFY ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY feed_date DESC, src_file_name DESC, src_row_number DESC) = 1
  ) s ON t.txn_id = s.txn_id
  WHEN MATCHED AND s.feed_date >= t.feed_date THEN UPDATE SET
       member_id=s.member_id, txn_date=s.txn_date, partner=s.partner, miles_redeemed=s.miles_redeemed,
       status=s.status, feed_date=s.feed_date, src_file_name=s.src_file_name, src_row_number=s.src_row_number,
       updated_ts=CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (txn_id, member_id, txn_date, partner, miles_redeemed, status, feed_date, src_file_name, src_row_number)
       VALUES (s.txn_id, s.member_id, s.txn_date, s.partner, s.miles_redeemed, s.status, s.feed_date, s.src_file_name, s.src_row_number);

  SELECT COUNT(*), COUNT_IF(ARRAY_SIZE(errors)=0), COUNT_IF(ARRAY_SIZE(errors)>0) INTO :v_in, :v_ok, :v_bad
    FROM STG.STG_REDEMPTION WHERE stg_load_ts = :v_run_ts;
  INSERT INTO OPS.PIPELINE_RUN_LOG (step, metrics) SELECT 'redemptions', OBJECT_CONSTRUCT('txns', :v_in, 'loaded', :v_ok, 'rejected', :v_bad);
  COMMIT;
  RETURN OBJECT_CONSTRUCT('txns', v_in, 'loaded', v_ok, 'rejected', v_bad);
END;
$$;

-- ---------------------------------------------------------------------
-- Joining back to member profile
--   * Join key = member_id (same VARCHAR type, trimmed on both sides). Never join on name (name is not unique).
--   * Go through the registry to get the member's CURRENT country, then to V_MEMBER_ALL for attributes.
--   * LEFT JOIN: a redemption may arrive before the profile (or for a quarantined profile) - keep it, flag orphan.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW CORE.V_REDEMPTION_ENRICHED AS
SELECT f.txn_id, f.txn_date, f.partner, f.miles_redeemed, f.status, f.feed_date,
       f.member_id, m.member_name, m.tier_code, m.country_code, m.state, m.is_active,
       (m.member_id IS NULL) AS is_orphan
FROM CORE.FACT_REDEMPTION f
LEFT JOIN CORE.MEMBER_CURRENT_COUNTRY r ON r.member_id = f.member_id
LEFT JOIN CORE.V_MEMBER_ALL m           ON m.member_id = r.member_id AND m.country_code = r.country_code;

-- Example: completed miles redeemed per country / tier in the last 90 days
-- SELECT country_code, tier_code, SUM(miles_redeemed) FROM CORE.V_REDEMPTION_ENRICHED
-- WHERE status='COMPLETED' AND txn_date >= DATEADD('day',-90,CURRENT_DATE()) GROUP BY ALL;
