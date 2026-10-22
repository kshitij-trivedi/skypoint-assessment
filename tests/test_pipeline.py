import sys, pathlib
from datetime import date, datetime
import pandas as pd
import pytest
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from sample import FLAT, HDR, JSON_DOC, SAMPLES, T1, T2
from skypoints.dates import parse_date, completed_years
from skypoints.parsers import parse_flat_file, parse_excel_feed, parse_redemptions, batch_ts_from_filename
from skypoints.staging import stage_member
from skypoints.transform import apply_batch, empty_state, latest_wins
from skypoints import validate, redemptions as rd

AS_OF = date(2024, 1, 15)


def flat_stage(text=FLAT, ts=T1, name="f1.dat"):
    raw, info = parse_flat_file(text, name, ts)
    return stage_member(raw, AS_OF), info


# ---------- dates / derived columns ----------
def test_date_parsing_kinds():
    assert parse_date("20101012") == (date(2010, 10, 12), "ok")
    assert parse_date("44562", lenient=True) == (date(2022, 1, 1), "ok")   # Excel serial: Excel adapter only
    assert parse_date("2022-01-01 00:00:00", lenient=True) == (date(2022, 1, 1), "ok")
    assert parse_date("44562")[1] == "invalid" and parse_date("2022-01-01")[1] == "invalid"   # strict = spec only
    assert parse_date("2021-13-13")[1] == "invalid"                         # impossible month
    assert parse_date("NULL")[1] == "null" and parse_date(None)[1] == "null"
    assert parse_date("3051985", "DDMMYYYY") == (date(1985, 5, 3), "ok")    # lost leading zero
    assert parse_date("31022020")[1] == "invalid"

def test_age_counts_completed_years():
    assert completed_years(date(1985, 5, 3), date(2024, 5, 2)) == 38
    assert completed_years(date(1985, 5, 3), date(2024, 5, 3)) == 39
    assert completed_years(None, AS_OF) is None

def test_stale_boundary_is_strictly_greater_than_90():
    raw, _ = parse_flat_file(FLAT, "f", T1)
    raw.loc[0, "last_flight_date"] = "20231017"   # exactly 90 days before 2024-01-15
    raw.loc[1, "last_flight_date"] = "20231016"   # 91 days
    raw.loc[2, "last_flight_date"] = None         # unknown
    s = stage_member(raw, AS_OF)
    assert list(s.stale_member[:3]) == [False, True, True]
    assert s.days_since_flight[0] == 90

# ---------- flat file / sample data issues ----------
def test_sample_flat_file_stages_and_standardises_country():
    s, info = flat_stage()
    assert (s.dq_status == "VALID").all()
    assert dict(zip(s.member_name, s.country_code)) == {"Elena": "USA", "Ravi": "IND", "Mateo": "PHL", "Nora": "CAN", "Jacob": "AUS"}
    assert s.dob[0] == date(1985, 5, 3) and s.age[0] == 38
    assert info["header_missing_vs_spec"] == ["post_code"]

def test_ragged_row_is_rejected_not_shifted():
    ragged = FLAT.replace("|D|Ravi|223458|20101012|20121013|SLV|Sam|TN|IND|03051985|A",
                          "|D|Ravi|223458|20101012|20121013|SLV|TN|IND|03051985|A")   # agent missing
    s, _ = flat_stage(ragged)
    assert "E_FIELD_COUNT_MISMATCH" in s[s.member_name == "Ravi"].dq_errors.iloc[0]
    assert s[s.member_name == "Ravi"].dq_status.iloc[0] == "REJECTED"

def test_blank_last_field_is_not_mistaken_for_a_trailing_delimiter():
    s, _ = flat_stage(FLAT + "|D|Zed|900001|20200101|20230101|GLD|Sam|CA|USA|03051985|\n")
    z = s[s.member_id == "900001"].iloc[0]
    assert z.dq_status == "VALID" and z.dq_errors == [] and z.is_active is None

