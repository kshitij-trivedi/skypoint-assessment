-- =====================================================================
-- SkyPoints member pipeline  |  Snowflake DDL
-- Layers: RAW (landing, all-string, immutable) -> STG (typed + derived + DQ)
--         -> CORE (per-country targets, redemption fact, registry)
-- =====================================================================
CREATE DATABASE IF NOT EXISTS SKYPOINTS;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.RAW;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.STG;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.CORE;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.DQ;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.OPS;
USE SCHEMA SKYPOINTS.RAW;

-- ---------- Record version from the file name ------------------------
-- The timestamp in the file name is the record version used by "latest record wins". One definition, used by the
-- COPY below, 01b_excel_feeds.sql and 05_validations.sql. Same pattern text as skypoints/config.py; [0-9] and [.]
-- avoid backslash escaping. Groups: 1 = YYYYMMDD, 2 = HHMMSS, 3 = optional TT (hundredths -> TT*10 ms).
-- Returns NULL when the base name does not match or the timestamp is not a real one (month 13), which staging
-- turns into E_MISSING_BATCH_TS and 05_validations into B_BAD_FILE_NAME.
CREATE OR REPLACE FUNCTION OPS.FN_FILE_BATCH_TS(FILE_NAME VARCHAR, PATTERN VARCHAR)
RETURNS TIMESTAMP_NTZ
AS
$$
  IFF(REGEXP_LIKE(REGEXP_REPLACE(FILE_NAME, '.*/', ''), PATTERN),
      TIMEADD('millisecond',
              10 * COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR(REGEXP_REPLACE(FILE_NAME, '.*/', ''), PATTERN, 1, 1, 'e', 3)), 0),
              TRY_TO_TIMESTAMP_NTZ(REGEXP_SUBSTR(REGEXP_REPLACE(FILE_NAME, '.*/', ''), PATTERN, 1, 1, 'e', 1)
                                   || REGEXP_SUBSTR(REGEXP_REPLACE(FILE_NAME, '.*/', ''), PATTERN, 1, 1, 'e', 2),
                                   'YYYYMMDDHH24MISS')),
      NULL)
$$;
CREATE OR REPLACE FUNCTION OPS.FN_MEMBER_FILE_BATCH_TS(FILE_NAME VARCHAR) RETURNS TIMESTAMP_NTZ AS
$$ OPS.FN_FILE_BATCH_TS(FILE_NAME, 'SKYPOINTS_MEMBER_([0-9]{8})_([0-9]{6})([0-9]{2})?[.]dat') $$;
CREATE OR REPLACE FUNCTION OPS.FN_EXCEL_FILE_BATCH_TS(FILE_NAME VARCHAR) RETURNS TIMESTAMP_NTZ AS
$$ OPS.FN_FILE_BATCH_TS(FILE_NAME, '[A-Z]{3}_([0-9]{8})_([0-9]{6})([0-9]{2})?[.](csv|xlsx)') $$;

-- ---------- File formats & stages ------------------------------------
-- Flat file lines look like  |D|Elena|223457|...  -> leading pipe => $1 is empty, $2 = record type
CREATE FILE FORMAT IF NOT EXISTS FF_MEMBER_PIPE
  TYPE = CSV FIELD_DELIMITER = '|' SKIP_HEADER = 0
  FIELD_OPTIONALLY_ENCLOSED_BY = '"' TRIM_SPACE = TRUE
  NULL_IF = ('NULL') EMPTY_FIELD_AS_NULL = FALSE  -- empty field = '' but MISSING field = NULL => field count is detectable
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;      -- ragged rows are caught by DQ (field_count_ok), not dropped by COPY

CREATE FILE FORMAT IF NOT EXISTS FF_REDEMPTION_JSON
  TYPE = JSON STRIP_OUTER_ARRAY = TRUE;         -- accepts NDJSON or one big array

CREATE STAGE IF NOT EXISTS STG_MEMBER_FILES     FILE_FORMAT = FF_MEMBER_PIPE;
CREATE STAGE IF NOT EXISTS STG_REDEMPTION_FILES FILE_FORMAT = FF_REDEMPTION_JSON;

