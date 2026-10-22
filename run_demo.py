"""End-to-end demo on the assessment's sample feeds in data/raw/.

    python run_demo.py [--as-of YYYY-MM-DD] [--out DIR]      (writes DIR/*.csv, default data/curated)
"""
import argparse
import pathlib
from datetime import date, datetime
import pandas as pd
from skypoints.config import EXCEL_FILE_PATTERN
from skypoints.parsers import parse_flat_file, parse_excel_feed, parse_redemptions, batch_ts_from_filename
from skypoints.staging import stage_member
from skypoints.transform import apply_batch, empty_state
from skypoints import validate, redemptions as rd

ROOT = pathlib.Path(__file__).resolve().parent
DATA = ROOT / "data" / "raw"
# The sample Excel files are named AUS.xlsx / IND.xlsx, without the <CC>_YYYYMMDD_HHMMSS timestamp the pipeline
# takes the record version from. The SQL path would reject their rows (E_MISSING_BATCH_TS); the demo gives them
# this explicit version instead (one hour after the 15 Jan flat file) so they can be shown. A file named to the
# pattern uses its own timestamp.
DEMO_EXCEL_BATCH_TS = datetime(2024, 1, 15, 3)

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--as-of", type=date.fromisoformat, default=date(2024, 1, 15),
                help="business date for Age / Stale_Member (default: 2024-01-15)")
ap.add_argument("--out", type=pathlib.Path, default=ROOT / "data" / "curated",
                help="output directory for the CSVs (default: data/curated)")
args = ap.parse_args()
AS_OF, out = args.as_of, args.out
out.mkdir(parents=True, exist_ok=True)
pd.set_option("display.width", 200, "display.max_columns", 30)


def load_flat(name):
    """batch_ts (the record version) comes from the file name. Returns (raw, info)."""
    return parse_flat_file((DATA / name).read_text(), name)


def load_excel(cc):
    path = next(DATA.glob(f"{cc}*.xlsx"))
    return parse_excel_feed(path, cc, batch_ts_from_filename(path.name, EXCEL_FILE_PATTERN) or DEMO_EXCEL_BATCH_TS)


raw1, info1 = load_flat("SKYPOINTS_MEMBER_20240115_020000.dat")
raw2, info2 = load_flat("SKYPOINTS_MEMBER_20240116_020000.dat")
stg = pd.concat([stage_member(raw1, AS_OF)] + [stage_member(load_excel(cc), AS_OF) for cc in ("AUS", "IND")],
                ignore_index=True)
move = stage_member(raw2, AS_OF)

print("== STAGING (typed + derived) ==")
print(stg[["member_name", "member_id", "country_raw", "country_code", "dob", "age", "days_since_flight",
           "stale_member", "dq_status", "dq_errors", "dq_warnings"]].to_string())

# file-level checks for BOTH member files; batch-level checks for the load-1 batch
findings = (validate.check_header(info1) + validate.check_header(info2)
            + validate.check_key_uniqueness(stg) + validate.check_profile(stg)
            + validate.check_field_reconciliation(raw1, stg) + validate.check_field_reconciliation(raw2, move)
            + validate.check_reject_rate(stg))
print("\n== BATCH-LEVEL FINDINGS ==")
for f in findings: print(f"[{f['severity']:5}] {f['rule']}: {f['detail']}")

t, reg = empty_state()
t, reg, m = apply_batch(stg, t, reg)
print("\n== LOAD 1 ==", m)
t, reg, m = apply_batch(move, t, reg)
print("== LOAD 2 (Ravi IND -> USA) ==", m)
for name, df in t.items():
    print(f"\n-- CORE.{name} ({len(df)})")
    if len(df): print(df[["member_id", "member_name", "country_code", "tier_code", "age", "stale_member"]].to_string(index=False))
    df.to_csv(out / f"{name}.csv", index=False)
print("\ncross-country duplicates:", validate.check_country_exclusivity(t) or "none")
stg[stg.dq_status == "REJECTED"].to_csv(out / "DQ_REJECT_MEMBER.csv", index=False)

# Day 1 feed, then day 2: RX10092 settles (PENDING -> COMPLETED) and one bad txn arrives
fact, rejects, staged = pd.DataFrame(), [], []
for name in ("redemptions_20240115.json", "redemptions_20240116.json"):
    good, bad = rd.stage_redemptions(parse_redemptions((DATA / name).read_text(), name))
    fact = rd.upsert_redemptions(fact, good)
    rejects.append(bad); staged.append(good)
rejects = pd.concat(rejects, ignore_index=True)
print("\n== REDEMPTION REJECTS ==")
print(rejects[["txn_id", "miles_redeemed", "status", "errors"]].to_string(index=False) if len(rejects) else "none")
print("txn_id used by more than one member:", validate.check_redemption_keys(pd.concat(staged, ignore_index=True)) or "none")
rejects.to_csv(out / "DQ_REJECT_REDEMPTION.csv", index=False)
enriched = rd.enrich(fact, reg, t)
print("\n== REDEMPTIONS joined to members ==")
print(enriched[["txn_id", "txn_date", "partner", "miles_redeemed", "status", "member_id", "member_name", "country_code", "is_orphan"]].to_string(index=False))
enriched.to_csv(out / "REDEMPTION_ENRICHED.csv", index=False)