def test_trailing_pipe_on_a_full_row_is_a_delimiter():
    s, _ = flat_stage(FLAT + "|D|Zed|900001|20200101|20230101|GLD|Sam|CA|USA|03051985|A|\n")
    z = s[s.member_id == "900001"].iloc[0]
    assert z.dq_status == "VALID" and z.is_active == "A"

def test_genuinely_short_row_is_still_rejected():
    s, _ = flat_stage(FLAT + "|D|Zed|900001|20200101|20230101|GLD|Sam|CA|USA\n")
    assert "E_FIELD_COUNT_MISMATCH" in s[s.member_id == "900001"].dq_errors.iloc[0]

def test_flat_file_dates_accept_only_the_spec_formats():
    for col, val, rule in [("enrollment_date", "44562", "E_INVALID_ENROLLMENT_DATE"),
                           ("enrollment_date", "2022-01-01", "E_INVALID_ENROLLMENT_DATE"),
                           ("last_flight_date", "2022-01-01", "E_INVALID_FLIGHT_DATE"),
                           ("dob", "1985-05-03", "E_INVALID_DOB")]:
        raw, _ = parse_flat_file(FLAT, "f", T1)
        raw.loc[0, col] = val
        assert rule in stage_member(raw, AS_OF).dq_errors[0], (col, val)

def test_mandatory_and_unknown_country_rejected():
    bad = FLAT + "|D||999|20200101||GLD|Sam|X|ZZZ|01011990|A\n|D|NoEnroll|998||20200101|GLD|Sam|X|IND|01011990|A\n"
    s, _ = flat_stage(bad)
    e = {r.member_id: r.dq_errors for r in s.itertuples()}
    assert "E_MANDATORY_MEMBER_NAME" in e["999"] and "E_UNKNOWN_COUNTRY" in e["999"]
    assert "E_MANDATORY_ENROLLMENT_DATE" in e["998"]

def test_profile_checks_catch_sample_anomalies():
    s, info = flat_stage()
    rules = {f["rule"] for f in validate.check_profile(s) + validate.check_header(info)}
    assert {"B_ID_LENGTH_OUTLIER", "B_DOB_PLACEHOLDER", "B_ALL_STALE", "B_COUNTRY_ALIAS_USED",
            "B_HEADER_MISSING_FIELDS"} <= rules

def test_batch_ts_comes_from_spec_file_name_including_hundredths():
    assert batch_ts_from_filename("in/SKYPOINTS_MEMBER_20240115_020000.dat") == datetime(2024, 1, 15, 2)
    assert batch_ts_from_filename("SKYPOINTS_MEMBER_20240115_02000045.dat") == datetime(2024, 1, 15, 2, 0, 0, 450000)
    assert batch_ts_from_filename("SKYPOINTS_MEMBER_20241315_020000.dat") is None      # month 13
    assert batch_ts_from_filename("members.csv") is None

def test_bad_file_name_rejects_rows_and_is_reported():
    raw, info = parse_flat_file(FLAT, "members_today.dat")
    s = stage_member(raw, AS_OF)
    assert (s.dq_status == "REJECTED").all() and all("E_MISSING_BATCH_TS" in e for e in s.dq_errors)
    assert "B_BAD_FILE_NAME" in {f["rule"] for f in validate.check_header(info)}

def test_field_values_lost_between_raw_and_staging_are_caught():
    raw, _ = parse_flat_file(FLAT, "f", T1)
    s = stage_member(raw, AS_OF)
    assert validate.check_field_reconciliation(raw, s) == []
    s.loc[1:, "agent_name"] = None              # what the assessment's staging table shows
    [f] = validate.check_field_reconciliation(raw, s)
    assert f["rule"] == "B_FIELD_DROPPED" and "agent_name filled on 5 raw rows but 1 staged" in f["detail"]

def test_trailer_count_mismatch():
    _, info = flat_stage(FLAT + "|T|7|\n")
    assert [f["rule"] for f in validate.check_header(info)].count("B_TRAILER_COUNT_MISMATCH") == 1