-- ---------- 1a. RAW / landing: member flat file ----------------------
-- Everything VARCHAR so that a bad value can never fail the load; header (H) and detail (D)
-- rows are both kept so the header can be validated against the design document.
CREATE TABLE IF NOT EXISTS RAW.RAW_MEMBER_FEED (
  rec_type          VARCHAR,          -- H | D | T
  member_name       VARCHAR,
  member_id         VARCHAR,
  enrollment_date   VARCHAR,
  last_flight_date  VARCHAR,
  tier_code         VARCHAR,
  agent_name        VARCHAR,
  state             VARCHAR,
  country           VARCHAR,
  post_code         VARCHAR,          -- in the spec (pos 9) but absent from the sample header
  dob               VARCHAR,
  is_active         VARCHAR,
  member_type       VARCHAR,          -- I/C, only sent by some country feeds (IND)
  field_count_ok    BOOLEAN,          -- FALSE => fields missing/extra, later columns would be shifted
  src_file_name     VARCHAR   NOT NULL,
  src_row_number    NUMBER    NOT NULL,
  batch_ts          TIMESTAMP_NTZ,    -- OPS.FN_MEMBER_FILE_BATCH_TS(file name); NULL => E_MISSING_BATCH_TS
  load_ts           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) DATA_RETENTION_TIME_IN_DAYS = 7;

-- Append-only stream => each downstream run only sees new rows (incremental, restartable)
CREATE STREAM IF NOT EXISTS RAW.STRM_MEMBER_FEED ON TABLE RAW.RAW_MEMBER_FEED APPEND_ONLY = TRUE;

-- ---------- 1b. RAW / landing: redemption JSON -----------------------
CREATE TABLE IF NOT EXISTS RAW.RAW_REDEMPTION_FEED (
  payload         VARIANT   NOT NULL,   -- one member document per row, untouched
  src_file_name   VARCHAR   NOT NULL,
  src_row_number  NUMBER    NOT NULL,
  load_ts         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE STREAM IF NOT EXISTS RAW.STRM_REDEMPTION_FEED ON TABLE RAW.RAW_REDEMPTION_FEED APPEND_ONLY = TRUE;

-- Loading (Snowpipe with AUTO_INGEST in prod; COPY shown for clarity)
-- Column positions follow the header actually received (10 fields in the sample: no Post_Code).
-- If the source starts sending Post_Code, add it to the list and shift $n accordingly (check 5.1 alerts on header drift).
-- COPY INTO RAW.RAW_MEMBER_FEED (rec_type, member_name, member_id, enrollment_date, last_flight_date,
--        tier_code, agent_name, state, country, dob, is_active, field_count_ok, src_file_name, src_row_number, batch_ts)
-- FROM (SELECT $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,
--              $12 IS NOT NULL AND COALESCE($13,'') = '' AND $14 IS NULL,   -- exactly the 11 expected fields
--              METADATA$FILENAME, METADATA$FILE_ROW_NUMBER,
--              OPS.FN_MEMBER_FILE_BATCH_TS(METADATA$FILENAME)     -- full name checked, TT included
--       FROM @RAW.STG_MEMBER_FILES)
-- ON_ERROR = CONTINUE;      -- COPY keeps per-file load history => the same file is never loaded twice
-- COPY INTO RAW.RAW_REDEMPTION_FEED (payload, src_file_name, src_row_number)
-- FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER FROM @RAW.STG_REDEMPTION_FILES);

-- ---------- Reference data -------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.REF_COUNTRY (
  country_code  VARCHAR(3)  PRIMARY KEY,      -- ISO alpha-3: the canonical value
  country_name  VARCHAR(100),
  target_table  VARCHAR(100) NOT NULL,        -- e.g. TABLE_INDIA
  is_enabled    BOOLEAN DEFAULT TRUE
);
CREATE TABLE IF NOT EXISTS CORE.REF_COUNTRY_ALIAS (   -- source spells countries inconsistently: AU / AUS, PHIL
  alias         VARCHAR(10) PRIMARY KEY,
  country_code  VARCHAR(3) NOT NULL
);
CREATE TABLE IF NOT EXISTS CORE.REF_TIER (tier_code VARCHAR(5) PRIMARY KEY, tier_name VARCHAR(50));

MERGE INTO CORE.REF_COUNTRY t USING (
  SELECT * FROM VALUES ('IND','India','TABLE_INDIA'),('USA','United States','TABLE_USA'),
         ('AUS','Australia','TABLE_AUSTRALIA'),('PHL','Philippines','TABLE_PHILIPPINES'),
         ('CAN','Canada','TABLE_CANADA') v(country_code,country_name,target_table)) s
