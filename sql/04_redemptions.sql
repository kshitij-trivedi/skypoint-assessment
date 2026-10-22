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
DECLARE v_in NUMBER; v_ok NUMBER; v_bad NUMBER;
BEGIN
  -- This run's valid rows, for the MERGE below. Created BEFORE the transaction: DDL inside BEGIN..COMMIT would
  -- commit implicitly. It holds one run only, so the MERGE never scans STG_REDEMPTION (which is clustered on
  -- load date, not on anything a run could filter by cheaply).
  CREATE OR REPLACE TEMPORARY TABLE STG.TMP_REDEMPTION_OK LIKE STG.STG_REDEMPTION;
  BEGIN TRANSACTION;

  -- One pass over the stream writes all three targets. A multi-table INSERT is DML, so reading the stream here
  -- consumes it when the transaction commits (exactly-once); a failure rolls back all three together.
  -- payload/txn (the whole member document) go only to the quarantine, where they are needed for replay;
  -- STG_REDEMPTION no longer repeats the document on every transaction row.
  -- Subqueries instead of a WITH clause: the multi-table INSERT documentation shows a plain subquery.
  INSERT ALL
    WHEN 1 = 1 THEN INTO STG.STG_REDEMPTION
         (member_id, feed_date, txn_id, txn_date, partner, miles_redeemed, status, errors, src_file_name, src_row_number)
         VALUES (member_id, feed_date, txn_id, txn_date, partner, miles_redeemed, status, errors, src_file_name, src_row_number)
    WHEN ARRAY_SIZE(errors) > 0 THEN INTO DQ.DQ_REJECT_REDEMPTION (payload, txn, error_codes, src_file_name, src_row_number)
         VALUES (payload, txn, errors, src_file_name, src_row_number)
    WHEN ARRAY_SIZE(errors) = 0 THEN INTO STG.TMP_REDEMPTION_OK
         (member_id, feed_date, txn_id, txn_date, partner, miles_redeemed, status, errors, src_file_name, src_row_number)
         VALUES (member_id, feed_date, txn_id, txn_date, partner, miles_redeemed, status, errors, src_file_name, src_row_number)
  SELECT member_id, feed_date, txn_id, txn_date, partner, miles_redeemed, status, errors, src_file_name, src_row_number,
         payload, txn
  FROM (
  SELECT t.*, ARRAY_CONSTRUCT_COMPACT(
      IFF(member_id IS NULL,                                              'E_MANDATORY_MEMBER_ID', NULL),
      IFF(txn_id IS NULL,                                                 'E_MANDATORY_TXN_ID', NULL),
      IFF(raw_feed_date IS NOT NULL AND feed_date IS NULL OR raw_feed_date IS NULL, 'E_INVALID_FEED_DATE', NULL),
      IFF(raw_txn_date IS NOT NULL AND txn_date IS NULL,                  'E_INVALID_TXN_DATE', NULL),
      IFF(miles_redeemed IS NULL,                                         'E_INVALID_MILES', NULL),   -- fact is NUMBER(12,0)
      IFF(LENGTH(member_id) > 18 OR LENGTH(txn_id) > 50 OR LENGTH(partner) > 100, 'E_LENGTH_EXCEEDED', NULL),
      IFF(status IS NULL OR status NOT IN ('COMPLETED','PENDING','CANCELLED','REVERSED'), 'E_UNKNOWN_STATUS', NULL),
      IFF(txn_date > feed_date,                                           'E_TXN_AFTER_FEED_DATE', NULL)
    ) AS errors
  FROM (
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
    -- Checked on the text, then cast: a positive whole number of at most 12 digits with no sign, leading zero or
    -- decimal point. Rejects 12.0, 12.5, 12.001, -5, 0, 012 and 1000000000000, exactly like skypoints MILES_PATTERN.
    -- (TRY_TO_NUMBER(..., 38, 2) rounded 12.001 to 12.00 and accepted 12.0.)
    -- Not verified on Snowflake: how VARIANT renders a JSON 12.0 as STRING. If it renders '12', that value would be
    -- accepted here while Python rejects it; check with SELECT PARSE_JSON('{"m":12.0}'):m::STRING.
    IFF(REGEXP_LIKE(TRIM(f.value:miles_redeemed::STRING), '[1-9][0-9]{0,11}'),
        TRIM(f.value:miles_redeemed::STRING)::NUMBER(12,0), NULL)          AS miles_redeemed,
    f.value:miles_redeemed::STRING                                        AS raw_miles,
    UPPER(f.value:status::STRING)                                         AS status,
    r.src_file_name, r.src_row_number, r.payload AS payload, f.value AS txn
  FROM RAW.STRM_REDEMPTION_FEED r,
       LATERAL FLATTEN(INPUT => r.payload:redemptions, OUTER => FALSE) f    -- members with [] simply yield no rows
  ) t
  ) checked;

  -- Counts come from the INSERT's own result (one column per INTO clause, in clause order), not from re-reading
  -- the targets: $1 = rows into STG_REDEMPTION, $2 = rejected, $3 = valid.
  SELECT $1, $2, $3 INTO :v_in, :v_bad, :v_ok FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  MERGE INTO CORE.FACT_REDEMPTION t USING (
      SELECT * FROM STG.TMP_REDEMPTION_OK
      QUALIFY ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY feed_date DESC, src_file_name DESC, src_row_number DESC) = 1
  ) s ON t.txn_id = s.txn_id
  WHEN MATCHED AND s.feed_date >= t.feed_date THEN UPDATE SET
       member_id=s.member_id, txn_date=s.txn_date, partner=s.partner, miles_redeemed=s.miles_redeemed,
       status=s.status, feed_date=s.feed_date, src_file_name=s.src_file_name, src_row_number=s.src_row_number,
       updated_ts=CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (txn_id, member_id, txn_date, partner, miles_redeemed, status, feed_date, src_file_name, src_row_number)
       VALUES (s.txn_id, s.member_id, s.txn_date, s.partner, s.miles_redeemed, s.status, s.feed_date, s.src_file_name, s.src_row_number);

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