# ---------- latest wins / country moves ----------
def test_latest_record_wins_inside_batch():
    txt = FLAT + "|D|Ravi|223458|20101012|20240101|GLD|Sam|CA|USA|03051985|A\n"
    s, _ = flat_stage(txt)
    w = latest_wins(s)
    assert len(w) == 5 and w[w.member_id == "223458"].country_code.iloc[0] == "USA"

def test_member_moves_country_across_batches():
    t, reg = empty_state()
    s1, _ = flat_stage()
    t, reg, m1 = apply_batch(s1, t, reg)
    assert len(t["TABLE_INDIA"]) == 1
    moved = "|D|Ravi|223458|20101012|20240110|PLT|Sam|CA|USA|03051985|A\n"
    s2, _ = flat_stage(HDR + moved, T2, "f2.dat")
    t, reg, m2 = apply_batch(s2, t, reg)
    assert m2["moved_country"] == 1
    assert len(t["TABLE_INDIA"]) == 0 and "223458" in set(t["TABLE_USA"].member_id)
    assert validate.check_country_exclusivity(t) == []
    assert reg.set_index("member_id").loc["223458", "country_code"] == "USA"

def test_country_exclusivity_on_empty_targets_is_a_pass_not_a_crash():
    t, _ = empty_state()
    assert validate.check_country_exclusivity(t) == []

def test_old_file_replayed_late_cannot_overwrite_and_rerun_is_idempotent():
    t, reg = empty_state()
    s1, _ = flat_stage(); s2, _ = flat_stage(HDR + "|D|Ravi|223458|20101012|20240110|PLT|Sam|CA|USA|03051985|A\n", T2, "f2.dat")
    t, reg, _ = apply_batch(s1, t, reg); t, reg, _ = apply_batch(s2, t, reg)
    t, reg, m = apply_batch(s1, t, reg)                    # replay old file
    assert m["ignored_older"] == 1 and len(t["TABLE_INDIA"]) == 0
    before = {k: len(v) for k, v in t.items()}
    t, reg, _ = apply_batch(s2, t, reg)                    # replay newest: no-op
    assert {k: len(v) for k, v in t.items()} == before and len(reg) == 5

def test_rejected_rows_never_reach_targets():
    s, _ = flat_stage(FLAT + "|D|Bad|777|20101012||GLD|Sam|X|ZZZ|01011990|A\n")
    t, reg = empty_state(); t, reg, _ = apply_batch(s, t, reg)
    assert sum(len(v) for v in t.values()) == 5

# ---------- Excel feeds ----------
def test_excel_feeds_parse_and_flag_issues():
    aus = stage_member(parse_excel_feed(SAMPLES / "AUS.xlsx", "AUS", T1), AS_OF)
    ind = stage_member(parse_excel_feed(SAMPLES / "IND.xlsx", "IND", T1), AS_OF)
    j = aus[aus.member_name == "Jonnathan"].iloc[0]
    assert j.dq_status == "REJECTED" and j.dq_errors == ["E_INVALID_ENROLLMENT_DATE"]     # 2021-13-13
    m = aus[aus.member_name == "Mike"].iloc[0]
    assert m.dq_status == "VALID" and "W_MISSING_DOB" in m.dq_warnings                    # 'NULL' dob
    assert (ind.dq_status == "VALID").all() and set(ind.member_type) == {"I", "C"}
    assert ind[ind.member_name == "Vikas"].enrollment_date.iloc[0] == date(2022, 1, 1)

def test_unknown_member_type_is_warned_not_rejected():
    raw = parse_excel_feed(SAMPLES / "IND.xlsx", "IND", T1)
    raw.loc[0, "member_type"] = "x"
    s = stage_member(raw, AS_OF)
    assert s.dq_status.iloc[0] == "VALID" and "W_UNKNOWN_MEMBER_TYPE" in s.dq_warnings.iloc[0]
    assert not any("W_UNKNOWN_MEMBER_TYPE" in w for w in s.dq_warnings.iloc[1:])
    raw.loc[0, "member_type"] = "Corporate"            # target column is CHAR(1): must be rejected, not loaded
    assert stage_member(raw, AS_OF).dq_errors.iloc[0] == ["E_LENGTH_EXCEEDED"]

