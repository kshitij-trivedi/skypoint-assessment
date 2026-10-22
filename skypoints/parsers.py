"""Source adapters: every feed is converted to ONE canonical all-string RAW layout (+ lineage columns)."""
from __future__ import annotations
import json
import re
from datetime import datetime
from pathlib import Path
import pandas as pd
from .config import RAW_COLS, SPEC_HEADER, EXCEL_FEEDS, MEMBER_FILE_PATTERN
from .dates import parse_date

LINEAGE = ["src_file_name", "src_row_number", "batch_ts", "source_type", "field_count_ok"]


def _clean(v):
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return None
    s = str(v).strip()
    return s if s != "" else None


def batch_ts_from_filename(name: str) -> datetime | None:
    """Record version comes from the file name. None if the name does not follow the spec."""
    m = re.fullmatch(MEMBER_FILE_PATTERN, Path(name).name)
    if not m:
        return None
    try:
        return datetime.strptime(m[1] + m[2], "%Y%m%d%H%M%S").replace(microsecond=int(m[3] or 0) * 10_000)
    except ValueError:
        return None


def parse_flat_file(text: str, src_file_name: str, batch_ts: datetime | None = None):
    """Pipe-delimited |H|...|  / |D|...|  / optional |T|count|. Columns are mapped BY HEADER NAME, so a
    reordered or extended layout does not silently shift data. batch_ts defaults to the one in the file name.
    Returns (raw_df, file_info)."""
    file_name_ok = batch_ts_from_filename(src_file_name) is not None
    if batch_ts is None:
        batch_ts = batch_ts_from_filename(src_file_name)
    header, rows, trailer = None, [], None
    for n, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        parts = line.split("|")[1:]
        rec = parts[0] if parts else ""
        if rec == "H":
            header = [h.strip().lower() for h in parts[1:]]
            if header and header[-1] == "":              # a header field is never blank: trailing delimiter
                header = header[:-1]
        elif rec == "T":
            trailer = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
        elif rec == "D":
            if header is None:
                raise ValueError(f"{src_file_name}: detail record before header (line {n})")
            vals = parts[1:]
            # A trailing '|' adds one empty element. Only the header length can tell it apart from a blank
            # optional LAST field (Is_Active), so strip it only when the row has exactly one field too many.
            if len(vals) == len(header) + 1 and vals[-1] == "":
                vals = vals[:-1]
            row = {c: None for c in RAW_COLS}
            for h, v in zip(header, vals):
                if h in row:
                    row[h] = _clean(v)
            row.update(src_file_name=src_file_name, src_row_number=n, batch_ts=batch_ts,
                       source_type="flat", field_count_ok=len(vals) == len(header))
            rows.append(row)
    df = pd.DataFrame(rows, columns=RAW_COLS + LINEAGE)
    info = {"header": header, "header_missing_vs_spec": [c for c in SPEC_HEADER if header and c not in header],
            "trailer_count": trailer, "detail_count": len(df), "file_name": src_file_name, "file_name_ok": file_name_ok}
    return df, info


EXCEL_DATE_COLS = {"enrollment_date": "YYYYMMDD", "last_flight_date": "YYYYMMDD", "dob": "DDMMYYYY"}
_STRFTIME = {"YYYYMMDD": "%Y%m%d", "DDMMYYYY": "%d%m%Y"}


def _excel_date(v, fmt: str):
    """Excel cell -> the flat file's compact date string (mirrors OPS.FN_XL_DATE_YMD / _DMY). Only this adapter
    accepts Excel serials and ISO dates. Unparseable values (2021-13-13) pass through unchanged so the strict
    staging rules reject them instead of silently turning them into NULL."""
    d, status = parse_date(v, fmt, lenient=True)
    return d.strftime(_STRFTIME[fmt]) if status == "ok" else None if status == "null" else v


def parse_excel_feed(path, country: str, batch_ts: datetime, namespace_ids: bool = True) -> pd.DataFrame:
    """Per-country Excel feed (own column names, Excel dates, 'NULL' strings, no country column).
    IDs in these files are local counters (1,2,3 in BOTH AUS and IND) -> namespaced '<CC>-<id>' so two
    different people are never merged, and never mistaken for a country move."""
    mapping = EXCEL_FEEDS[country]
    src = pd.read_excel(path, dtype=object)
    missing = [c for c in mapping if c not in src.columns]
    if missing:
        raise ValueError(f"{Path(path).name}: expected columns missing: {missing}")
    rows = []
    for i, r in src.iterrows():
        row = {c: None for c in RAW_COLS}
        for sc, cc in mapping.items():
            row[cc] = _clean(r[sc])
        for c, fmt in EXCEL_DATE_COLS.items():
            row[c] = _excel_date(row[c], fmt)
        row["country"] = country
        if namespace_ids and row["member_id"]:
            row["member_id"] = f"{country}-{row['member_id']}"
        row.update(src_file_name=Path(path).name, src_row_number=i + 2, batch_ts=batch_ts,
                   source_type="excel", field_count_ok=True)
        rows.append(row)
    return pd.DataFrame(rows, columns=RAW_COLS + LINEAGE)


def _json_text(v):
    """Keep a JSON scalar as the text it was written as (12.0 stays '12.0'). Leaving numbers as Python values
    lets pandas upcast the whole column to float as soon as one row has a fraction, turning 5000 into 5000.0."""
    return None if v is None else v if isinstance(v, str) else json.dumps(v)


def parse_redemptions(text: str, src_file_name: str) -> pd.DataFrame:
    """JSON feed (one document, array of documents, or NDJSON) -> one row per transaction.
    Equivalent of LATERAL FLATTEN. Members with no redemptions yield no rows."""
    text = text.strip()
    try:
        obj = json.loads(text)
        docs = obj if isinstance(obj, list) else [obj]
    except json.JSONDecodeError:
        docs = [json.loads(l) for l in text.splitlines() if l.strip()]
    rows = []
    for n, d in enumerate(docs, start=1):
        for t in d.get("redemptions") or []:
            rows.append({"member_id": _clean(d.get("member_id")), "feed_date": _clean(d.get("feed_date")), "source_country": _clean(d.get("source_country")),
                         "txn_id": _clean(t.get("txn_id")), "txn_date": _clean(t.get("txn_date")),
                         "partner": t.get("partner"), "miles_redeemed": _json_text(t.get("miles_redeemed")),
                         "status": _clean(t.get("status")), "src_file_name": src_file_name, "src_row_number": n})
    return pd.DataFrame(rows, columns=["member_id", "feed_date", "source_country", "txn_id", "txn_date", "partner",
                                       "miles_redeemed", "status", "src_file_name", "src_row_number"])
