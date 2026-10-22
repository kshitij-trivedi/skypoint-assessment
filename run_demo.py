"""End-to-end demo on the assessment's sample feeds in data/raw/.

    python run_demo.py [--as-of YYYY-MM-DD]      (writes data/curated/*.csv)
"""
import argparse
import pathlib
from datetime import date, datetime
import pandas as pd
from skypoints.parsers import parse_flat_file, parse_excel_feed, parse_redemptions
from skypoints.staging import stage_member
from skypoints.transform import apply_batch, empty_state
from skypoints import validate, redemptions as rd

DATA = pathlib.Path(__file__).resolve().parent / "data" / "raw"

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--as-of", type=date.fromisoformat, default=date(2024, 1, 15),
                help="business date for Age / Stale_Member (default: 2024-01-15)")
AS_OF = ap.parse_args().as_of
out = pathlib.Path(__file__).resolve().parent / "data" / "curated"; out.mkdir(parents=True, exist_ok=True)
pd.set_option("display.width", 200, "display.max_columns", 30)


def load_flat(name):
    """batch_ts (the record version) comes from the file name."""
    return parse_flat_file((DATA / name).read_text(), name)


raw, info = load_flat("SKYPOINTS_MEMBER_20240115_020000.dat")
frames = [stage_member(raw, AS_OF)]
for cc in ("AUS", "IND"):
    frames.append(stage_member(parse_excel_feed(DATA / f"{cc}.xlsx", cc, datetime(2024, 1, 15, 3)), AS_OF))
stg = pd.concat(frames, ignore_index=True)

print("== STAGING (typed + derived) ==")
print(stg[["member_name", "member_id", "country_raw", "country_code", "dob", "age", "days_since_flight",
           "stale_member", "dq_status", "dq_errors", "dq_warnings"]].to_string())

findings = (validate.check_header(info) + validate.check_key_uniqueness(stg) + validate.check_profile(stg)
            + validate.check_field_reconciliation(raw, stg) + validate.check_reject_rate(stg))
print("\n== BATCH-LEVEL FINDINGS ==")
for f in findings: print(f"[{f['severity']:5}] {f['rule']}: {f['detail']}")

t, reg = empty_state()
t, reg, m = apply_batch(stg, t, reg)
print("\n== LOAD 1 ==", m)
move = stage_member(load_flat("SKYPOINTS_MEMBER_20240116_020000.dat")[0], AS_OF)
t, reg, m = apply_batch(move, t, reg)
print("== LOAD 2 (Ravi IND -> USA) ==", m)
for name, df in t.items():
    print(f"\n-- CORE.{name} ({len(df)})")
    if len(df): print(df[["member_id", "member_name", "country_code", "tier_code", "age", "stale_member"]].to_string(index=False))
    df.to_csv(out / f"{name}.csv", index=False)
print("\ncross-country duplicates:", validate.check_country_exclusivity(t) or "none")
stg[stg.dq_status == "REJECTED"].to_csv(out / "DQ_REJECT_MEMBER.csv", index=False)

# Day 1 feed, then day 2: RX10092 settles (PENDING -> COMPLETED) and one bad txn arrives
fact, rejects = pd.DataFrame(), []
for name in ("redemptions_20240115.json", "redemptions_20240116.json"):
    good, bad = rd.stage_redemptions(parse_redemptions((DATA / name).read_text(), name))
    fact = rd.upsert_redemptions(fact, good)
    rejects.append(bad)
rejects = pd.concat(rejects, ignore_index=True)
print("\n== REDEMPTION REJECTS ==")
print(rejects[["txn_id", "miles_redeemed", "status", "errors"]].to_string(index=False) if len(rejects) else "none")
rejects.to_csv(out / "DQ_REJECT_REDEMPTION.csv", index=False)
enriched = rd.enrich(fact, reg, t)
print("\n== REDEMPTIONS joined to members ==")
print(enriched[["txn_id", "txn_date", "partner", "miles_redeemed", "status", "member_id", "member_name", "country_code", "is_orphan"]].to_string(index=False))
enriched.to_csv(out / "REDEMPTION_ENRICHED.csv", index=False)
