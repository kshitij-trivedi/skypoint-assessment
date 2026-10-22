# 2. Approach

## Principles

1. **Never lose data silently.** Every row that arrives is either loaded or quarantined with a reason.
2. **Deterministic and replayable.** Re-running a batch, or loading an old file late, can never change the result.
3. **Set-based only.** No row-by-row processing on the production path, which matters at billions of rows a day.
4. **Rules have ids.** Every check produces a stable rule id (`E_*` blocking, `W_*` warning, `B_*` file/batch), so
   issues can be counted, alerted on and traced back to a test.

## How the work was done

1. **Read the spec and the sample as a data engineer would in a source review.** The issues list in
   [01-use-case-understanding.md](01-use-case-understanding.md) came first, before any code.
2. **Designed the layers** (RAW, STG, CORE, DQ, OPS) and the table shapes, then wrote the Snowflake DDL.
3. **Wrote each deliverable twice:** Snowflake SQL as the production path, and a small Python package (`skypoints/`)
   implementing the same rules, so every rule could be unit-tested locally without a warehouse.
4. **One test per rule or behaviour.** The tests run on the assessment's own sample files in `data/raw/`.
5. **Review passes against the brief.** The first version of the code arrived in this repository in a few large
   commits. The fixes from the file-by-file review pass that followed are separate commits, one per finding
   or group of related findings, from "Use nullable Int64 for age/days/post_code" onward (see `git log`).
   TODO(owner): confirm whether earlier review passes happened before the code was committed here.

## Key decisions

| Decision | Alternative considered | Why this one |
|---|---|---|
| **Latest wins = record version** `(batch_ts, src_row_number)` | Latest `Last_Flight_Date` | Flight date is a business attribute, not a version: a correction can carry an older flight date. The file timestamp is the only reliable ordering. |
| **Global registry** `MEMBER_CURRENT_COUNTRY` | Scan every country table to find a member | A point lookup per member instead of N table scans; also blocks a late old file from overwriting newer data. |
| **Country move = delete from old + upsert into new, in one transaction** | Insert into new and clean up later | A member must never be visible in two countries at once. |
| **RAW is all text** | Typed landing | A bad value can never fail the load; it is caught by a rule and quarantined instead. |
| **Quarantine, don't drop** | Filter bad rows out | Rejected rows stay replayable once the source fixes them; reject rate is measurable. |
| **Business date is a parameter** for Age / Stale | `CURRENT_DATE` | Backfills reproduce exactly. A view recomputes Age / Stale as of today for consumers. |
| **Age = completed years** | `DATEDIFF('year')` | `DATEDIFF('year')` counts calendar boundaries and is one year too high before the birthday. |
| **Stale is strictly > 90 days**; missing flight date = stale | `>= 90` | Follows the brief literally; a member who never flew is not active. |
| **Header-name column mapping** | Fixed positions | The sample header already differs from the spec (no Post_Code). |
| **Namespaced Excel IDs** (`AUS-1`) | Use IDs as-is | Same local ID in two countries would look like a country move and merge two people. |
| **Redemption latest wins on `feed_date`** per `txn_id` | Insert every version | `PENDING` becomes `COMPLETED` in a later feed; the fact holds one current row per transaction. |
| **Redemption join via the registry, LEFT JOIN** | INNER JOIN to profile | A redemption can arrive before its profile; it is kept and flagged as an orphan, never dropped or guessed. |

## Validation catalogue

### Row level: member (blocking `E_*` sends the row to quarantine)

| Rule | Check |
|---|---|
| `E_MANDATORY_MEMBER_NAME`, `E_MANDATORY_MEMBER_ID`, `E_MANDATORY_ENROLLMENT_DATE` | Mandatory fields per spec |
| `E_INVALID_ENROLLMENT_DATE`, `E_INVALID_FLIGHT_DATE`, `E_INVALID_DOB` | Present but not a real date (e.g. `2021-13-13`) |
| `E_MISSING_COUNTRY`, `E_UNKNOWN_COUNTRY` | Country absent or not resolvable to an enabled country |
| `E_LENGTH_EXCEEDED` | Longer than the spec length |
| `E_MEMBER_ID_FORMAT` | ID contains characters outside `A-Z a-z 0-9 -` |
| `E_FIELD_COUNT_MISMATCH` | Row has missing/extra fields (would shift columns) |
| `E_MISSING_BATCH_TS` | File name gave no record version |

### Row level: member (warning `W_*`, row still loads)

`W_UNKNOWN_TIER`, `W_UNKNOWN_ACTIVE_FLAG`, `W_UNKNOWN_MEMBER_TYPE`, `W_FLIGHT_BEFORE_ENROLLMENT`,
`W_DOB_NOT_BEFORE_ENROLLMENT`, `W_AGE_OUT_OF_RANGE`, `W_FUTURE_DATE`, `W_MISSING_DOB`, `W_MISSING_AGENT`,
`W_INVALID_POST_CODE`

### Row level: redemption

`E_MANDATORY_MEMBER_ID`, `E_MANDATORY_TXN_ID`, `E_INVALID_FEED_DATE`, `E_INVALID_TXN_DATE`,
`E_INVALID_MILES` (not a positive whole number that fits the fact), `E_UNKNOWN_STATUS`, `E_TXN_AFTER_FEED_DATE`,
`E_LENGTH_EXCEEDED`

### File and batch level

