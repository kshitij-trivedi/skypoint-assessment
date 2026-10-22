# 1. Use-case understanding

## The business problem

SkyPoints is a global airline loyalty programme. All members currently live in one database with millions of rows.
The business wants members **split by country** into dedicated tables (`Table_India`, `Table_USA`, ...), fed daily
by the source system, and wants **partner redemption activity** available next to the member profile.

Constraints stated in the brief:

* Two daily feeds: a **pipe-delimited flat file** of member profiles and a **semi-structured JSON feed** of mileage
  redemptions from partner airlines.
* Volume is **billions of records per day** across both feeds, so the design must be set-based and incremental.
* A member can **move country**; the **latest record wins** and the member must then exist in exactly one country table.
* Staging carries two derived attributes: **Age** (from DOB) and **Stale_Member** (more than 90 days since last flight).

## Inputs

### Member flat file (design-doc layout)

| Pos | Column | Len | Type | Mandatory | Key (per spec) |
|---|---|---|---|---|---|
| 1 | Member Name | 255 | VARCHAR | Y | Y |
| 2 | Member ID | 18 | VARCHAR | Y | N |
| 3 | Enrollment Date | 8 | DATE | Y | N |
| 4 | Last Flight Date | 8 | DATE | N | N |
| 5 | Tier Code | 5 | CHAR | N | N |
| 6 | Agent Name | 255 | CHAR | N | N |
| 7 | State | 5 | CHAR | N | N |
| 8 | Country | 5 | CHAR | N | N |
| 9 | Post Code | 5 | INT | N | N |
| 10 | Date of Birth | 8 | DATE | N | N |
| 11 | Active Member | 1 | CHAR | N | N |

Records are typed by a prefix: `|H|` header, `|D|` detail (and an optional `|T|` trailer, which many sources add). The file
name carries the extract date and time (`YYYYMMDD`, `HHMMSSTT`).

### Redemption JSON feed

One document per member: `member_id`, `feed_date`, and an array `redemptions[]` of
`{txn_id, txn_date, partner, miles_redeemed, status}`. The same transaction can reappear in a later feed with a new
status (`PENDING` today, `COMPLETED` tomorrow).

### Country Excel feeds (supplied with the assignment)

`AUS.xlsx` and `IND.xlsx` are member extracts from two countries that do **not** use the flat-file layout: their own
column names, Excel dates, no country column, and an India-only `Individual or Corporate` column. They are treated as a
second source channel that must land in the same country tables.

## Outputs

| Output | Purpose |
|---|---|
| Raw / landing tables | Exact copy of what arrived, with file and row lineage; replayable |
| Staging table | Typed, standardised, derived Age / Stale_Member, and a DQ verdict per row |
| One table per country | Current state of every member who belongs to that country |
| Flattened redemption table + fact | One row per transaction, queryable, joinable to the member |
| Quarantine tables + findings | Every rejected row and every file/batch-level issue, with a rule id |

## What the sample data actually shows

Reading the sample closely surfaced issues that a production pipeline must catch. Each one maps to a rule.

| # | Observation in the sample | Why it matters | Handling (rule id) |
|---|---|---|---|
| 1 | Country written `AU` (Jacob) and `PHIL` (Mateo) next to ISO-like `USA`, `IND`, `CAN` | Would create `Table_AU` and `Table_AUS`, splitting one country | Alias table to ISO alpha-3; unknown country rejected (`E_UNKNOWN_COUNTRY`) |
| 2 | DOB `03051985` in the file becomes `3051985` in staging | DOB was typed as a number; the leading zero is lost and the date no longer parses | Keep raw as text, left-pad to 8, parse as DDMMYYYY |
| 3 | Agent_Name is `Sam` on all 5 file rows but only Elena has it in staging | Values silently dropped by the load; row counts still match | Per-column RAW vs STG reconciliation (`B_FIELD_DROPPED`) |
| 4 | Header has 10 fields; the spec has 11 (no Post_Code) | Positional loading would shift every column after Country | Map columns by header name; report drift (`B_HEADER_MISSING_FIELDS`) |
| 5 | Spec marks **Member Name** as the key, Member ID as non-key | Names are not unique; keying on name merges different people | Treated as a spec typo: uniqueness on `member_id` |
| 6 | IDs `22345` and `2256` among 6-digit IDs | Likely truncated or zero-stripped IDs | Length-outlier profile (`B_ID_LENGTH_OUTLIER`) |
| 7 | Every member shares DOB `03051985` | Placeholder or default value, not real data | Profile check (`B_DOB_PLACEHOLDER`) |
| 8 | Every last flight is in 2012 | Every member is stale; suspicious for a live programme | Profile check (`B_ALL_STALE`) |
| 9 | Staging header reads `County` | Typo for Country | Documented; canonical name used |
| 10 | Excel: date `2021-13-13`, text `NULL`, Excel date cells | Invalid vs missing need different treatment | Invalid mandatory date rejected; missing DOB is a warning |
| 11 | Excel: IDs `1, 2, 3` exist in **both** AUS and IND for different people | "Latest wins" would treat them as one member moving country | Namespaced keys `AUS-1`, `IND-1` |

## Assumptions to confirm with the source team

| Assumption | Used where |
|---|---|
| DOB is `DDMMYYYY` (sample `03051985` = 3 May 1985) | DOB parsing, Age |
| File name is `SKYPOINTS_MEMBER_YYYYMMDD_HHMMSS[TT].dat`, TT = hundredths | Record version for latest-wins |
| Member ID, not Member Name, is the business key | Uniqueness, latest-wins, joins |
| Tiers are `GLD / SLV / PLT`; active flag is `A / I`; member type is `I / C` | Warning rules |
| Redemptions for Excel-fed members carry a `source_country` (their IDs are local counters) | Redemption join; otherwise kept as orphans |
| A missing Last Flight Date counts as stale | Stale_Member |
