"""Flattened redemption feed: validation, latest-feed-wins per txn_id, join-back to members (mirrors sql/04)."""
from __future__ import annotations
import re
import pandas as pd
from .config import REDEMPTION_STATUSES, REDEMPTION_MAX_LEN, MAX_MILES, MILES_PATTERN
from .dates import parse_date


def stage_redemptions(flat: pd.DataFrame):
    good, bad = [], []
    for r in flat.to_dict("records"):
        r = {k: (None if pd.isna(v) else v) for k, v in r.items()}   # normalise NaN to None (NaN is truthy)
        e = []
        txn_d, s1 = parse_date(r["txn_date"]); feed_d, s2 = parse_date(r["feed_date"])
        # Checked on the text, not a parsed number: '12.0', '12.5', '012', '+12' and 13+ digits all fail.
        # sql/04 applies the same regex to the raw JSON text (see MILES_PATTERN).
        raw_miles = str(r["miles_redeemed"]).strip() if r["miles_redeemed"] is not None else ""
        miles = int(raw_miles) if re.fullmatch(MILES_PATTERN, raw_miles) else None
        if not r["member_id"]: e.append("E_MANDATORY_MEMBER_ID")
        if not r["txn_id"]: e.append("E_MANDATORY_TXN_ID")
        if s2 != "ok": e.append("E_INVALID_FEED_DATE")
        if s1 == "invalid": e.append("E_INVALID_TXN_DATE")
        if miles is None or not 0 < miles < MAX_MILES: e.append("E_INVALID_MILES")
        if (r["status"] or "").upper() not in REDEMPTION_STATUSES: e.append("E_UNKNOWN_STATUS")
        if txn_d and feed_d and txn_d > feed_d: e.append("E_TXN_AFTER_FEED_DATE")
        # Feeds whose ids are local counters (Excel feeds) carry source_country; namespace like the profile side
        member_key = f"{str(r['source_country']).upper()}-{r['member_id']}" if r.get("source_country") and r["member_id"] else r["member_id"]
        keyed = {**r, "member_id": member_key}
        if any(keyed.get(c) and len(str(keyed[c])) > n for c, n in REDEMPTION_MAX_LEN.items()): e.append("E_LENGTH_EXCEEDED")
        row = {**r, "member_id": member_key, "txn_date": txn_d, "feed_date": feed_d, "miles_redeemed": miles,
               "status": (r["status"] or "").upper()}
        # quarantine keeps the value as received, so the row can be replayed after a source fix
        (bad if e else good).append({**row, "miles_redeemed": r["miles_redeemed"], "errors": e} if e else row)
    cols = list(flat.columns)
    return pd.DataFrame(good, columns=cols), pd.DataFrame(bad, columns=cols + ["errors"])


def upsert_redemptions(fact: pd.DataFrame, new: pd.DataFrame) -> pd.DataFrame:
    """Latest feed_date wins per txn_id (PENDING -> COMPLETED)."""
    both = pd.concat([fact, new], ignore_index=True) if len(fact) else new.copy()
    both = both.sort_values(["feed_date", "src_file_name", "src_row_number"])
    return both.drop_duplicates("txn_id", keep="last").reset_index(drop=True)


def enrich(fact: pd.DataFrame, registry: pd.DataFrame, targets: dict) -> pd.DataFrame:
    """fact LEFT JOIN registry (member_id) LEFT JOIN country table (member_id + country). Orphans are kept."""
    cols = ["member_id", "member_name", "tier_code", "country_code", "state"]
    loaded = [t[cols] for t in targets.values() if len(t)]
    members = pd.concat(loaded, ignore_index=True) if loaded else pd.DataFrame(columns=cols)
    j = fact.merge(registry[["member_id", "country_code"]], on="member_id", how="left") \
            .merge(members, on=["member_id", "country_code"], how="left")
    j["is_orphan"] = j.member_name.isna()
    return j
