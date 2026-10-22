-- =====================================================================
-- Country-specific Excel feeds (AUS.xlsx, IND.xlsx) -> canonical RAW_MEMBER_FEED
-- Same rules as skypoints/parsers.py::parse_excel_feed:
--   * each country has its own column names / dates are Excel serials, ISO strings or the text 'NULL'
--   * no country column -> implied by the file
--   * IDs are local counters (1,2,3 exist in BOTH files for different people) -> namespaced '<CC>-<id>'
-- Snowflake cannot read .xlsx directly: export each sheet to CSV upstream (or Snowpark) and PUT it on the stage.
-- The export must be named <CC>_YYYYMMDD_HHMMSS[TT].csv: that timestamp is the record version (otherwise
-- E_MISSING_BATCH_TS). Parsed by OPS.FN_EXCEL_FILE_BATCH_TS (01_ddl.sql), same pattern as skypoints/config.py.
-- =====================================================================
USE SCHEMA SKYPOINTS.RAW;

CREATE FILE FORMAT IF NOT EXISTS FF_EXCEL_CSV TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' SKIP_HEADER = 1
  NULL_IF = () EMPTY_FIELD_AS_NULL = TRUE;          -- keep the text 'NULL': the normaliser deals with it explicitly
CREATE STAGE IF NOT EXISTS STG_EXCEL_FILES FILE_FORMAT = FF_EXCEL_CSV;

