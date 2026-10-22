"""RAW -> STG: type, standardise, derive Age & Stale_Member, evaluate row-level DQ (mirrors sql/02)."""
from __future__ import annotations
from datetime import date
import re
import pandas as pd
from .config import (COUNTRY_ALIASES, COUNTRY_TABLES, TIERS, ACTIVE_FLAGS, MEMBER_TYPES, MAX_LEN, STALE_DAYS)
from .dates import parse_date, completed_years

_ID_RE = re.compile(r"^[A-Za-z0-9-]+$")


def _up(v):
    return v.upper() if isinstance(v, str) else v


def stage_member(raw: pd.DataFrame, as_of: date) -> pd.DataFrame:
    out = []
    for r in raw.to_dict("records"):
        r = {k: (None if (not isinstance(v, (list, bool)) and pd.isna(v)) else v) for k, v in r.items()}  # NaN is truthy!
        errors, warns = [], []
        enroll, st_e = parse_date(r["enrollment_date"], "YYYYMMDD")
        flight, st_f = parse_date(r["last_flight_date"], "YYYYMMDD")
        dob, st_d = parse_date(r["dob"], "DDMMYYYY")      # DDMMYYYY assumed - confirm with source
        country_raw = _up(r["country"])
        cc = COUNTRY_ALIASES.get(country_raw) if country_raw else None
        tier, active, mtype = _up(r["tier_code"]), _up(r["is_active"]), _up(r.get("member_type"))
        pc_raw = str(r["post_code"]).strip() if r.get("post_code") else None
        post_code = int(pc_raw) if pc_raw and pc_raw.isdigit() and len(pc_raw) <= 5 else None   # spec: INT, 5 digits
        age = completed_years(dob, as_of)
        days = (as_of - flight).days if flight else None

        # ---- blocking
        if not r["member_name"]: errors.append("E_MANDATORY_MEMBER_NAME")
        if not r["member_id"]: errors.append("E_MANDATORY_MEMBER_ID")
        if st_e == "null": errors.append("E_MANDATORY_ENROLLMENT_DATE")
        if st_e == "invalid": errors.append("E_INVALID_ENROLLMENT_DATE")
        if st_f == "invalid": errors.append("E_INVALID_FLIGHT_DATE")
        if st_d == "invalid": errors.append("E_INVALID_DOB")
        if not country_raw: errors.append("E_MISSING_COUNTRY")
        elif cc is None: errors.append("E_UNKNOWN_COUNTRY")
        if any(r.get(c) and len(str(r[c])) > n for c, n in MAX_LEN.items()): errors.append("E_LENGTH_EXCEEDED")
        if r["member_id"] and not _ID_RE.match(r["member_id"]): errors.append("E_MEMBER_ID_FORMAT")
        if not r.get("field_count_ok", True): errors.append("E_FIELD_COUNT_MISMATCH")
        if r.get("batch_ts") is None: errors.append("E_MISSING_BATCH_TS")    # no version => cannot apply latest-wins

        # ---- warnings
        if tier and tier not in TIERS: warns.append("W_UNKNOWN_TIER")
        if active and active not in ACTIVE_FLAGS: warns.append("W_UNKNOWN_ACTIVE_FLAG")
        if mtype and mtype not in MEMBER_TYPES: warns.append("W_UNKNOWN_MEMBER_TYPE")
        if flight and enroll and flight < enroll: warns.append("W_FLIGHT_BEFORE_ENROLLMENT")
        if dob and enroll and dob >= enroll: warns.append("W_DOB_NOT_BEFORE_ENROLLMENT")
        if age is not None and not 0 <= age <= 120: warns.append("W_AGE_OUT_OF_RANGE")
        if (enroll and enroll > as_of) or (flight and flight > as_of): warns.append("W_FUTURE_DATE")
        if st_d == "null": warns.append("W_MISSING_DOB")
        if not r["agent_name"]: warns.append("W_MISSING_AGENT")
        if pc_raw and post_code is None: warns.append("W_INVALID_POST_CODE")

        out.append({**{k: r[k] for k in ("member_name", "member_id", "tier_code", "agent_name", "state", "is_active",
                                         "member_type", "src_file_name", "src_row_number", "batch_ts", "source_type")},
                    "tier_code": tier, "state": _up(r["state"]), "is_active": active, "member_type": mtype,
                    "enrollment_date": enroll, "last_flight_date": flight, "dob": dob, "post_code": post_code,
                    "country_raw": country_raw, "country_code": cc, "age": age, "days_since_flight": days,
                    # no flight date => treated as stale (same rule as SQL)
                    "stale_member": True if days is None else days > STALE_DAYS,
                    "dq_status": "REJECTED" if errors else "VALID", "dq_errors": errors, "dq_warnings": warns})
    return pd.DataFrame(out)
