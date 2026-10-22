-- =====================================================================
-- 5. Validations
-- Layer 1 (row level)  : evaluated in SP_LOAD_STG_MEMBER / SP_LOAD_REDEMPTIONS (rule ids E_* blocking, W_* warning)
-- Layer 2 (file level) : header vs design doc, trailer count      <- below
-- Layer 3 (batch level): key uniqueness, profiling, reconciliation <- below
-- Each query returns rows only when something is WRONG, so they plug straight into an alerting task.
-- =====================================================================

-- 5.0 File name must follow the spec SKYPOINTS_MEMBER_YYYYMMDD_HHMMSS[TT].dat (the timestamp is the record version).
--     Same function as the COPY, so "bad name" here and E_MISSING_BATCH_TS in staging can never disagree.
SELECT DISTINCT src_file_name, 'B_BAD_FILE_NAME' AS rule
FROM RAW.RAW_MEMBER_FEED
WHERE src_file_name NOT LIKE '%.xlsx%' AND src_file_name NOT LIKE '%.csv'
  AND OPS.FN_MEMBER_FILE_BATCH_TS(src_file_name) IS NULL;

-- 5.1 Header record must match the design doc (sample header has no Post_Code, the spec has 11 fields)
SELECT src_file_name, 'B_HEADER_MISMATCH' AS rule,
       ARRAY_CONSTRUCT(member_name,member_id,enrollment_date,last_flight_date,tier_code,agent_name,state,country,dob,is_active) AS received
FROM RAW.RAW_MEMBER_FEED
WHERE rec_type='H'
  AND NOT (member_name='Member_Name' AND member_id='Member_Id' AND enrollment_date='Enrollment_Date'
       AND last_flight_date='Last_Flight_Date' AND tier_code='Tier_Code' AND agent_name='Agent_Name'
       AND state='State' AND country='Country' AND dob='DOB' AND is_active='Is_Active');

-- 5.2 Key-column uniqueness. The spec marks Member_Name as the key - almost certainly meant Member_ID
--     (names repeat). Uniqueness is enforced on member_id; duplicates are resolved by "latest wins".
--     a) duplicates inside one file are a source defect worth alerting on
SELECT src_file_name, member_id, COUNT(*) AS occurrences
FROM STG.STG_MEMBER WHERE dq_status='VALID'
GROUP BY src_file_name, member_id HAVING COUNT(*) > 1;
--     b) after the load, a member must exist in exactly ONE country table (and PK must be unique per table)
SELECT member_id, COUNT(*) AS countries, ARRAY_AGG(country_code) AS where_found
FROM CORE.V_MEMBER_ALL GROUP BY member_id HAVING COUNT(*) > 1;
--     c) same member_id reused by a different person (different name AND dob) = ID collision, not a move
SELECT member_id, COUNT(DISTINCT member_name) AS names, COUNT(DISTINCT dob) AS dobs, ARRAY_AGG(DISTINCT country_code) AS countries
FROM STG.STG_MEMBER WHERE dq_status='VALID'
GROUP BY member_id HAVING COUNT(DISTINCT member_name) > 1 AND COUNT(DISTINCT dob) > 1;

-- 5.3 Profiling checks aimed at the issues visible in the sample
--     a) member_id length outliers (22345 / 2256 next to 6-digit ids -> truncated or zero-stripped ids)
WITH m AS (SELECT MODE(LENGTH(member_id)) AS typical FROM STG.STG_MEMBER WHERE dq_status='VALID')
SELECT s.member_id, s.src_file_name, LENGTH(s.member_id) AS len, m.typical
FROM STG.STG_MEMBER s CROSS JOIN m WHERE LENGTH(s.member_id) <> m.typical AND s.dq_status='VALID';
--     b) DOB placeholder: one DOB shared by a large share of a batch (sample: every row is 03051985)
SELECT src_file_name, dob, COUNT(*) AS n, ROUND(100*RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY src_file_name),1) AS pct
FROM STG.STG_MEMBER GROUP BY src_file_name, dob QUALIFY pct > 50 AND n >= 5;
--     c) country spelled inconsistently (AU vs AUS, PHIL vs PHL) - confirms alias table is doing work; unknowns are rejected
SELECT country_raw, country_code, COUNT(*) FROM STG.STG_MEMBER GROUP BY ALL HAVING country_raw <> country_code OR country_code IS NULL;
--     d) values lost between RAW and STG: the file has Agent_Name 'Sam' on all 5 rows, the sample staging table
--        shows it for Elena only. Per file, a column filled on N raw rows must be filled on N staged rows.
--        (dates / post_code are excluded: staging legitimately NULLs invalid values, and flags them)
WITH r AS (
  SELECT src_file_name,
         COUNT(NULLIF(TRIM(member_name),'')) mn, COUNT(NULLIF(TRIM(member_id),'')) mi, COUNT(NULLIF(TRIM(tier_code),'')) tc,
         COUNT(NULLIF(TRIM(agent_name),'')) an, COUNT(NULLIF(TRIM(state),'')) st, COUNT(NULLIF(TRIM(country),'')) co,
         COUNT(NULLIF(TRIM(is_active),'')) ia
  FROM RAW.RAW_MEMBER_FEED WHERE rec_type = 'D' GROUP BY 1),