-- Verbatim landing tables, one per layout (all VARCHAR)
CREATE TABLE IF NOT EXISTS RAW.RAW_XL_AUS (
  unique_id VARCHAR, member_name VARCHAR, tier_type VARCHAR, date_of_birth VARCHAR,
  date_of_enrollment VARCHAR, date_of_flight VARCHAR,
  src_file_name VARCHAR, src_row_number NUMBER, load_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
CREATE TABLE IF NOT EXISTS RAW.RAW_XL_IND (
  id VARCHAR, name VARCHAR, dob VARCHAR, tier_code VARCHAR, enrollment_date VARCHAR,
  individual_or_corporate VARCHAR, flight_date VARCHAR,
  src_file_name VARCHAR, src_row_number NUMBER, load_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
CREATE STREAM IF NOT EXISTS RAW.STRM_XL_AUS ON TABLE RAW.RAW_XL_AUS APPEND_ONLY = TRUE;
CREATE STREAM IF NOT EXISTS RAW.STRM_XL_IND ON TABLE RAW.RAW_XL_IND APPEND_ONLY = TRUE;

-- COPY INTO RAW.RAW_XL_AUS FROM (SELECT $1,$2,$3,$4,$5,$6, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
--                                FROM @RAW.STG_EXCEL_FILES/aus/);
-- COPY INTO RAW.RAW_XL_IND FROM (SELECT $1,$2,$3,$4,$5,$6,$7, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
--                                FROM @RAW.STG_EXCEL_FILES/ind/);

-- Normalise a date cell to the canonical compact string used by RAW_MEMBER_FEED.
-- Excel serial / ISO date / 'NULL'. Anything unparseable (e.g. 2021-13-13) is passed through UNCHANGED
-- so the staging rules reject it (E_INVALID_*) instead of silently turning it into NULL.
CREATE OR REPLACE FUNCTION OPS.FN_XL_DATE_YMD(V VARCHAR) RETURNS VARCHAR AS
$$ CASE
     WHEN V IS NULL OR UPPER(TRIM(V)) IN ('','NULL','NONE','NAN','N/A') THEN NULL
     WHEN REGEXP_LIKE(TRIM(V),'[0-9]{5}') THEN TO_CHAR(DATEADD('day', TRIM(V)::NUMBER, '1899-12-30'::DATE), 'YYYYMMDD')
     WHEN TRY_TO_DATE(LEFT(TRIM(V),10),'YYYY-MM-DD') IS NOT NULL THEN TO_CHAR(TRY_TO_DATE(LEFT(TRIM(V),10),'YYYY-MM-DD'), 'YYYYMMDD')
     ELSE TRIM(V) END $$;
CREATE OR REPLACE FUNCTION OPS.FN_XL_DATE_DMY(V VARCHAR) RETURNS VARCHAR AS      -- same, DOB layout is DDMMYYYY
$$ CASE
     WHEN V IS NULL OR UPPER(TRIM(V)) IN ('','NULL','NONE','NAN','N/A') THEN NULL
     WHEN REGEXP_LIKE(TRIM(V),'[0-9]{5}') THEN TO_CHAR(DATEADD('day', TRIM(V)::NUMBER, '1899-12-30'::DATE), 'DDMMYYYY')
     WHEN TRY_TO_DATE(LEFT(TRIM(V),10),'YYYY-MM-DD') IS NOT NULL THEN TO_CHAR(TRY_TO_DATE(LEFT(TRIM(V),10),'YYYY-MM-DD'), 'DDMMYYYY')
     ELSE TRIM(V) END $$;

-- Map each layout into the canonical RAW_MEMBER_FEED (stream => only new rows; run before SP_LOAD_STG_MEMBER)
CREATE OR REPLACE PROCEDURE OPS.SP_NORMALISE_EXCEL_FEEDS()
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE v_aus NUMBER; v_ind NUMBER;
BEGIN
  BEGIN TRANSACTION;
  INSERT INTO RAW.RAW_MEMBER_FEED
    (rec_type, member_name, member_id, enrollment_date, last_flight_date, tier_code, agent_name, state, country,
     post_code, dob, is_active, member_type, field_count_ok, src_file_name, src_row_number, batch_ts)
  SELECT 'D', member_name,
         IFF(NULLIF(TRIM(unique_id),'') IS NULL, NULL, 'AUS-' || TRIM(unique_id)),      -- namespace local ids
         OPS.FN_XL_DATE_YMD(date_of_enrollment), OPS.FN_XL_DATE_YMD(date_of_flight),
         tier_type, NULL, NULL, 'AUS', NULL, OPS.FN_XL_DATE_DMY(date_of_birth), NULL, NULL,
         TRUE, src_file_name, src_row_number, OPS.FN_EXCEL_FILE_BATCH_TS(src_file_name)
  FROM RAW.STRM_XL_AUS;
  v_aus := SQLROWCOUNT;
  INSERT INTO RAW.RAW_MEMBER_FEED
    (rec_type, member_name, member_id, enrollment_date, last_flight_date, tier_code, agent_name, state, country,
     post_code, dob, is_active, member_type, field_count_ok, src_file_name, src_row_number, batch_ts)
  SELECT 'D', name,
         IFF(NULLIF(TRIM(id),'') IS NULL, NULL, 'IND-' || TRIM(id)),
         OPS.FN_XL_DATE_YMD(enrollment_date), OPS.FN_XL_DATE_YMD(flight_date),
         tier_code, NULL, NULL, 'IND', NULL, OPS.FN_XL_DATE_DMY(dob), NULL, individual_or_corporate,
         TRUE, src_file_name, src_row_number, OPS.FN_EXCEL_FILE_BATCH_TS(src_file_name)
  FROM RAW.STRM_XL_IND;
  v_ind := SQLROWCOUNT;
  INSERT INTO OPS.PIPELINE_RUN_LOG (step, metrics) SELECT 'normalise_excel', OBJECT_CONSTRUCT('aus', :v_aus, 'ind', :v_ind);
  COMMIT;
  RETURN OBJECT_CONSTRUCT('aus', v_aus, 'ind', v_ind);
EXCEPTION
  -- Any failure: undo everything this call did (ROLLBACK is a no-op if no transaction is open), then re-raise
  -- so the caller / task sees the error. The stream offset is not advanced by a rolled-back transaction.
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;
-- Onboarding another country feed = one more RAW_XL_<CC> table + one INSERT block with its column mapping.
