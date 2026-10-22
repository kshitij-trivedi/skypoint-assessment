-- =====================================================================
-- 3. STG -> per-country tables  ("latest record wins", member may move country)
--
-- Version of a record = (batch_ts, src_row_number). Newest version wins, at three levels:
--   (a) inside the batch      : QUALIFY ROW_NUMBER() keeps one row per member_id
--   (b) against history       : only apply if newer than what CORE.MEMBER_CURRENT_COUNTRY recorded
--                               (so a late/replayed OLD file can never overwrite newer data)
--   (c) across country tables : when the winning record's country differs from where the member
--                               currently lives, delete from the old country table and upsert into the new
-- Idempotent: re-running the same batch is a no-op because of the >= version check + MERGE.
-- Scales: every step is set-based and pruned by member_id / batch_ts; no row-by-row logic.
-- =====================================================================

-- The five known country tables are created in 01_ddl.sql; this onboards any country added to REF_COUNTRY later
CREATE OR REPLACE PROCEDURE OPS.SP_ENSURE_COUNTRY_TABLES()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
  c CURSOR FOR SELECT target_table FROM CORE.REF_COUNTRY WHERE is_enabled;
BEGIN
  FOR rec IN c DO
    EXECUTE IMMEDIATE 'CREATE TABLE IF NOT EXISTS CORE.' || rec.target_table || ' LIKE CORE.MEMBER_TEMPLATE';
  END FOR;
  RETURN 'ok';
END;
$$;

CREATE OR REPLACE PROCEDURE OPS.SP_LOAD_COUNTRY_TABLES(P_BATCH_FROM TIMESTAMP_NTZ)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
  c CURSOR FOR SELECT country_code, target_table FROM CORE.REF_COUNTRY WHERE is_enabled;
  v_candidates NUMBER; v_applied NUMBER; v_moved NUMBER;
BEGIN
  CALL OPS.SP_ENSURE_COUNTRY_TABLES();
  -- Work tables are built BEFORE the transaction: DDL inside BEGIN..COMMIT implicitly commits, which would make
  -- the delete-from-old-country / upsert-into-new-country pair non-atomic.

  -- (a) newest record per member inside the unprocessed window
  CREATE OR REPLACE TEMPORARY TABLE STG.TMP_LATEST AS
    SELECT * FROM STG.STG_MEMBER
    WHERE dq_status = 'VALID' AND batch_ts >= :P_BATCH_FROM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY batch_ts DESC, src_row_number DESC) = 1;

  -- (b) keep only records newer than (or equal to, for idempotent replay) the version already applied
  CREATE OR REPLACE TEMPORARY TABLE STG.TMP_APPLY AS
    SELECT l.*, r.country_code AS prev_country
    FROM STG.TMP_LATEST l
    LEFT JOIN CORE.MEMBER_CURRENT_COUNTRY r ON r.member_id = l.member_id
    WHERE r.member_id IS NULL
       OR l.batch_ts > r.source_batch_ts
       OR (l.batch_ts = r.source_batch_ts AND l.src_row_number >= r.source_row_number);

  BEGIN TRANSACTION;
  -- (c) member moved country: remove from every other country table first
  FOR rec IN c DO
    EXECUTE IMMEDIATE
      'DELETE FROM CORE.' || rec.target_table || ' t USING STG.TMP_APPLY a ' ||
      'WHERE t.member_id = a.member_id AND a.country_code <> ''' || rec.country_code || '''';
  END FOR;

  -- upsert into the country the member now belongs to
  FOR rec IN c DO
    EXECUTE IMMEDIATE
      'MERGE INTO CORE.' || rec.target_table || ' t USING (SELECT * FROM STG.TMP_APPLY WHERE country_code = ''' ||
      rec.country_code || ''') s ON t.member_id = s.member_id ' ||
      'WHEN MATCHED THEN UPDATE SET member_name=s.member_name, enrollment_date=s.enrollment_date, ' ||
      '  last_flight_date=s.last_flight_date, tier_code=s.tier_code, agent_name=s.agent_name, state=s.state, ' ||
      '  country_code=s.country_code, post_code=s.post_code, dob=s.dob, is_active=s.is_active, member_type=s.member_type, age=s.age, ' ||
      '  days_since_flight=s.days_since_flight, stale_member=s.stale_member, source_batch_ts=s.batch_ts, ' ||
      '  source_file_name=s.src_file_name, source_row_number=s.src_row_number, updated_ts=CURRENT_TIMESTAMP() ' ||
      'WHEN NOT MATCHED THEN INSERT (member_id, member_name, enrollment_date, last_flight_date, tier_code, agent_name, ' ||
      '  state, country_code, post_code, dob, is_active, member_type, age, days_since_flight, stale_member, source_batch_ts, source_file_name, source_row_number) ' ||
      'VALUES (s.member_id, s.member_name, s.enrollment_date, s.last_flight_date, s.tier_code, s.agent_name, s.state, ' ||
      '  s.country_code, s.post_code, s.dob, s.is_active, s.member_type, s.age, s.days_since_flight, s.stale_member, s.batch_ts, s.src_file_name, s.src_row_number)';
  END FOR;

  -- registry follows the winner
  MERGE INTO CORE.MEMBER_CURRENT_COUNTRY r USING STG.TMP_APPLY a ON r.member_id = a.member_id
  WHEN MATCHED THEN UPDATE SET country_code=a.country_code, source_batch_ts=a.batch_ts,
                               source_row_number=a.src_row_number, updated_ts=CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (member_id, country_code, source_batch_ts, source_row_number)
                        VALUES (a.member_id, a.country_code, a.batch_ts, a.src_row_number);

  SELECT (SELECT COUNT(*) FROM STG.TMP_LATEST), COUNT(*), COUNT_IF(prev_country IS NOT NULL AND prev_country <> country_code)
    INTO :v_candidates, :v_applied, :v_moved FROM STG.TMP_APPLY;
  INSERT INTO OPS.PIPELINE_RUN_LOG (step, metrics)
    SELECT 'country_split', OBJECT_CONSTRUCT('candidates', :v_candidates, 'applied', :v_applied, 'moved_country', :v_moved);
  COMMIT;
  RETURN OBJECT_CONSTRUCT('candidates', v_candidates, 'applied', v_applied, 'moved_country', v_moved);
END;
$$;

-- Convenience: one logical view over all country tables (regenerate when a country is onboarded)
CREATE OR REPLACE VIEW CORE.V_MEMBER_ALL AS
  SELECT * FROM CORE.TABLE_INDIA       UNION ALL
  SELECT * FROM CORE.TABLE_USA         UNION ALL
  SELECT * FROM CORE.TABLE_AUSTRALIA   UNION ALL
  SELECT * FROM CORE.TABLE_PHILIPPINES UNION ALL
  SELECT * FROM CORE.TABLE_CANADA;

-- Age/Stale are time-dependent, so stored values age. This view always gives "as of today" values.
CREATE OR REPLACE VIEW CORE.V_MEMBER_CURRENT AS
  SELECT m.* EXCLUDE (age, days_since_flight, stale_member),
         IFF(dob IS NULL, NULL, DATEDIFF('year',dob,CURRENT_DATE())
             - IFF(DATEADD('year',DATEDIFF('year',dob,CURRENT_DATE()),dob) > CURRENT_DATE(),1,0)) AS age,
         DATEDIFF('day', last_flight_date, CURRENT_DATE())                               AS days_since_flight,
         COALESCE(DATEDIFF('day', last_flight_date, CURRENT_DATE()) > 90, TRUE)          AS stale_member
  FROM CORE.V_MEMBER_ALL m;
