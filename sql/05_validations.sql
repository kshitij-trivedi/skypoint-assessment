-- =====================================================================
-- 5. Validations
-- Layer 1 (row level)  : evaluated in SP_LOAD_STG_MEMBER / SP_LOAD_REDEMPTIONS (rule ids E_* blocking, W_* warning)
-- Layer 2 (file level) : file name, header vs design doc, trailer count   <- below
-- Layer 3 (batch level): key uniqueness, profiling, reconciliation         <- below
-- Each query returns rows only when something is WRONG and is labelled with its rule id; the ids match
-- skypoints/validate.py and docs/02-approach.md (coverage per rule: docs/SQL_PYTHON_PARITY.md).
-- These are manual queries: no Snowflake Task runs them yet.
--
-- Batch window: every query reads only rows at or after $WINDOW_START, so it prunes instead of scanning
-- years of history. Set it to the start of the batch being checked before running the file:
--   * STG.STG_MEMBER is filtered on batch_ts (clustered on TO_DATE(batch_ts), country_code);
--   * STG.STG_REDEMPTION on stg_load_ts (clustered on TO_DATE(stg_load_ts));
--   * RAW.RAW_MEMBER_FEED on load_ts (arrival time; rows from a badly named file have no batch_ts).
-- batch_ts is the extract time in the file name and load_ts the arrival time, so pick a start that covers both.
-- =====================================================================
SET WINDOW_START = DATEADD('day', -1, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ;

-- ---------- File level ----------------------------------------------------------------------------------------

-- B_BAD_FILE_NAME: the name must follow SKYPOINTS_MEMBER_YYYYMMDD_HHMMSS[TT].dat (the timestamp is the record
-- version). Same function as the COPY, so this and E_MISSING_BATCH_TS in staging can never disagree.
SELECT DISTINCT src_file_name, 'B_BAD_FILE_NAME' AS rule
FROM RAW.RAW_MEMBER_FEED
WHERE load_ts >= $WINDOW_START
  AND src_file_name NOT ILIKE '%.xlsx' AND src_file_name NOT ILIKE '%.csv'        -- Excel exports: own pattern
  AND OPS.FN_MEMBER_FILE_BATCH_TS(src_file_name) IS NULL;

-- B_HEADER_MISSING_FIELDS / B_HEADER_UNKNOWN_FIELDS: header drift against the design doc, by field name, like
-- Python. Header names land in the RAW column at their position, so ARRAY_CONSTRUCT_COMPACT collects what was
-- received. Only the 10 positions the COPY maps can land; an 11th field would need the COPY extended first.
WITH hdr AS (
  SELECT src_file_name,
         ARRAY_CONSTRUCT_COMPACT(LOWER(TRIM(member_name)), LOWER(TRIM(member_id)), LOWER(TRIM(enrollment_date)),
                                 LOWER(TRIM(last_flight_date)), LOWER(TRIM(tier_code)), LOWER(TRIM(agent_name)),
                                 LOWER(TRIM(state)), LOWER(TRIM(country)), LOWER(TRIM(post_code)), LOWER(TRIM(dob)),
                                 LOWER(TRIM(is_active))) AS received,
         ARRAY_CONSTRUCT('member_name','member_id','enrollment_date','last_flight_date','tier_code','agent_name',
                         'state','country','post_code','dob','is_active') AS spec      -- = skypoints SPEC_HEADER
  FROM RAW.RAW_MEMBER_FEED
  WHERE rec_type = 'H' AND load_ts >= $WINDOW_START)
SELECT src_file_name, 'B_HEADER_MISSING_FIELDS' AS rule, ARRAY_EXCEPT(spec, received) AS fields
FROM hdr WHERE ARRAY_SIZE(ARRAY_EXCEPT(spec, received)) > 0
UNION ALL
SELECT src_file_name, 'B_HEADER_UNKNOWN_FIELDS' AS rule, ARRAY_EXCEPT(received, spec) AS fields
FROM hdr WHERE ARRAY_SIZE(ARRAY_EXCEPT(received, spec)) > 0;

-- B_HEADER_MISMATCH (SQL only): exact names IN ORDER. The COPY maps by position, so a reordered header would
-- shift values into the wrong columns; Python maps by header name and is not exposed to this.
SELECT src_file_name, 'B_HEADER_MISMATCH' AS rule,
       ARRAY_CONSTRUCT(member_name,member_id,enrollment_date,last_flight_date,tier_code,agent_name,state,country,dob,is_active) AS received
FROM RAW.RAW_MEMBER_FEED
WHERE rec_type = 'H' AND load_ts >= $WINDOW_START
  AND NOT (member_name='Member_Name' AND member_id='Member_Id' AND enrollment_date='Enrollment_Date'
       AND last_flight_date='Last_Flight_Date' AND tier_code='Tier_Code' AND agent_name='Agent_Name'
       AND state='State' AND country='Country' AND dob='DOB' AND is_active='Is_Active');

-- B_TRAILER_COUNT_MISMATCH: an optional |T|<count>| trailer must equal the number of D rows in the file.
-- The COPY puts the trailer's count (field after 'T') into member_name. A non-numeric trailer is ignored, like Python.
SELECT src_file_name, 'B_TRAILER_COUNT_MISMATCH' AS rule, trailer_count, detail_count
FROM (SELECT src_file_name,
             MAX(IFF(rec_type = 'T', TRY_TO_NUMBER(TRIM(member_name)), NULL)) AS trailer_count,
             COUNT_IF(rec_type = 'D')                                        AS detail_count
      FROM RAW.RAW_MEMBER_FEED
      WHERE load_ts >= $WINDOW_START
      GROUP BY src_file_name)
WHERE trailer_count IS NOT NULL AND trailer_count <> detail_count;

-- ---------- Batch level: keys ---------------------------------------------------------------------------------
-- The spec marks Member_Name as the key - almost certainly meant Member_ID (names repeat). Uniqueness is
-- enforced on member_id; duplicates are resolved by "latest wins".

-- B_DUPLICATE_KEY: the same member twice in one file is a source defect worth reporting
SELECT src_file_name, member_id, 'B_DUPLICATE_KEY' AS rule, COUNT(*) AS occurrences
FROM STG.STG_MEMBER
WHERE batch_ts >= $WINDOW_START AND dq_status = 'VALID'
GROUP BY src_file_name, member_id HAVING COUNT(*) > 1;

-- B_ID_COLLISION: the same member_id used by a different person (different name AND dob) is not a country move
SELECT member_id, 'B_ID_COLLISION' AS rule, COUNT(DISTINCT member_name) AS names, COUNT(DISTINCT dob) AS dobs,
       ARRAY_AGG(DISTINCT country_code) AS countries
FROM STG.STG_MEMBER
WHERE batch_ts >= $WINDOW_START AND dq_status = 'VALID'
GROUP BY member_id HAVING COUNT(DISTINCT member_name) > 1 AND COUNT(DISTINCT dob) > 1;

-- B_MEMBER_IN_MULTIPLE_COUNTRIES: after the load a member must be in exactly ONE country table. Checked for the
-- members this batch touched, so CORE is probed by member_id (its clustering key) instead of scanned whole.
SELECT member_id, 'B_MEMBER_IN_MULTIPLE_COUNTRIES' AS rule, COUNT(*) AS countries, ARRAY_AGG(country_code) AS where_found
FROM CORE.V_MEMBER_ALL
WHERE member_id IN (SELECT member_id FROM STG.STG_MEMBER WHERE batch_ts >= $WINDOW_START AND dq_status = 'VALID')
GROUP BY member_id HAVING COUNT(*) > 1;

-- ---------- Batch level: profiling aimed at the issues visible in the sample -----------------------------------
-- Flat-file rows only, per file, VALID rows, files with at least 5 such rows (same as skypoints check_profile).
-- Excel exports (.csv/.xlsx, namespaced ids such as AUS-1) are excluded: their ids are local counters and their
-- columns differ, so they would distort the profile.

-- B_ID_LENGTH_OUTLIER: 22345 / 2256 next to 6-digit ids -> truncated or zero-stripped ids.
-- MODE per file. On a tie Snowflake's MODE may pick either value, Python takes the smallest.
WITH flat AS (
  SELECT s.*, COUNT(*) OVER (PARTITION BY src_file_name) AS file_rows
  FROM STG.STG_MEMBER s
  WHERE batch_ts >= $WINDOW_START AND dq_status = 'VALID'
    AND src_file_name NOT ILIKE '%.xlsx' AND src_file_name NOT ILIKE '%.csv')
SELECT member_id, src_file_name, 'B_ID_LENGTH_OUTLIER' AS rule, LENGTH(member_id) AS len, typical
FROM (SELECT f.*, MODE(LENGTH(member_id)) OVER (PARTITION BY src_file_name) AS typical FROM flat f WHERE file_rows >= 5)
WHERE LENGTH(member_id) <> typical;

-- B_DOB_PLACEHOLDER: one DOB shared by more than half of a file's known DOBs (sample: every row is 03051985)
WITH flat AS (
  SELECT s.*, COUNT(*) OVER (PARTITION BY src_file_name) AS file_rows,
         COUNT(dob) OVER (PARTITION BY src_file_name) AS dob_rows
  FROM STG.STG_MEMBER s
  WHERE batch_ts >= $WINDOW_START AND dq_status = 'VALID'
    AND src_file_name NOT ILIKE '%.xlsx' AND src_file_name NOT ILIKE '%.csv')
SELECT src_file_name, 'B_DOB_PLACEHOLDER' AS rule, dob, COUNT(*) AS n, ROUND(100 * COUNT(*) / ANY_VALUE(dob_rows), 1) AS pct
FROM flat
WHERE file_rows >= 5 AND dob IS NOT NULL
GROUP BY src_file_name, dob
HAVING COUNT(*) / ANY_VALUE(dob_rows) > 0.5;

-- B_ALL_STALE: more than 95% of a file's members stale (all sample flights are in 2012)
WITH flat AS (
  SELECT s.*, COUNT(*) OVER (PARTITION BY src_file_name) AS file_rows
  FROM STG.STG_MEMBER s
  WHERE batch_ts >= $WINDOW_START AND dq_status = 'VALID'
    AND src_file_name NOT ILIKE '%.xlsx' AND src_file_name NOT ILIKE '%.csv')
SELECT src_file_name, 'B_ALL_STALE' AS rule, ROUND(100 * AVG(stale_member::INT), 1) AS pct_stale
FROM flat WHERE file_rows >= 5
GROUP BY src_file_name HAVING AVG(stale_member::INT) > 0.95;

-- B_COUNTRY_ALIAS_USED (INFO): country spelled inconsistently (AU vs AUS, PHIL vs PHL) and mapped by the alias
-- table. Unknown countries are not listed here: they are rejected row by row (E_UNKNOWN_COUNTRY).
SELECT country_raw, country_code, 'B_COUNTRY_ALIAS_USED' AS rule, COUNT(*) AS n
FROM STG.STG_MEMBER
WHERE batch_ts >= $WINDOW_START AND country_code IS NOT NULL AND country_raw <> country_code
GROUP BY country_raw, country_code;

-- ---------- Batch level: reconciliation -----------------------------------------------------------------------

-- B_FIELD_DROPPED: values lost between RAW and STG. The file has Agent_Name 'Sam' on all 5 rows, the sample staging
-- table shows it for Elena only. Per file, a column filled on N raw rows must be filled on N staged rows.
-- (dates / post_code are excluded: staging legitimately NULLs invalid values, and flags them)
WITH r AS (
  SELECT src_file_name,
         COUNT(NULLIF(TRIM(member_name),'')) mn, COUNT(NULLIF(TRIM(member_id),'')) mi, COUNT(NULLIF(TRIM(tier_code),'')) tc,
         COUNT(NULLIF(TRIM(agent_name),'')) an, COUNT(NULLIF(TRIM(state),'')) st, COUNT(NULLIF(TRIM(country),'')) co,
         COUNT(NULLIF(TRIM(is_active),'')) ia
  FROM RAW.RAW_MEMBER_FEED WHERE rec_type = 'D' AND load_ts >= $WINDOW_START GROUP BY 1),
s AS (
  SELECT src_file_name, COUNT(member_name) mn, COUNT(member_id) mi, COUNT(tier_code) tc, COUNT(agent_name) an,
         COUNT(state) st, COUNT(country_raw) co, COUNT(is_active) ia
  FROM STG.STG_MEMBER WHERE batch_ts >= $WINDOW_START GROUP BY 1)
SELECT src_file_name, 'B_FIELD_DROPPED' AS rule, dropped_columns
FROM (
  SELECT r.src_file_name, ARRAY_CONSTRUCT_COMPACT(
           IFF(s.mn < r.mn, 'member_name', NULL), IFF(s.mi < r.mi, 'member_id', NULL), IFF(s.tc < r.tc, 'tier_code', NULL),
           IFF(s.an < r.an, 'agent_name', NULL),  IFF(s.st < r.st, 'state', NULL),     IFF(s.co < r.co, 'country', NULL),
           IFF(s.ia < r.ia, 'is_active', NULL)) AS dropped_columns
  FROM r JOIN s USING (src_file_name))
WHERE ARRAY_SIZE(dropped_columns) > 0;

-- B_ROW_COUNT_MISMATCH (SQL only): every RAW detail row reached STG. Python builds STG from RAW in memory and
-- has no separate load step that could lose rows.
SELECT r.src_file_name, 'B_ROW_COUNT_MISMATCH' AS rule, r.detail_rows, COALESCE(s.stg_rows,0) AS stg_rows,
       r.detail_rows - COALESCE(s.stg_rows,0) AS missing
FROM (SELECT src_file_name, COUNT_IF(rec_type='D') AS detail_rows FROM RAW.RAW_MEMBER_FEED
      WHERE load_ts >= $WINDOW_START GROUP BY 1) r
LEFT JOIN (SELECT src_file_name, COUNT(*) AS stg_rows FROM STG.STG_MEMBER
           WHERE batch_ts >= $WINDOW_START OR (batch_ts IS NULL AND stg_load_ts >= $WINDOW_START) GROUP BY 1) s
  USING (src_file_name)
WHERE r.detail_rows <> COALESCE(s.stg_rows,0);

-- B_REJECT_RATE: circuit breaker, fail the run if more than 1% of a file is rejected. Rows from a badly named file
-- have no batch_ts (all rejected, E_MISSING_BATCH_TS), so they are picked up by stg_load_ts instead.
SELECT src_file_name, 'B_REJECT_RATE' AS rule, ROUND(100 * AVG((dq_status = 'REJECTED')::INT), 2) AS reject_pct
FROM STG.STG_MEMBER
WHERE batch_ts >= $WINDOW_START OR (batch_ts IS NULL AND stg_load_ts >= $WINDOW_START)
GROUP BY src_file_name HAVING AVG((dq_status = 'REJECTED')::INT) > 0.01;

-- ---------- Redemptions ---------------------------------------------------------------------------------------

-- B_TXN_ID_COLLISION: the same txn_id sent under different members; latest-wins would silently move the miles
SELECT txn_id, 'B_TXN_ID_COLLISION' AS rule, ARRAY_AGG(DISTINCT member_id) AS members
FROM STG.STG_REDEMPTION
WHERE stg_load_ts >= $WINDOW_START AND ARRAY_SIZE(errors) = 0
GROUP BY txn_id HAVING COUNT(DISTINCT member_id) > 1;

-- B_ORPHAN_REDEMPTION (SQL only): transactions whose member is unknown or quarantined. Python marks is_orphan on
-- the enriched rows but raises no finding.
SELECT 'B_ORPHAN_REDEMPTION' AS rule, COUNT(*) AS n
FROM CORE.V_REDEMPTION_ENRICHED
WHERE is_orphan AND feed_date >= TO_DATE($WINDOW_START)
HAVING COUNT(*) > 0;

-- B_FACT_DUPLICATE_TXN (SQL only): primary-key check, Snowflake does not enforce PKs. Python's fact is
-- de-duplicated by construction (drop_duplicates on txn_id).
SELECT txn_id, 'B_FACT_DUPLICATE_TXN' AS rule, COUNT(*) AS n
FROM CORE.FACT_REDEMPTION
WHERE txn_id IN (SELECT txn_id FROM CORE.FACT_REDEMPTION WHERE updated_ts >= $WINDOW_START)
GROUP BY txn_id HAVING COUNT(*) > 1;