s AS (
  SELECT src_file_name, COUNT(member_name) mn, COUNT(member_id) mi, COUNT(tier_code) tc, COUNT(agent_name) an,
         COUNT(state) st, COUNT(country_raw) co, COUNT(is_active) ia
  FROM STG.STG_MEMBER GROUP BY 1)
SELECT src_file_name, 'B_FIELD_DROPPED' AS rule, dropped_columns
FROM (
  SELECT r.src_file_name, ARRAY_CONSTRUCT_COMPACT(
           IFF(s.mn < r.mn, 'member_name', NULL), IFF(s.mi < r.mi, 'member_id', NULL), IFF(s.tc < r.tc, 'tier_code', NULL),
           IFF(s.an < r.an, 'agent_name', NULL),  IFF(s.st < r.st, 'state', NULL),     IFF(s.co < r.co, 'country', NULL),
           IFF(s.ia < r.ia, 'is_active', NULL)) AS dropped_columns
  FROM r JOIN s USING (src_file_name))
WHERE ARRAY_SIZE(dropped_columns) > 0;
--     e) every member 'stale' (all sample flights are in 2012) - flag a batch where >95% are stale
SELECT src_file_name, ROUND(100*AVG(stale_member::INT),1) AS pct_stale FROM STG.STG_MEMBER GROUP BY src_file_name HAVING pct_stale > 95;

-- 5.4 Reconciliation: nothing lost between layers
SELECT r.src_file_name, r.detail_rows, COALESCE(s.stg_rows,0) AS stg_rows, r.detail_rows - COALESCE(s.stg_rows,0) AS missing
FROM (SELECT src_file_name, COUNT_IF(rec_type='D') AS detail_rows FROM RAW.RAW_MEMBER_FEED GROUP BY 1) r
LEFT JOIN (SELECT src_file_name, COUNT(*) AS stg_rows FROM STG.STG_MEMBER GROUP BY 1) s USING (src_file_name)
WHERE r.detail_rows <> COALESCE(s.stg_rows,0);
-- (if the source adds a |T|<count> trailer, compare it to detail_rows here as well)

-- 5.5 Redemption integrity
SELECT 'orphan_redemption' AS rule, COUNT(*) AS n FROM CORE.V_REDEMPTION_ENRICHED WHERE is_orphan HAVING COUNT(*) > 0;
SELECT txn_id, COUNT(*) FROM CORE.FACT_REDEMPTION GROUP BY txn_id HAVING COUNT(*) > 1;   -- PK check (Snowflake does not enforce)
-- same txn_id sent under different members: latest-wins would silently move the miles to another member
SELECT txn_id, 'B_TXN_ID_COLLISION' AS rule, ARRAY_AGG(DISTINCT member_id) AS members
FROM STG.STG_REDEMPTION WHERE ARRAY_SIZE(errors) = 0
GROUP BY txn_id HAVING COUNT(DISTINCT member_id) > 1;

-- 5.6 Reject-rate circuit breaker: fail the run if >1% of a file is rejected
SELECT src_file_name, ROUND(100*AVG((dq_status='REJECTED')::INT),2) AS reject_pct
FROM STG.STG_MEMBER GROUP BY 1 HAVING reject_pct > 1;
