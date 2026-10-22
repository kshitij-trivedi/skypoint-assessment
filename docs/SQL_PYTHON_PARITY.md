# SQL / Python parity

Every rule id, where it is implemented, and which test exercises it. The SQL in `sql/` is the production design; the
Python in `skypoints/` implements the same rules so they can be tested and demonstrated without Snowflake.

**The SQL has not been executed against a Snowflake account.** A "Y" in the SQL column means the rule is written in
SQL, not that it has been run. Tests exercise the Python implementation only.

`test_every_rule_id_in_the_code_is_referenced_by_a_test` fails the build if a rule id in `skypoints/` is not
mentioned in `tests/`, so this table cannot silently fall behind on the Python side.

## Row level: member (`sql/02_load_staging.sql`, `skypoints/staging.py`)

| Rule | SQL | Python | Test |
|---|---|---|---|
| `E_MANDATORY_MEMBER_NAME` | Y | Y | `test_mandatory_and_unknown_country_rejected` |
| `E_MANDATORY_MEMBER_ID` | Y | Y | `test_member_blocking_rules` |
| `E_MANDATORY_ENROLLMENT_DATE` | Y | Y | `test_mandatory_and_unknown_country_rejected` |
| `E_INVALID_ENROLLMENT_DATE` | Y | Y | `test_excel_feeds_parse_and_flag_issues`, `test_flat_file_dates_accept_only_the_spec_formats` |
| `E_INVALID_FLIGHT_DATE` | Y | Y | `test_flat_file_dates_accept_only_the_spec_formats` |
| `E_INVALID_DOB` | Y | Y | `test_flat_file_dates_accept_only_the_spec_formats` |
| `E_MISSING_COUNTRY` | Y | Y | `test_member_blocking_rules` |
| `E_UNKNOWN_COUNTRY` | Y | Y | `test_mandatory_and_unknown_country_rejected` |
| `E_LENGTH_EXCEEDED` | Y | Y | `test_unknown_member_type_is_warned_not_rejected` |
| `E_MEMBER_ID_FORMAT` | Y | Y | `test_member_blocking_rules` |
| `E_FIELD_COUNT_MISMATCH` | Y | Y | `test_ragged_row_is_rejected_not_shifted`, `test_genuinely_short_row_is_still_rejected` |
| `E_MISSING_BATCH_TS` | Y | Y | `test_bad_file_name_rejects_rows_and_is_reported` |
| `W_UNKNOWN_TIER` | Y | Y | `test_member_warning_rules_flag_but_still_load` |
| `W_UNKNOWN_ACTIVE_FLAG` | Y | Y | `test_member_warning_rules_flag_but_still_load` |
| `W_UNKNOWN_MEMBER_TYPE` | Y | Y | `test_unknown_member_type_is_warned_not_rejected` |
| `W_FLIGHT_BEFORE_ENROLLMENT` | Y | Y | `test_member_warning_rules_flag_but_still_load` |
| `W_DOB_NOT_BEFORE_ENROLLMENT` | Y | Y | `test_member_warning_rules_flag_but_still_load` |
| `W_AGE_OUT_OF_RANGE` | Y | Y | `test_member_warning_rules_flag_but_still_load` |
| `W_FUTURE_DATE` | Y | Y | `test_member_warning_rules_flag_but_still_load` |
| `W_MISSING_DOB` | Y | Y | `test_excel_feeds_parse_and_flag_issues` |
| `W_MISSING_AGENT` | Y | Y | `test_member_warning_rules_flag_but_still_load` |
| `W_INVALID_POST_CODE` | Y | Y | `test_post_code_mapped_by_header_name_when_present` |

## Row level: redemption (`sql/04_redemptions.sql`, `skypoints/redemptions.py`)