| Rule | Check |
|---|---|
| `B_BAD_FILE_NAME` | Name does not follow the spec |
| `B_HEADER_MISSING_FIELDS`, `B_HEADER_UNKNOWN_FIELDS` | Header drift vs the design doc, by field name |
| `B_HEADER_MISMATCH` (SQL only) | Header names not exactly in spec order; matters because the COPY maps by position |
| `B_TRAILER_COUNT_MISMATCH` | Trailer count differs from detail rows |
| `B_DUPLICATE_KEY` | Same member twice in one file |
| `B_ID_COLLISION` | Same ID used by different people (name and DOB differ) |
| `B_MEMBER_IN_MULTIPLE_COUNTRIES` | Post-load: a member in more than one country table |
| `B_ID_LENGTH_OUTLIER`, `B_DOB_PLACEHOLDER`, `B_ALL_STALE` | Profiling aimed at the sample's anomalies; per file, flat-file rows only |
| `B_COUNTRY_ALIAS_USED` | Country spelled as an alias (`AU`, `PHIL`) and mapped |
| `B_FIELD_DROPPED` | Values present in RAW missing in STG |
| `B_ROW_COUNT_MISMATCH` (SQL only) | RAW detail rows that never reached STG |
| `B_REJECT_RATE` | Circuit breaker: more than 1% of a file rejected |
| `B_TXN_ID_COLLISION` | Same `txn_id` under two members |
| `B_ORPHAN_REDEMPTION` (SQL only) | Redemptions whose member is unknown or quarantined |
| `B_FACT_DUPLICATE_TXN` (SQL only) | Primary-key check on the redemption fact (Snowflake does not enforce PKs) |

Coverage of every rule id in SQL, Python and the tests is listed in [SQL_PYTHON_PARITY.md](SQL_PYTHON_PARITY.md).

## Testing strategy

* `tests/test_pipeline.py` (67 tests, counting each parametrized case) covers date parsing edge cases, Age and the
  exact 90-day boundary, every sample anomaly, country moves, late replays and idempotency, Excel feeds and
  namespacing, JSON flattening, the PENDING-to-COMPLETED flow, overflow and collision cases, and the demo's
  `--as-of` option.
* Every rule id in `skypoints/` is referenced by at least one test, and a meta-test
  (`test_every_rule_id_in_the_code_is_referenced_by_a_test`) fails if a new rule is added without one. Per-rule
  coverage, including the SQL-only rules that have no Python test, is in [SQL_PYTHON_PARITY.md](SQL_PYTHON_PARITY.md).
* CI (`.github/workflows/tests.yml`) runs the tests and the demo on Python 3.11 to 3.13 on every push, with pandas
  deprecation warnings treated as errors.

## Use of AI

What is stated here is what can be checked in this repository; anything not yet confirmed by the author is marked
`TODO(owner): confirm`.

* The fixes from the file-by-file review pass (commits from "Use nullable Int64 for age/days/post_code" onward) were
  implemented with Claude Code, an AI coding assistant, working from the list of review findings. Before each commit
  the full test suite (pandas `FutureWarning` as errors) and `run_demo.py` were run and had to pass. The parser,
  date and miles fixes were written test first: the new tests failed before the fix (and one of them exposed a
  further bug, valid miles rejected once any value in the file had a fraction).
* Checks on the AI's output in that pass: the tests, the meta-test that every rule id has a test, the committed demo
  output in `data/curated` staying unchanged unless a change was intended, a diff of the demo's printed output where
  a change touched it, and the parity table. One review finding (an
  over-escaped regex in `05_validations.sql`) did not reproduce and is recorded as such in the commit message, not
  "fixed".
* TODO(owner): confirm which AI tools were used for the original code, tests and documentation, and in what role
  (drafting, reviewing).
* TODO(owner): confirm that earlier review passes found and fixed the defects previously listed here: streams that
  would never advance their offset, DDL that committed a transaction mid-move, and staging columns that would crash a
  whole batch on one oversized value.
* TODO(owner): confirm that the design decisions (the version rule, the registry, quarantine over drop, namespacing)
  were made and checked by the engineer.
* **The SQL has not been executed.** Nothing in `sql/` has been run on a Snowflake account; only the Python
  implementation is tested. Which rules exist in SQL, in Python and in the tests is listed in
  [SQL_PYTHON_PARITY.md](SQL_PYTHON_PARITY.md).

## Known limitations

* The SQL is written for Snowflake but has **not been executed against a Snowflake account**; the Python reference and
  its tests do run. Snowflake-specific points that are untested include the multi-table `INSERT ALL` with
  `RESULT_SCAN` counts, procedure `DEFAULT` arguments, `EXCEPTION` blocks and how a JSON `12.0` renders as text.
* No scheduling is scripted: there is no Snowflake Task graph, the procedures are called by hand and
  `05_validations.sql` is run manually (design in [03-architecture.md](03-architecture.md)).
* The country split's watermark does not pick up a file whose timestamp is older than the watermark but arrives
  late; that needs a backfill call with `P_BATCH_FROM`.
* The sample Excel files have no timestamp in their names. The demo gives them an explicit version
  (`DEMO_EXCEL_BATCH_TS`); the SQL path would reject their rows (`E_MISSING_BATCH_TS`).
* Open assumptions to confirm with the source team ([details](01-use-case-understanding.md#assumptions-to-confirm-with-the-source-team)):
  DOB is `DDMMYYYY`; the file name pattern `SKYPOINTS_MEMBER_YYYYMMDD_HHMMSS[TT].dat`; tier (`GLD/SLV/PLT`), active
  flag (`A/I`) and member type (`I/C`) values; and that redemptions for Excel-fed members carry `source_country`.