def test_excel_local_ids_are_namespaced_so_no_false_collision_or_move():
    s = pd.concat([stage_member(parse_excel_feed(SAMPLES / f"{c}.xlsx", c, T1), AS_OF) for c in ("AUS", "IND")])
    assert s.member_id.is_unique and validate.check_key_uniqueness(s) == []
    t, reg = empty_state(); t, reg, m = apply_batch(s, t, reg)
    assert m["moved_country"] == 0 and len(t["TABLE_INDIA"]) == 3 and len(t["TABLE_AUSTRALIA"]) == 2

def test_unnamespaced_ids_would_collide():
    s = pd.concat([stage_member(parse_excel_feed(SAMPLES / f"{c}.xlsx", c, T1, namespace_ids=False), AS_OF) for c in ("AUS", "IND")])
    assert any(f["rule"] == "B_ID_COLLISION" for f in validate.check_key_uniqueness(s))

# ---------- JSON redemptions ----------
def test_json_flatten_and_validate():
    flat = parse_redemptions(JSON_DOC, "r1.json")
    assert len(flat) == 2 and set(flat.txn_id) == {"RX10091", "RX10092"}
    good, bad = rd.stage_redemptions(flat)
    assert len(good) == 2 and bad.empty and good.miles_redeemed.sum() == 17000

def test_redemption_bad_rows_quarantined():
    doc = JSON_DOC.replace('"miles_redeemed": 5000', '"miles_redeemed": -5').replace('"COMPLETED"', '"DONE"')
    good, bad = rd.stage_redemptions(parse_redemptions(doc, "r.json"))
    assert good.empty and set(sum(bad.errors, [])) == {"E_INVALID_MILES", "E_UNKNOWN_STATUS"}

def test_redemption_values_that_would_overflow_the_fact_are_quarantined():
    doc = (JSON_DOC.replace('"miles_redeemed": 12000', '"miles_redeemed": 1000000000000')
                   .replace('"txn_id": "RX10092"', '"txn_id": "' + "R" * 51 + '"'))
    good, bad = rd.stage_redemptions(parse_redemptions(doc, "r.json"))
    assert good.empty
    assert [e for e in bad.errors] == [["E_INVALID_MILES"], ["E_LENGTH_EXCEEDED"]]

@pytest.mark.parametrize("miles", ["12.0", "12.5", "12.001", "-5", "0", "1000000000000", '"012"', '"+12"', "true"])
def test_miles_must_be_a_positive_whole_number_written_as_one(miles):
    doc = JSON_DOC.replace('"miles_redeemed": 12000', f'"miles_redeemed": {miles}')
    _, bad = rd.stage_redemptions(parse_redemptions(doc, "r.json"))
    assert bad.errors.tolist() == [["E_INVALID_MILES"]]

def test_largest_miles_value_that_fits_the_fact_is_accepted():
    doc = JSON_DOC.replace('"miles_redeemed": 12000', '"miles_redeemed": 999999999999')
    good, bad = rd.stage_redemptions(parse_redemptions(doc, "r.json"))
    assert bad.empty and 999999999999 in set(good.miles_redeemed)

def test_txn_id_reused_by_another_member_is_flagged():
    other = JSON_DOC.replace('"member_id": "223457"', '"member_id": "223458"')
    good, _ = rd.stage_redemptions(pd.concat([parse_redemptions(JSON_DOC, "a.json"), parse_redemptions(other, "b.json")]))
    assert {f["rule"] for f in validate.check_redemption_keys(good)} == {"B_TXN_ID_COLLISION"}
    assert validate.check_redemption_keys(rd.stage_redemptions(parse_redemptions(JSON_DOC, "a.json"))[0]) == []

def test_redemptions_before_any_member_load_are_orphans_not_a_crash():
    good, _ = rd.stage_redemptions(parse_redemptions(JSON_DOC, "a.json"))
    t, reg = empty_state()
    assert rd.enrich(rd.upsert_redemptions(pd.DataFrame(), good), reg, t).is_orphan.all()

