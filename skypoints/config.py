COUNTRY_ALIASES = {"IND": "IND", "IN": "IND", "USA": "USA", "US": "USA", "AUS": "AUS", "AU": "AUS",
                   "PHL": "PHL", "PHIL": "PHL", "PH": "PHL", "CAN": "CAN"}
COUNTRY_TABLES = {"IND": "TABLE_INDIA", "USA": "TABLE_USA", "AUS": "TABLE_AUSTRALIA",
                  "PHL": "TABLE_PHILIPPINES", "CAN": "TABLE_CANADA"}
TIERS = {"GLD", "SLV", "PLT"}
ACTIVE_FLAGS = {"A", "I"}
MEMBER_TYPES = {"I", "C"}   # IND feed: Individual / Corporate
REDEMPTION_STATUSES = {"COMPLETED", "PENDING", "CANCELLED", "REVERSED"}
STALE_DAYS = 90
# Nullable integer columns: pandas' Int64 keeps 38 as 38 (not 38.0) when another row is missing
INT_COLS = {c: "Int64" for c in ("age", "days_since_flight", "post_code")}

# File name spec (assumed - confirm with design doc): SKYPOINTS_MEMBER_YYYYMMDD_HHMMSS[TT].dat, TT = hundredths
MEMBER_FILE_PATTERN = r"SKYPOINTS_MEMBER_(\d{8})_(\d{6})(\d{2})?\.dat"

# Spec (design doc) field order/lengths. Header of the sample file omits Post_Code -> flagged.
SPEC_HEADER = ["member_name", "member_id", "enrollment_date", "last_flight_date", "tier_code", "agent_name",
               "state", "country", "post_code", "dob", "is_active"]
MAX_LEN = {"member_name": 255, "member_id": 18, "tier_code": 5, "agent_name": 255, "state": 5,
           "country": 5, "is_active": 1, "member_type": 1}
REDEMPTION_MAX_LEN = {"member_id": 18, "txn_id": 50, "partner": 100}
MAX_MILES = 10**12          # FACT_REDEMPTION.miles_redeemed is NUMBER(12,0)

RAW_COLS = ["member_name", "member_id", "enrollment_date", "last_flight_date", "tier_code", "agent_name",
            "state", "country", "post_code", "dob", "is_active", "member_type"]

# Per-country Excel feeds: source column -> canonical column. Country is implied by the file.
EXCEL_FEEDS = {
    "AUS": {"Unique ID": "member_id", "Member Name": "member_name", "Tier Type": "tier_code",
            "Date of Birth": "dob", "Date of Enrollment": "enrollment_date", "Date of Flight": "last_flight_date"},
    "IND": {"ID": "member_id", "Name": "member_name", "DOB": "dob", "TierCode": "tier_code",
            "EnrollmentDate": "enrollment_date", "Individual or Corporate": "member_type",
            "Flight Date": "last_flight_date"},
}