ON t.country_code = s.country_code
WHEN NOT MATCHED THEN INSERT (country_code,country_name,target_table) VALUES (s.country_code,s.country_name,s.target_table);

MERGE INTO CORE.REF_COUNTRY_ALIAS t USING (
  SELECT * FROM VALUES ('IND','IND'),('IN','IND'),('USA','USA'),('US','USA'),('AUS','AUS'),('AU','AUS'),
         ('PHL','PHL'),('PHIL','PHL'),('PH','PHL'),('CAN','CAN') v(alias,country_code)) s
ON t.alias = s.alias
WHEN NOT MATCHED THEN INSERT (alias,country_code) VALUES (s.alias,s.country_code);

MERGE INTO CORE.REF_TIER t USING (SELECT * FROM VALUES ('GLD','Gold'),('SLV','Silver'),('PLT','Platinum') v(tier_code,tier_name)) s
ON t.tier_code = s.tier_code WHEN NOT MATCHED THEN INSERT (tier_code,tier_name) VALUES (s.tier_code,s.tier_name);

-- ---------- 2. STAGING: typed, derived columns, DQ outcome -----------
-- Text columns are deliberately unbounded here: STG also holds rejected rows, and a value that breaks the spec
-- length (E_LENGTH_EXCEEDED) must be quarantined, not crash the INSERT for the whole batch. Spec lengths are
-- enforced by the DQ rule and by the bounded CORE tables, which only ever receive VALID rows.
CREATE TABLE IF NOT EXISTS STG.STG_MEMBER (
  member_name        VARCHAR,             -- spec 255
  member_id          VARCHAR,             -- spec 18
  enrollment_date    DATE,
  last_flight_date   DATE,
  tier_code          VARCHAR,             -- spec 5
  agent_name         VARCHAR,             -- spec 255
  state              VARCHAR,             -- spec 5
  country_raw        VARCHAR,             -- spec 5, as received (AU, PHIL ...)
  country_code       VARCHAR(3),          -- standardised via REF_COUNTRY_ALIAS
  post_code          NUMBER(5,0),
  dob                DATE,
  is_active          VARCHAR,             -- spec 1
  member_type        VARCHAR,             -- I = individual, C = corporate (IND feed)
  -- derived
  age                NUMBER,              -- completed years at business date (unbounded: an absurd DOB is a warning, not a crash)
  days_since_flight  NUMBER,
  stale_member       BOOLEAN,             -- days_since_flight > 90
  -- lineage + DQ
  batch_ts           TIMESTAMP_NTZ,
  src_file_name      VARCHAR,
  src_row_number     NUMBER,
  dq_status          VARCHAR(10),         -- VALID | REJECTED
  dq_errors          ARRAY,               -- blocking rule ids
  dq_warnings        ARRAY,               -- non-blocking rule ids
  stg_load_ts        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) CLUSTER BY (TO_DATE(batch_ts), country_code);

CREATE TABLE IF NOT EXISTS DQ.DQ_REJECT_MEMBER LIKE STG.STG_MEMBER;   -- quarantine, replayable after fix

-- ---------- 3. CORE: per-country targets ------------------------------
-- Template: every country table is CREATE TABLE ... LIKE this. Holds the CURRENT state of a member.
CREATE TABLE IF NOT EXISTS CORE.MEMBER_TEMPLATE (
  member_id          VARCHAR(18)  NOT NULL,   -- logical PK (informational in Snowflake; enforced by MERGE)
  member_name        VARCHAR(255) NOT NULL,
  enrollment_date    DATE         NOT NULL,
  last_flight_date   DATE,
  tier_code          VARCHAR(5),
  agent_name         VARCHAR(255),
  state              VARCHAR(5),
  country_code       VARCHAR(3)   NOT NULL,
  post_code          NUMBER(5,0),
  dob                DATE,
  is_active          VARCHAR(1),
  member_type        VARCHAR(1),
  age                NUMBER,
  days_since_flight  NUMBER,
  stale_member       BOOLEAN,
  source_batch_ts    TIMESTAMP_NTZ,           -- version of the record (latest wins)
  source_file_name   VARCHAR,
  source_row_number  NUMBER,
  updated_ts         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_member PRIMARY KEY (member_id)
);

