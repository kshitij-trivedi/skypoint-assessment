"""STG -> per-country tables with 'latest record wins' + member-moved-country handling (mirrors sql/03)."""
from __future__ import annotations
import pandas as pd
from .config import COUNTRY_TABLES, INT_COLS

KEEP = ["member_id", "member_name", "enrollment_date", "last_flight_date", "tier_code", "agent_name", "state",
        "country_code", "post_code", "dob", "is_active", "member_type", "age", "days_since_flight", "stale_member",
        "batch_ts", "src_file_name", "src_row_number"]


def empty_state():
    return ({t: pd.DataFrame(columns=KEEP) for t in COUNTRY_TABLES.values()},
            pd.DataFrame(columns=["member_id", "country_code", "batch_ts", "src_row_number"]))


def latest_wins(stg: pd.DataFrame) -> pd.DataFrame:
    """One row per member_id: highest (batch_ts, src_row_number). NOT Last_Flight_Date - that is a business
    attribute, not the version of the record."""
    v = stg[stg.dq_status == "VALID"].sort_values(["batch_ts", "src_row_number"])
    return v.drop_duplicates("member_id", keep="last")[KEEP]


def apply_batch(stg: pd.DataFrame, targets: dict, registry: pd.DataFrame):
    """Idempotent set-based apply. Returns (targets, registry, metrics)."""
    targets = {k: v.copy() for k, v in targets.items()}
    latest = latest_wins(stg)
    reg = registry.set_index("member_id") if len(registry) else registry.set_index("member_id")
    keep_rows, moved, stale_ignored = [], 0, 0
    for r in latest.to_dict("records"):
        prev = reg.loc[r["member_id"]] if r["member_id"] in reg.index else None
        if prev is not None and (r["batch_ts"], r["src_row_number"]) < (prev["batch_ts"], prev["src_row_number"]):
            stale_ignored += 1          # older file replayed late: must not overwrite newer data
            continue
        if prev is not None and prev["country_code"] != r["country_code"]:
            moved += 1
        keep_rows.append(r)
    applied = pd.DataFrame(keep_rows, columns=KEEP).astype(INT_COLS)   # to_dict() above drops the Int64 dtype
    if len(applied):
        ids = set(applied.member_id)
        for name, t in targets.items():          # (c) delete from every country table (covers moves + upsert)
            targets[name] = t[~t.member_id.isin(ids)]
        for cc, g in applied.groupby("country_code"):
            name = COUNTRY_TABLES[cc]
            targets[name] = pd.concat([targets[name], g], ignore_index=True) if len(targets[name]) else g.reset_index(drop=True)
        newreg = applied[["member_id", "country_code", "batch_ts", "src_row_number"]]
        kept = registry[~registry.member_id.isin(ids)]
        registry = pd.concat([kept, newreg], ignore_index=True) if len(kept) else newreg.reset_index(drop=True)
    return targets, registry, {"candidates": len(latest), "applied": len(applied), "moved_country": moved,
                               "ignored_older": stale_ignored}
