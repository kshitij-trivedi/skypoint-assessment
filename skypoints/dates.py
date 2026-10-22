"""Tolerant date parsing that distinguishes NULL from INVALID (the two need different handling)."""
from __future__ import annotations
from datetime import date, datetime, timedelta

NULL_TOKENS = {"", "NULL", "NONE", "NAN", "NAT", "N/A"}
EXCEL_EPOCH = date(1899, 12, 30)


def parse_date(value, fmt: str = "YYYYMMDD"):
    """Return (date|None, status) where status in ok | null | invalid.
    fmt applies to compact digit strings: YYYYMMDD or DDMMYYYY (zero-padded if the leading 0 was lost).
    Always accepted: ISO yyyy-mm-dd[ hh:mm:ss] and Excel serial numbers (5 digits)."""
    if value is None:
        return None, "null"
    if isinstance(value, datetime):
        return value.date(), "ok"
    if isinstance(value, date):
        return value, "ok"
    s = str(value).strip()
    if s.upper() in NULL_TOKENS:
        return None, "null"
    try:
        if len(s) >= 10 and s[4] == "-" and s[7] == "-":
            return datetime.strptime(s[:10], "%Y-%m-%d").date(), "ok"
        if s.endswith(".0"):
            s = s[:-2]
        if s.isdigit():
            if len(s) == 5:                                    # Excel serial
                return EXCEL_EPOCH + timedelta(days=int(s)), "ok"
            if fmt == "DDMMYYYY" and 7 <= len(s) <= 8:
                return datetime.strptime(s.zfill(8), "%d%m%Y").date(), "ok"
            if fmt == "YYYYMMDD" and len(s) == 8:
                return datetime.strptime(s, "%Y%m%d").date(), "ok"
    except ValueError:
        pass
    return None, "invalid"


def completed_years(dob: date | None, as_of: date) -> int | None:
    if dob is None:
        return None
    return as_of.year - dob.year - ((as_of.month, as_of.day) < (dob.month, dob.day))