| Rule | SQL | Python | Test |
|---|---|---|---|
| `E_MANDATORY_MEMBER_ID` | Y | Y | `test_redemption_blocking_rules` |
| `E_MANDATORY_TXN_ID` | Y | Y | `test_redemption_blocking_rules` |
| `E_INVALID_FEED_DATE` | Y | Y | `test_redemption_blocking_rules` |
| `E_INVALID_TXN_DATE` | Y | Y | `test_redemption_blocking_rules` |
| `E_INVALID_MILES` | Y | Y | `test_miles_must_be_a_positive_whole_number_written_as_one`, `test_redemption_bad_rows_quarantined`, `test_redemption_values_that_would_overflow_the_fact_are_quarantined` |
| `E_UNKNOWN_STATUS` | Y | Y | `test_redemption_bad_rows_quarantined` |
| `E_TXN_AFTER_FEED_DATE` | Y | Y | `test_redemption_blocking_rules` |
| `E_LENGTH_EXCEEDED` | Y | Y | `test_redemption_values_that_would_overflow_the_fact_are_quarantined` |

## File and batch level (`sql/05_validations.sql`, `skypoints/validate.py`)

| Rule | SQL | Python | Test |
|---|---|---|---|
| `B_BAD_FILE_NAME` | Y | Y | `test_bad_file_name_rejects_rows_and_is_reported` |
| `B_HEADER_MISSING_FIELDS` | Y | Y | `test_profile_checks_catch_sample_anomalies` |
| `B_HEADER_UNKNOWN_FIELDS` | Y | Y | `test_unknown_header_field_is_reported` |
| `B_HEADER_MISMATCH` | Y | **gap: SQL only** (Python maps columns by header name, so order cannot shift values) | none (SQL only) |
| `B_TRAILER_COUNT_MISMATCH` | Y | Y | `test_trailer_count_mismatch` |
| `B_DUPLICATE_KEY` | Y | Y | `test_duplicate_key_in_one_file_is_reported` |
| `B_ID_COLLISION` | Y | Y | `test_unnamespaced_ids_would_collide` |
| `B_MEMBER_IN_MULTIPLE_COUNTRIES` | Y | Y | `test_member_in_two_country_tables_is_reported` |
| `B_ID_LENGTH_OUTLIER` | Y | Y | `test_profile_checks_catch_sample_anomalies`, `test_profiles_are_per_file_and_ignore_excel_rows` |
| `B_DOB_PLACEHOLDER` | Y | Y | `test_profile_checks_catch_sample_anomalies` |
| `B_ALL_STALE` | Y | Y | `test_profile_checks_catch_sample_anomalies` |
| `B_COUNTRY_ALIAS_USED` | Y | Y | `test_profile_checks_catch_sample_anomalies` |
| `B_FIELD_DROPPED` | Y | Y | `test_field_values_lost_between_raw_and_staging_are_caught` |
| `B_ROW_COUNT_MISMATCH` | Y | **gap: SQL only** (Python builds STG from RAW in memory; no load step can lose rows) | none (SQL only) |
| `B_REJECT_RATE` | Y | Y | `test_reject_rate_is_per_file` |
| `B_TXN_ID_COLLISION` | Y | Y | `test_txn_id_reused_by_another_member_is_flagged` |
| `B_ORPHAN_REDEMPTION` | Y | **gap: SQL only** (Python sets `is_orphan` on enriched rows but raises no finding) | orphan flag: `test_redemptions_before_any_member_load_are_orphans_not_a_crash` |
| `B_FACT_DUPLICATE_TXN` | Y | **gap: SQL only** (Python's fact is de-duplicated on `txn_id` by construction) | none (SQL only) |

## Known behavioural differences

| Topic | SQL | Python |
|---|---|---|
| `B_ID_LENGTH_OUTLIER` tie | `MODE` may pick either length when two are equally common | `mode()` takes the smallest |
| JSON number `12.0` | Depends on how Snowflake renders the VARIANT as STRING (**not verified**); if it renders `12`, SQL would accept it | Rejected (`E_INVALID_MILES`) |
| Header order | Positional COPY: reordering is reported (`B_HEADER_MISMATCH`) and would shift values | Mapped by name: order does not matter |
| Unknown header fields | Only the 10 positions the COPY maps can be seen | Every header field is seen |
