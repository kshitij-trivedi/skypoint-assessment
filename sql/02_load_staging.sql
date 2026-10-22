-- =====================================================================
-- 2. RAW -> STG : type, standardise, derive Age + Stale_Member, evaluate DQ rules
-- Business date is a parameter (not CURRENT_DATE) so reruns/backfills are reproducible.
--   SET BUSINESS_DATE = '2024-01-15'::DATE;
-- Exactly-once: the stream offset only advances when a DML statement reads it and the transaction commits,
-- so the stream is read by the INSERT itself (a CTAS/temp table would NOT consume it, and DDL inside an
-- explicit transaction implicitly commits it). One multi-table INSERT writes STG and the quarantine in a single
-- pass, so this run's rows are never read back from STG (stg_load_ts is not the clustering key).
-- Read inside-out: p = parsed from the stream, e = enriched with reference data and derived columns,
-- typed = rule outcomes. (Subqueries instead of a WITH clause: the multi-table INSERT documentation shows a
-- plain subquery.)
-- =====================================================================
CREATE OR REPLACE PROCEDURE OPS.SP_LOAD_STG_MEMBER(P_BUSINESS_DATE DATE)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
  v_rows NUMBER; v_valid NUMBER; v_rejected NUMBER;
BEGIN
  BEGIN TRANSACTION;

  INSERT ALL
    WHEN 1 = 1 THEN INTO STG.STG_MEMBER
      (member_name, member_id, enrollment_date, last_flight_date, tier_code, agent_name, state, country_raw, country_code,
       post_code, member_type, dob, is_active, age, days_since_flight, stale_member, batch_ts, src_file_name,
       src_row_number, dq_status, dq_errors, dq_warnings)
      VALUES (member_name, member_id, enrollment_date, last_flight_date, tier_code, agent_name, state, country_raw, country_code,
       post_code, member_type, dob, is_active, age, days_since_flight, stale_member, batch_ts, src_file_name,
       src_row_number, dq_status, dq_errors, dq_warnings)
    -- Bad rows -> quarantine as well (nothing is silently dropped). Same shape: DQ_REJECT_MEMBER is LIKE STG_MEMBER.
    WHEN dq_status = 'REJECTED' THEN INTO DQ.DQ_REJECT_MEMBER
      (member_name, member_id, enrollment_date, last_flight_date, tier_code, agent_name, state, country_raw, country_code,
       post_code, member_type, dob, is_active, age, days_since_flight, stale_member, batch_ts, src_file_name,
       src_row_number, dq_status, dq_errors, dq_warnings)
      VALUES (member_name, member_id, enrollment_date, last_flight_date, tier_code, agent_name, state, country_raw, country_code,
       post_code, member_type, dob, is_active, age, days_since_flight, stale_member, batch_ts, src_file_name,
       src_row_number, dq_status, dq_errors, dq_warnings)
  SELECT member_name, member_id, enrollment_date, last_flight_date, tier_code, agent_name, state, country_raw, country_code,
         post_code, member_type, dob, is_active, age, days_since_flight, stale_member, batch_ts, src_file_name,
         src_row_number, IFF(ARRAY_SIZE(dq_errors) = 0, 'VALID', 'REJECTED') AS dq_status, dq_errors, dq_warnings
  FROM (
  SELECT e.*,
    -- stale = more than 90 days since last flight; NULL flight date => treated as stale (never flown / unknown)
    COALESCE(e.days_since_flight > 90, TRUE) AS stale_member,
    -- ---- blocking rules (row is quarantined) --------------------------------------------------------
    ARRAY_CONSTRUCT_COMPACT(
      IFF(e.member_name IS NULL,                                        'E_MANDATORY_MEMBER_NAME', NULL),
      IFF(e.member_id   IS NULL,                                        'E_MANDATORY_MEMBER_ID',   NULL),
      IFF(e.raw_enroll IS NULL OR TRIM(e.raw_enroll) = '',              'E_MANDATORY_ENROLLMENT_DATE', NULL),
      IFF(NULLIF(TRIM(e.raw_enroll),'') IS NOT NULL AND e.enrollment_date IS NULL, 'E_INVALID_ENROLLMENT_DATE', NULL),
      IFF(NULLIF(TRIM(e.raw_flight),'') IS NOT NULL AND e.last_flight_date IS NULL,'E_INVALID_FLIGHT_DATE',     NULL),
      IFF(NULLIF(TRIM(e.raw_dob),'')    IS NOT NULL AND e.dob IS NULL,             'E_INVALID_DOB',           NULL),
      IFF(e.country_raw IS NULL,                                        'E_MISSING_COUNTRY', NULL),
      IFF(e.country_raw IS NOT NULL AND (e.country_code IS NULL OR NOT COALESCE(e.country_enabled,FALSE)),
                                                                        'E_UNKNOWN_COUNTRY', NULL),
      -- Every bounded column of CORE.MEMBER_TEMPLATE / MEMBER_CURRENT_COUNTRY must be covered here, otherwise one
      -- oversized VALID value fails the MERGE in SP_LOAD_COUNTRY_TABLES for the whole batch:
      --   member_id VARCHAR(18), member_name VARCHAR(255), tier_code VARCHAR(5), agent_name VARCHAR(255),
      --   state VARCHAR(5), is_active VARCHAR(1), member_type VARCHAR(1)      -> checked below
      --   country_code VARCHAR(3)  -> only ever a REF_COUNTRY_ALIAS value (unknown => E_UNKNOWN_COUNTRY)
      --   post_code NUMBER(5,0)    -> regex [0-9]{1,5} above, anything else is NULL + W_INVALID_POST_CODE
      --   country_raw (spec 5) is not stored in CORE but is checked for spec parity with skypoints/config.py MAX_LEN
      IFF(LENGTH(e.member_name) > 255 OR LENGTH(e.member_id) > 18 OR LENGTH(e.tier_code) > 5
          OR LENGTH(e.agent_name) > 255
          OR LENGTH(e.state) > 5 OR LENGTH(e.country_raw) > 5 OR LENGTH(e.is_active) > 1 OR LENGTH(e.member_type) > 1,
                                                                        'E_LENGTH_EXCEEDED', NULL),
      IFF(e.member_id IS NOT NULL AND NOT REGEXP_LIKE(e.member_id,'[A-Za-z0-9-]+'), 'E_MEMBER_ID_FORMAT', NULL),
      -- file name did not carry a parseable timestamp => no record version; a NULL would sort FIRST in
      -- "ORDER BY batch_ts DESC" and wrongly win latest-wins
      IFF(e.batch_ts IS NULL,                                           'E_MISSING_BATCH_TS', NULL),
      IFF(e.field_count_ok = FALSE,                                     'E_FIELD_COUNT_MISMATCH', NULL)
    ) AS dq_errors,
    -- ---- warning rules (row loads, issue is logged) --------------------------------------------------
    ARRAY_CONSTRUCT_COMPACT(
      IFF(e.tier_code IS NOT NULL AND e.known_tier IS NULL, 'W_UNKNOWN_TIER', NULL),
      IFF(e.is_active IS NOT NULL AND e.is_active NOT IN ('A','I'),   'W_UNKNOWN_ACTIVE_FLAG', NULL),
      IFF(e.member_type IS NOT NULL AND e.member_type NOT IN ('I','C'), 'W_UNKNOWN_MEMBER_TYPE', NULL),
      IFF(e.last_flight_date < e.enrollment_date,                     'W_FLIGHT_BEFORE_ENROLLMENT', NULL),
      IFF(e.dob >= e.enrollment_date,                                 'W_DOB_NOT_BEFORE_ENROLLMENT', NULL),
      IFF(e.age NOT BETWEEN 0 AND 120,                                'W_AGE_OUT_OF_RANGE', NULL),
      IFF(e.enrollment_date > :P_BUSINESS_DATE OR e.last_flight_date > :P_BUSINESS_DATE, 'W_FUTURE_DATE', NULL),
      IFF(e.dob IS NULL AND NULLIF(TRIM(e.raw_dob),'') IS NULL,       'W_MISSING_DOB', NULL),
      IFF(e.agent_name IS NULL,                                       'W_MISSING_AGENT', NULL),
      IFF(e.raw_post_code IS NOT NULL AND e.post_code IS NULL,        'W_INVALID_POST_CODE', NULL)
    ) AS dq_warnings
  FROM (
    SELECT p.*, a.country_code, c.is_enabled AS country_enabled, t.tier_code AS known_tier,
      -- completed years (DATEDIFF('year') counts calendar boundaries, so correct for not-yet-had birthday)
      IFF(p.dob IS NULL, NULL,
          DATEDIFF('year', p.dob, :P_BUSINESS_DATE)
          - IFF(DATEADD('year', DATEDIFF('year', p.dob, :P_BUSINESS_DATE), p.dob) > :P_BUSINESS_DATE, 1, 0)) AS age,
      DATEDIFF('day', p.last_flight_date, :P_BUSINESS_DATE)                                                  AS days_since_flight
    FROM (
      SELECT
        NULLIF(TRIM(r.member_name),'')                                   AS member_name,
        NULLIF(TRIM(r.member_id),'')                                     AS member_id,
        TRY_TO_DATE(NULLIF(TRIM(r.enrollment_date),''),  'YYYYMMDD')     AS enrollment_date,
        TRY_TO_DATE(NULLIF(TRIM(r.last_flight_date),''), 'YYYYMMDD')     AS last_flight_date,
        -- DOB arrives DDMMYYYY and the staging extract lost the leading zero (3051985) => LPAD first.
        -- !! DDMMYYYY vs MMDDYYYY must be confirmed with the source design doc.
        TRY_TO_DATE(LPAD(NULLIF(TRIM(r.dob),''),8,'0'),  'DDMMYYYY')     AS dob,
        UPPER(NULLIF(TRIM(r.tier_code),''))                              AS tier_code,
        NULLIF(TRIM(r.agent_name),'')                                    AS agent_name,
        UPPER(NULLIF(TRIM(r.state),''))                                  AS state,
        UPPER(NULLIF(TRIM(r.country),''))                                AS country_raw,
        UPPER(NULLIF(TRIM(r.is_active),''))                              AS is_active,
        UPPER(NULLIF(TRIM(r.member_type),''))                            AS member_type,
        -- spec: INT, 5 digits. Anything else becomes NULL + warning (non-mandatory field)
        IFF(REGEXP_LIKE(TRIM(r.post_code),'[0-9]{1,5}'), TRIM(r.post_code)::NUMBER, NULL) AS post_code,
        NULLIF(TRIM(r.post_code),'') AS raw_post_code,
        r.enrollment_date AS raw_enroll, r.last_flight_date AS raw_flight, r.dob AS raw_dob,
        r.field_count_ok, r.batch_ts, r.src_file_name, r.src_row_number
      FROM RAW.STRM_MEMBER_FEED r
      WHERE r.rec_type = 'D'
    ) p
    LEFT JOIN CORE.REF_COUNTRY_ALIAS a ON a.alias = p.country_raw
    LEFT JOIN CORE.REF_COUNTRY c       ON c.country_code = a.country_code
    LEFT JOIN CORE.REF_TIER t          ON t.tier_code = p.tier_code
  ) e
  ) typed;

  -- Counts come from the INSERT's own result (one column per INTO clause, in clause order), not from re-reading
  -- STG: $1 = rows into STG_MEMBER, $2 = rows into DQ_REJECT_MEMBER.
  SELECT $1, $2 INTO :v_rows, :v_rejected FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
  v_valid := v_rows - v_rejected;

  INSERT INTO OPS.PIPELINE_RUN_LOG (step, metrics)
    SELECT 'stg_member', OBJECT_CONSTRUCT('rows', :v_rows, 'valid', :v_valid, 'rejected', :v_rejected,
                                          'business_date', :P_BUSINESS_DATE::STRING);
  COMMIT;
  RETURN OBJECT_CONSTRUCT('rows', v_rows, 'valid', v_valid, 'rejected', v_rejected);
EXCEPTION
  -- Any failure: undo everything this call did (ROLLBACK is a no-op if no transaction is open), then re-raise
  -- so the caller / task sees the error. The stream offset is not advanced by a rolled-back transaction.
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;