-- One table per country (identical shape). A new country later = row in REF_COUNTRY + CALL OPS.SP_ENSURE_COUNTRY_TABLES().
CREATE TABLE IF NOT EXISTS CORE.TABLE_INDIA       LIKE CORE.MEMBER_TEMPLATE;
CREATE TABLE IF NOT EXISTS CORE.TABLE_USA         LIKE CORE.MEMBER_TEMPLATE;
CREATE TABLE IF NOT EXISTS CORE.TABLE_AUSTRALIA   LIKE CORE.MEMBER_TEMPLATE;
CREATE TABLE IF NOT EXISTS CORE.TABLE_PHILIPPINES LIKE CORE.MEMBER_TEMPLATE;
CREATE TABLE IF NOT EXISTS CORE.TABLE_CANADA      LIKE CORE.MEMBER_TEMPLATE;
ALTER TABLE CORE.TABLE_INDIA       CLUSTER BY (member_id);
ALTER TABLE CORE.TABLE_USA         CLUSTER BY (member_id);
ALTER TABLE CORE.TABLE_AUSTRALIA   CLUSTER BY (member_id);
ALTER TABLE CORE.TABLE_PHILIPPINES CLUSTER BY (member_id);
ALTER TABLE CORE.TABLE_CANADA      CLUSTER BY (member_id);

-- Global registry: which country a member CURRENTLY belongs to and which record version put them there.
-- Makes "latest wins" and "member moved country" cheap (point lookup instead of scanning every country table).
CREATE TABLE IF NOT EXISTS CORE.MEMBER_CURRENT_COUNTRY (
  member_id         VARCHAR(18) PRIMARY KEY,
  country_code      VARCHAR(3)  NOT NULL,
  source_batch_ts   TIMESTAMP_NTZ NOT NULL,
  source_row_number NUMBER NOT NULL,
  updated_ts        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) CLUSTER BY (member_id);

-- Redemption fact (flattened JSON): one row per transaction
CREATE TABLE IF NOT EXISTS CORE.FACT_REDEMPTION (
  txn_id          VARCHAR(50)  NOT NULL,
  member_id       VARCHAR(18)  NOT NULL,
  txn_date        DATE,
  partner         VARCHAR(100),
  miles_redeemed  NUMBER(12,0),
  status          VARCHAR(20),
  feed_date       DATE,                      -- version of the txn: PENDING -> COMPLETED arrives as a later feed
  src_file_name   VARCHAR,
  src_row_number  NUMBER,
  updated_ts      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_redemption PRIMARY KEY (txn_id)
) CLUSTER BY (txn_date, member_id);

-- Flattened JSON, one row per transaction, every row with its DQ outcome (the queryable flat table)
CREATE TABLE IF NOT EXISTS STG.STG_REDEMPTION (
  member_id       VARCHAR,                   -- namespaced (AUS-1) when the feed sends source_country
  feed_date       DATE,
  txn_id          VARCHAR,
  txn_date        DATE,
  partner         VARCHAR,
  miles_redeemed  NUMBER(12,0),              -- NULL when invalid (E_INVALID_MILES); the raw text stays in DQ
  status          VARCHAR,
  errors          ARRAY,                     -- empty = valid
  src_file_name   VARCHAR,
  src_row_number  NUMBER,
  stg_load_ts     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) CLUSTER BY (TO_DATE(stg_load_ts));

-- The member document (payload) and the transaction element (txn) are kept only here, for replay after a source
-- fix. STG_REDEMPTION does not repeat the whole document on every transaction row; RAW keeps it once anyway.
CREATE TABLE IF NOT EXISTS DQ.DQ_REJECT_REDEMPTION (
  payload VARIANT, txn VARIANT, error_codes ARRAY, src_file_name VARCHAR, src_row_number NUMBER,
  rejected_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

-- What each incremental step has already processed. SP_LOAD_COUNTRY_TABLES reads STG rows from last_batch_ts on
-- and advances it in the same transaction as its MERGEs, so a skipped or failed run cannot strand rows.
CREATE TABLE IF NOT EXISTS OPS.PIPELINE_WATERMARK (
  pipeline_name  VARCHAR PRIMARY KEY,
  last_batch_ts  TIMESTAMP_NTZ NOT NULL,
  updated_ts     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

-- Run log for observability / reconciliation
CREATE TABLE IF NOT EXISTS OPS.PIPELINE_RUN_LOG (
  run_id VARCHAR DEFAULT UUID_STRING(), step VARCHAR, metrics VARIANT,
  run_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
