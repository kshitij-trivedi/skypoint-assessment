"""Batch / file level validations (mirrors sql/05). Each returns a list of findings; empty list = pass."""
from __future__ import annotations
import pandas as pd
from .config import SPEC_HEADER


def check_header(info: dict) -> list[dict]:
    f = []
    if not info.get("file_name_ok", True):
        f.append({"rule": "B_BAD_FILE_NAME", "severity": "ERROR",
                  "detail": f"{info['file_name']} does not match SKYPOINTS_MEMBER_YYYYMMDD_HHMMSS[TT].dat"})
    if info["header_missing_vs_spec"]:
        f.append({"rule": "B_HEADER_MISSING_FIELDS", "severity": "WARN",
                  "detail": f"header lacks spec fields {info['header_missing_vs_spec']}"})
    extra = [h for h in (info["header"] or []) if h not in SPEC_HEADER]
    if extra:
        f.append({"rule": "B_HEADER_UNKNOWN_FIELDS", "severity": "WARN", "detail": f"unexpected fields {extra}"})
    if info["trailer_count"] is not None and info["trailer_count"] != info["detail_count"]:
        f.append({"rule": "B_TRAILER_COUNT_MISMATCH", "severity": "ERROR",
                  "detail": f"trailer={info['trailer_count']} details={info['detail_count']}"})
    return f


def check_key_uniqueness(stg: pd.DataFrame) -> list[dict]:
    """Key = member_id (spec marks Member_Name as key - almost certainly a typo; names repeat)."""
    v = stg[stg.dq_status == "VALID"]
    f = []
    for (file, mid), g in v.groupby(["src_file_name", "member_id"]):
        if len(g) > 1:
            kind = "country_move" if g.country_code.nunique() > 1 else "duplicate"
            f.append({"rule": "B_DUPLICATE_KEY", "severity": "INFO", "detail": f"{mid} x{len(g)} in {file} ({kind})"})
    for mid, g in v.groupby("member_id"):
        if g.member_name.nunique() > 1 and g.dob.nunique() > 1:
            f.append({"rule": "B_ID_COLLISION", "severity": "ERROR",
                      "detail": f"{mid}: different people share an id {sorted(g.member_name.unique())}"})
    return f


def check_profile(stg: pd.DataFrame, flat_only: bool = True) -> list[dict]:
    """Profiling checks that catch the anomalies visible in the sample data."""
    f = []
    v = stg[(stg.dq_status == "VALID") & ((stg.source_type == "flat") if flat_only else True)]
    if len(v) >= 5:
        lens = v.member_id.str.len()
        typical = lens.mode().iloc[0]
        for mid in v.member_id[lens != typical]:
            f.append({"rule": "B_ID_LENGTH_OUTLIER", "severity": "WARN",
                      "detail": f"{mid} has {len(mid)} chars, typical is {typical}"})
        top = v.dob.value_counts(normalize=True)
        if len(top) and top.iloc[0] > 0.5:
            f.append({"rule": "B_DOB_PLACEHOLDER", "severity": "WARN",
                      "detail": f"{top.iloc[0]:.0%} of rows share DOB {top.index[0]}"})
        if v.stale_member.mean() > 0.95:
            f.append({"rule": "B_ALL_STALE", "severity": "WARN",
                      "detail": f"{v.stale_member.mean():.0%} of members are stale - check Last_Flight_Date"})
    alias = stg[(stg.country_raw.notna()) & (stg.country_code.notna()) & (stg.country_raw != stg.country_code)]
    for raw, g in alias.groupby("country_raw"):
        f.append({"rule": "B_COUNTRY_ALIAS_USED", "severity": "INFO",
                  "detail": f"{raw} -> {g.country_code.iloc[0]} ({len(g)} rows)"})
    return f


# RAW column -> STG column, for fields staging never legitimately blanks (dates/post_code can be nulled as invalid)
RECON_COLS = {"member_name": "member_name", "member_id": "member_id", "tier_code": "tier_code",
              "agent_name": "agent_name", "state": "state", "country": "country_raw", "is_active": "is_active"}


def check_field_reconciliation(raw: pd.DataFrame, stg: pd.DataFrame) -> list[dict]:
    """Per file and column: values present in RAW must still be present in STG. Catches the sample's
    staging table, where Agent_Name 'Sam' (on every file row) survives for only 1 of 5 members."""
    f = []
    for file, r in raw.groupby("src_file_name"):
        s = stg[stg.src_file_name == file]
        for rc, sc in RECON_COLS.items():
            raw_n, stg_n = int(r[rc].notna().sum()), int(s[sc].notna().sum())
            if stg_n < raw_n:
                f.append({"rule": "B_FIELD_DROPPED", "severity": "ERROR",
                          "detail": f"{file}: {rc} filled on {raw_n} raw rows but {stg_n} staged rows"})
    return f


def check_reject_rate(stg: pd.DataFrame, threshold: float = 0.01) -> list[dict]:
    rate = (stg.dq_status == "REJECTED").mean() if len(stg) else 0
    return [{"rule": "B_REJECT_RATE", "severity": "ERROR",
             "detail": f"{rate:.1%} rejected > {threshold:.0%}"}] if rate > threshold else []


def check_redemption_keys(staged: pd.DataFrame) -> list[dict]:
    """txn_id is the fact's key: the same txn_id under two different members is a source defect
    (latest-wins would silently move miles from one member to another)."""
    return [{"rule": "B_TXN_ID_COLLISION", "severity": "ERROR", "detail": f"{t}: members {sorted(g.member_id.unique())}"}
            for t, g in staged.groupby("txn_id") if g.member_id.nunique() > 1]


def check_country_exclusivity(targets: dict[str, pd.DataFrame]) -> list[dict]:
    loaded = [t[["member_id"]].assign(t=n) for n, t in targets.items() if len(t)]
    if not loaded:
        return []
    allm = pd.concat(loaded, ignore_index=True)
    dup = allm[allm.duplicated("member_id", keep=False)]
    return [{"rule": "B_MEMBER_IN_MULTIPLE_COUNTRIES", "severity": "ERROR", "detail": f"{m}: {sorted(g.t)}"}
            for m, g in dup.groupby("member_id")]
