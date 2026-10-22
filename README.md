# SkyPoints Member Data Pipeline

Incubyte Data Engineer technical assessment. SkyPoints, a global airline loyalty programme, receives a daily member
flat file and a partner redemption JSON feed. This pipeline lands both, validates every row, derives Age and
Stale_Member, splits members into per-country tables with **latest record wins**, and flattens redemptions so they
join back to the member profile, at a design scale of billions of rows a day.

* **Production path:** Snowflake SQL in [`sql/`](sql/) (set-based, incremental via streams).
* **Reference implementation:** the same rules in Python in [`skypoints/`](skypoints/), used for the tests and the live demo.

## Documentation

| Document | Contents |
|---|---|
| [1. Use-case understanding](docs/01-use-case-understanding.md) | The business problem, inputs and outputs, issues found in the sample data, assumptions to confirm |
| [2. Approach](docs/02-approach.md) | Principles, key decisions and alternatives, full validation catalogue, testing, use of AI |
| [3. Architecture](docs/03-architecture.md) | Data flow diagram, layers, run order, latest-wins algorithm, redemption join, scale and reliability |

## Quick start

```bash
pip install -r requirements.txt
pytest -q                                # 67 tests
python run_demo.py                       # end-to-end: reads data/raw, writes data/curated/*.csv
python run_demo.py --as-of 2024-03-01    # different business date for Age / Stale_Member
```

The demo shows staging with derived columns, file and batch findings, two loads (Ravi moves from India to the USA),
the per-country tables, a redemption going from PENDING to COMPLETED, a rejected redemption, and the join back to members.

## Deliverables

| # | Deliverable | SQL (Snowflake) | Python reference |
|---|---|---|---|
| 1 | DDL: raw/landing, staging, per-country targets | [`01_ddl.sql`](sql/01_ddl.sql), [`01b_excel_feeds.sql`](sql/01b_excel_feeds.sql) | |
| 2 | Staging load with Age and Stale_Member (> 90 days) | [`02_load_staging.sql`](sql/02_load_staging.sql) | [`staging.py`](skypoints/staging.py) |
| 3 | Per-country split, latest record wins, country moves | [`03_split_by_country.sql`](sql/03_split_by_country.sql) | [`transform.py`](skypoints/transform.py) |
| 4 | JSON flattened to a queryable table, join back to members | [`04_redemptions.sql`](sql/04_redemptions.sql) | [`redemptions.py`](skypoints/redemptions.py) |
| 5 | Validations: mandatory, key uniqueness, sample-data issues | [`02`](sql/02_load_staging.sql), [`04`](sql/04_redemptions.sql), [`05_validations.sql`](sql/05_validations.sql) | [`staging.py`](skypoints/staging.py), [`validate.py`](skypoints/validate.py) |
| 6 | Live demonstration | | [`run_demo.py`](run_demo.py) |

## Repository structure

```
.
├── docs/                         use case, approach, architecture
├── sql/                          Snowflake, numbered in run order
│   ├── 01_ddl.sql                schemas, stages, RAW / STG / CORE / DQ / OPS tables
│   ├── 01b_excel_feeds.sql       country Excel feeds -> canonical RAW
│   ├── 02_load_staging.sql       RAW -> STG: typing, Age, Stale_Member, row rules
│   ├── 03_split_by_country.sql   STG -> country tables, latest record wins
│   ├── 04_redemptions.sql        JSON flatten, fact MERGE, join-back view
│   └── 05_validations.sql        file and batch level checks
├── skypoints/                    Python reference implementation
├── tests/                        pytest suite
├── data/
│   ├── raw/                      input: assessment sample feeds (flat files, JSON, Excel)
│   └── curated/                  output of run_demo.py: country tables, enriched redemptions, rejects
│                                 (committed as sample output so results are visible without running;
│                                  run_demo.py regenerates it)
├── run_demo.py                   live demo
└── .github/workflows/tests.yml   CI: tests + demo on every push
```

## Status

The Python implementation and its tests run (locally and in CI). The SQL is written for Snowflake but has **not yet
been executed against a Snowflake account**. Assumptions awaiting confirmation from the source team are listed in
[use-case understanding](docs/01-use-case-understanding.md#assumptions-to-confirm-with-the-source-team).