def test_pending_becomes_completed_by_later_feed_and_join_back():
    g1, _ = rd.stage_redemptions(parse_redemptions(JSON_DOC, "r1.json"))
    later = JSON_DOC.replace("20240115", "20240120").replace('"PENDING"', '"COMPLETED"')
    g2, _ = rd.stage_redemptions(parse_redemptions(later, "r2.json"))
    fact = rd.upsert_redemptions(rd.upsert_redemptions(pd.DataFrame(), g1), g2)
    assert len(fact) == 2 and set(fact.status) == {"COMPLETED"}
    # an out-of-order OLD feed must not roll the status back
    fact = rd.upsert_redemptions(fact, g1)
    assert set(fact.status) == {"COMPLETED"}
    s, _ = flat_stage(); t, reg = empty_state(); t, reg, _ = apply_batch(s, t, reg)
    orphan = fact.iloc[[0]].assign(txn_id="RX9", member_id="000000")
    e = rd.enrich(pd.concat([fact, orphan], ignore_index=True), reg, t)
    assert e[e.member_id == "223457"].country_code.eq("USA").all()
    assert e[e.member_id == "000000"].is_orphan.all() and not e[e.member_id == "223457"].is_orphan.any()


# ---------- Post_Code (in spec, absent from the sample header) ----------
def test_post_code_absent_from_header_is_null_not_an_error():
    s, _ = flat_stage()
    assert s.post_code.isna().all() and (s.dq_status == "VALID").all()

def test_post_code_mapped_by_header_name_when_present():
    txt = ("|H|Member_Name|Member_Id|Enrollment_Date|Last_Flight_Date|Tier_Code|Agent_Name|State|Country|Post_Code|DOB|Is_Active\n"
           "|D|Elena|223457|20101012|20121013|GLD|Sam|CA|USA|94105|03051985|A\n"
           "|D|Ravi|223458|20101012|20121013|SLV|Sam|TN|IND|ABC12|03051985|A\n"
           "|D|Mateo|223459|20101012|20121013|GLD|Sam|NCR|PHIL|1234567|03051985|A\n")
    s, info = flat_stage(txt)
    assert info["header_missing_vs_spec"] == []
    assert s.post_code[0] == 94105 and s.dob[0] == date(1985, 5, 3)          # DOB not shifted by the extra column
    assert pd.isna(s.post_code[1]) and "W_INVALID_POST_CODE" in s.dq_warnings[1]
    assert pd.isna(s.post_code[2]) and "W_INVALID_POST_CODE" in s.dq_warnings[2]
    t, reg = empty_state(); t, reg, _ = apply_batch(s, t, reg)
    assert t["TABLE_USA"].post_code.iloc[0] == 94105                           # reaches the country table


# ---------- redemptions for Excel-fed (namespaced) members ----------
def test_redemption_with_source_country_joins_to_namespaced_excel_member():
    stg = pd.concat([stage_member(parse_excel_feed(SAMPLES / "AUS.xlsx", "AUS", T1), AS_OF),
                     stage_member(parse_excel_feed(SAMPLES / "IND.xlsx", "IND", T1), AS_OF)])
    t, reg = empty_state(); t, reg, _ = apply_batch(stg, t, reg)
    doc = JSON_DOC.replace('"223457"', '"1", "source_country": "AUS"')
    good, bad = rd.stage_redemptions(parse_redemptions(doc, "r.json"))
    assert bad.empty and set(good.member_id) == {"AUS-1"}
    e = rd.enrich(good, reg, t)
    assert e.member_name.eq("Mike").all() and e.country_code.eq("AUS").all() and not e.is_orphan.any()
    # same id without source_country is NOT guessed: it is an orphan, never a wrong match
    g2, _ = rd.stage_redemptions(parse_redemptions(JSON_DOC.replace('"223457"', '"1"'), "r2.json"))
    assert rd.enrich(g2, reg, t).is_orphan.all()
