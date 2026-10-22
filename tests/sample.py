"""Test fixtures: the assessment's sample feeds, read from data/raw so tests and demo share one copy."""
from datetime import datetime
from pathlib import Path

SAMPLES = Path(__file__).resolve().parent.parent / "data" / "raw"
FLAT = (SAMPLES / "SKYPOINTS_MEMBER_20240115_020000.dat").read_text()
JSON_DOC = (SAMPLES / "redemptions_20240115.json").read_text()
T1 = datetime(2024, 1, 15, 2, 0)
T2 = datetime(2024, 1, 16, 2, 0)

HDR = FLAT.splitlines()[0] + "\n"
