"""Migration 306 (staging optimization plan §10.35 F): the demand reconciler
keeps its hourly schedule; normal runs reconcile 6 hours and a wide 58-hour
pass runs every 6 hours.

analytics.reconcile_demand_intervals uses wide_window instead of
reconcile_window unless a successful (HEALTHY / REPAIRED) demand_intervals run
with at least wide_window was logged within the last wide_every (30-minute
tolerance), so a skipped or failed wide pass is retried by the next run.
Without the wide keys the procedure behaves as before; invalid wide
configuration raises 22023 at alter_job time (the job's own check_config
validator) and at run time.

Procedure-level tests run in one rolled-back transaction each and start from an
empty demand_intervals reconciliation log. The end-to-end test commits its
fixture (recovery and the late-sweep job commit) and deletes it afterwards.
"""
import difflib
import re
import time
import uuid
from datetime import timedelta
from pathlib import Path

import psycopg
import psycopg.types.json
import pytest

from tests.test_routing_forward_floor_late_sweep import CONNINFO, _now, _one, _set_ckpt, _state

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "306_demand_reconcile_wide_cadence.sql"
MIGRATION_213 = REPO / "postgres" / "migrations" / "213_analytical_reconciliation.sql"
ROLLBACK_SQL = REPO / "postgres" / "maintenance" / "306_demand_reconcile_wide_cadence_rollback.sql"

MIGRATION_ID = "306_demand_reconcile_wide_cadence"
PROC = "analytics.reconcile_demand_intervals(integer,jsonb)"
CHECK = "config.assert_demand_reconciliation_job_config(jsonb)"
BODY_MD5_213 = "c2492b9d357c59aa0fa0cc97dd70f70e"
BODY_MD5_306 = "4b9820743f6ecddcbb89051269faf6e0"
SHARED_CHECK_MD5 = "897a9771d434a64fc873cfa23217e878"
JOB_CONFIG = {"lookback": "3 hours", "reconcile_window": "6 hours", "wide_window": "58 hours", "wide_every": "6 hours"}
FORWARD_LOCK = "analytics.run_demand_calculation_job"
NARROW, WIDE = timedelta(hours=6), timedelta(hours=58)
JOBS = (
    "reconcile_demand_intervals",
    "run_demand_calculation_job",
    "run_normalization_job",
    "run_energy_routing_job",
    "run_environment_routing_job",
    "run_routing_late_sweep_job",
    "run_failed_message_recovery_job",
    "run_raw_message_failure_capture_job",
)


@pytest.fixture(scope="module", autouse=True)
def quiesce_jobs():
    """Pause the demand jobs and the ingest / routing / recovery jobs for this
    module; restore their scheduled state afterwards."""
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        jobs = c.execute(
            """
            SELECT j.job_id, j.scheduled, s.next_start
            FROM timescaledb_information.jobs AS j
            JOIN timescaledb_information.job_stats AS s USING (job_id)
            WHERE j.proc_name = ANY(%s)
            """,
            (list(JOBS),),
        ).fetchall()
        for job_id, _, _ in jobs:
            c.execute("SELECT alter_job(%s, scheduled => false)", (job_id,))
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and c.execute(
            "SELECT count(*) FROM timescaledb_information.job_stats WHERE job_id = ANY(%s) AND job_status = 'Running'",
            ([j[0] for j in jobs],),
        ).fetchone()[0]:
            time.sleep(1)
    yield
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        for job_id, scheduled, next_start in jobs:
            if scheduled:
                c.execute("SELECT alter_job(%s, scheduled => true, next_start => %s)", (job_id, next_start))


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as conn:
        try:
            yield conn
        finally:
            conn.rollback()


@pytest.fixture
def clean(tx):
    """An empty demand_intervals reconciliation log and a current checkpoint."""
    tx.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals'")
    cp = _now(tx).replace(second=0, microsecond=0) - timedelta(minutes=15)
    if _state(tx, "demand_intervals") is None:
        tx.execute("INSERT INTO telemetry.pipeline_state (pipeline_name, last_received_at, last_status) "
                   "VALUES ('demand_intervals', %s, 'SUCCESS')", (cp,))
    _set_ckpt(tx, "demand_intervals", cp)
    return tx


def _call(conn, config=JOB_CONFIG):
    conn.execute("CALL analytics.reconcile_demand_intervals(0, %s::jsonb)", (psycopg.types.json.Jsonb(config),))
    return _last(conn)


def _last(conn):
    """(outcome, window length, window_end) of the newest demand_intervals log row."""
    return _one(conn, "SELECT outcome, window_end - window_start, window_end FROM analytics.pipeline_reconciliation_log "
                      "WHERE tier = 'demand_intervals' ORDER BY ran_at DESC LIMIT 1")


def _log(conn, age, window, outcome="HEALTHY"):
    """A past demand_intervals run, `age` ago, over `window` (None: no window, as
    a SKIPPED_LOCKED / NO_CHECKPOINT run logs it)."""
    cp = _now(conn) - age
    conn.execute(
        "SELECT analytics.record_reconciliation_run(gen_random_uuid(), 'demand_intervals', %s, %s, %s, "
        "NULL, NULL, NULL, 0, %s, %s, NULL, NULL)",
        (cp, None if window is None else cp - window, None if window is None else cp,
         1 if outcome == "FAILED" else 0, outcome),
    )


def _job(conn):
    return _one(conn, "SELECT job_id, config, check_schema, check_name, schedule_interval, fixed_schedule, max_runtime, "
                      "max_retries, retry_period FROM timescaledb_information.jobs WHERE proc_name = 'reconcile_demand_intervals'")


# ---------------------------------------------------------------------------
# Deployed objects
# ---------------------------------------------------------------------------


def test_deployed_body_job_and_validator(tx):
    md5, secdef, owner = _one(tx, "SELECT md5(replace(prosrc, E'\\r', '')), prosecdef, pg_get_userbyid(proowner) "
                                  "FROM pg_proc WHERE oid = %s::regprocedure", (PROC,))
    assert (md5, secdef, owner) == (BODY_MD5_306, True, "ems_admin")
    assert _one(tx, "SELECT count(*) FROM admin.schema_migrations WHERE migration_id = %s", (MIGRATION_ID,))[0] == 1
    assert tx.execute("SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name = 'reconcile_demand_intervals'"
                      ).fetchone()[0] == 1
    _, config, check_schema, check_name, sched, fixed, mrt, retries, rp = _job(tx)
    assert config == JOB_CONFIG
    assert (check_schema, check_name) == ("config", "assert_demand_reconciliation_job_config")
    assert (sched, fixed, mrt, retries, rp) == (timedelta(hours=1), True, timedelta(minutes=10), 3, timedelta(minutes=15))
    # The shared validator of the other nine reconcilers is unchanged and still
    # refuses the wide keys (they would be silently ignored there).
    assert _one(tx, "SELECT md5(replace(prosrc, E'\\r', '')) FROM pg_proc "
                    "WHERE oid = 'config.assert_reconciliation_job_config(jsonb)'::regprocedure")[0] == SHARED_CHECK_MD5
    others = tx.execute("SELECT DISTINCT check_name FROM timescaledb_information.jobs "
                        "WHERE proc_name ~ '^reconcile_' AND proc_name <> 'reconcile_demand_intervals'").fetchall()
    assert others == [("assert_reconciliation_job_config",)]
    with pytest.raises(psycopg.errors.RaiseException, match='unrecognised key "wide_'):
        with tx.transaction():
            tx.execute("SELECT config.assert_reconciliation_job_config(%s::jsonb)", (psycopg.types.json.Jsonb(JOB_CONFIG),))
    owner, = _one(tx, "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = %s::regprocedure", (CHECK,))
    assert owner == "ems_admin"
    for role in ("public", "ems_app", "grafana_reader"):
        assert _one(tx, "SELECT has_function_privilege(%s, %s, 'EXECUTE')", (role, CHECK))[0] is False
        assert _one(tx, "SELECT has_function_privilege(%s, %s, 'EXECUTE')", (role, PROC))[0] is False


def _body(text, marker):
    start = text.index(marker)
    start = text.index("AS $procedure$", start) + len("AS $procedure$")
    return text[start:text.index("$procedure$", start)]


def test_migration_body_is_the_213_body_plus_only_inserted_306_blocks(tx):
    marker = "CREATE OR REPLACE PROCEDURE analytics.reconcile_demand_intervals"
    old = _body(MIGRATION_213.read_text(encoding="utf-8"), marker).splitlines(keepends=True)
    new = _body(MIGRATION.read_text(encoding="utf-8"), marker)
    assert new == _one(tx, "SELECT replace(prosrc, E'\\r', '') FROM pg_proc WHERE oid = %s::regprocedure", (PROC,))[0]
    ops = difflib.SequenceMatcher(None, old, new.splitlines(keepends=True), autojunk=False).get_opcodes()
    inserted = [new.splitlines(keepends=True)[j1:j2] for tag, _, _, j1, j2 in ops if tag != "equal"]
    assert {tag for tag, *_ in ops} == {"equal", "insert"}           # nothing of the 213 body removed or changed
    assert len(inserted) == 3
    assert all("Migration 306" in "".join(block) for block in inserted)
    assert "EXECUTE " not in new and "format(" not in new


def test_manifest_registers_migration_306_last():
    import csv

    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    migrations = [r for r in rows if r["target_category"] == "migration"]
    assert migrations[-1]["source_file"] == "306_demand_reconcile_wide_cadence.sql"
    assert migrations[-1]["target_path"] == "postgres/migrations/306_demand_reconcile_wide_cadence.sql"
    assert migrations[-2]["source_file"] == "305_routing_recovery_queue.sql"


def test_health_view_still_has_one_demand_row(tx):
    rows = tx.execute("SELECT reconcile_job FROM analytics.v_pipeline_health WHERE pipeline = 'demand_intervals'").fetchall()
    assert rows == [("analytics.reconcile_demand_intervals",)]


# ---------------------------------------------------------------------------
# Cadence
# ---------------------------------------------------------------------------


def test_first_run_is_wide_and_the_next_is_narrow(clean):
    # The outcome depends on what other suites left in the database (a wide pass
    # may legitimately repair their intervals); the cadence is what is pinned.
    cp = _state(clean, "demand_intervals")[0]
    for expected in (WIDE, NARROW, NARROW):
        outcome, window, window_end = _call(clean)
        assert outcome in ("HEALTHY", "REPAIRED") and (window, window_end) == (expected, cp)


@pytest.mark.parametrize(
    ("age", "expected"),
    [
        (timedelta(hours=1), NARROW),
        (timedelta(hours=5, minutes=29), NARROW),
        (timedelta(hours=5, minutes=31), WIDE),     # 30-minute tolerance: the 6-hourly slot is wide
        (timedelta(hours=6), WIDE),
        (timedelta(hours=7), WIDE),
    ],
)
def test_wide_pass_every_six_hours(clean, age, expected):
    _log(clean, age, WIDE)
    assert _call(clean)[1] == expected


def test_hourly_cadence_gives_one_wide_pass_in_six(clean):
    """Simulated hourly runs at :59 for 24 h: the wide pass at 0, 6, 12, 18 h."""
    windows = []
    for hour in range(24):
        # Shift the log back one hour per simulated run (ran_at is immutable in a
        # hypertable, so the rows are re-inserted at their new age).
        rows = clean.execute("SELECT now() - ran_at, window_end - window_start, outcome FROM analytics.pipeline_reconciliation_log "
                             "WHERE tier = 'demand_intervals'").fetchall()
        clean.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals'")
        for age, window, outcome in rows:
            _log(clean, age + timedelta(hours=1), window, outcome)
        windows.append(_call(clean)[1])
    assert [h for h, w in enumerate(windows) if w == WIDE] == [0, 6, 12, 18]
    assert all(w == NARROW for w in windows if w != WIDE)


def test_repaired_counts_as_a_successful_wide_pass(clean):
    _log(clean, timedelta(hours=2), WIDE, "REPAIRED")
    assert _call(clean)[1] == NARROW


def test_narrow_and_wider_runs(clean):
    _log(clean, timedelta(minutes=10), NARROW)                  # narrow runs never count as the wide pass
    assert _call(clean)[1] == WIDE
    clean.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals'")
    _log(clean, timedelta(hours=1), timedelta(hours=72))         # a longer window does
    assert _call(clean)[1] == NARROW


@pytest.mark.parametrize("outcome", ["FAILED", "SKIPPED_LOCKED", "NO_CHECKPOINT"])
def test_an_unsuccessful_wide_slot_is_retried_by_the_next_run(clean, outcome):
    _log(clean, timedelta(hours=7), WIDE)                        # last successful wide pass: due now
    _log(clean, timedelta(hours=1), WIDE if outcome == "FAILED" else None, outcome)
    assert _call(clean)[1] == WIDE


def test_lock_skip_then_the_next_run_is_wide(clean):
    with psycopg.connect(CONNINFO, autocommit=True) as holder:
        holder.execute("SELECT pg_advisory_lock(hashtextextended(%s, 0))", (FORWARD_LOCK,))
        try:
            outcome, window, _ = _call(clean)
        finally:
            holder.execute("SELECT pg_advisory_unlock(hashtextextended(%s, 0))", (FORWARD_LOCK,))
    assert (outcome, window) == ("SKIPPED_LOCKED", None)
    assert _call(clean)[1] == WIDE
    assert _call(clean)[1] == NARROW


def test_no_checkpoint_then_the_next_run_is_wide(clean):
    _set_ckpt(clean, "demand_intervals", None)
    assert _call(clean)[:2] == ("NO_CHECKPOINT", None)
    _set_ckpt(clean, "demand_intervals", _now(clean) - timedelta(minutes=15))
    assert _call(clean)[1] == WIDE


def test_a_failed_wide_run_is_logged_failed_and_retried(clean):
    """A failure inside the refresh (caught and logged FAILED by the procedure)."""
    clean.execute("CREATE FUNCTION pg_temp.t306_fail() RETURNS trigger LANGUAGE plpgsql AS "
                  "$$BEGIN RAISE EXCEPTION 't306 injected failure'; END$$")
    clean.execute("CREATE TRIGGER t306_fail BEFORE INSERT OR UPDATE ON analytics.demand_intervals "
                  "FOR EACH ROW EXECUTE FUNCTION pg_temp.t306_fail()")
    fx = _demand_fixture(clean, "FAIL")
    _energy(clean, fx, _bucket_at(clean, timedelta(hours=30)), 15)
    outcome, window, _ = _call(clean)
    assert (outcome, window) == ("FAILED", WIDE)
    clean.execute("DROP TRIGGER t306_fail ON analytics.demand_intervals")
    assert _call(clean)[:2] in (("HEALTHY", WIDE), ("REPAIRED", WIDE))
    assert _call(clean)[1] == NARROW


def test_without_wide_keys_the_behaviour_is_unchanged(clean):
    _log(clean, timedelta(hours=1), WIDE)
    for config, expected in (
        ({"lookback": "3 hours", "reconcile_window": "48 hours"}, timedelta(hours=48)),   # the 305 config
        ({"lookback": "3 hours", "reconcile_window": "6 hours"}, NARROW),
        ({}, NARROW),                                                                    # the procedure default
        # keys the procedure never read stay unchecked at run time, as before 306
        ({"reconcile_window": "6 hours", "n_max": "not read by this procedure"}, NARROW),
    ):
        clean.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals'")
        assert _call(clean, config)[1] == expected
        assert _call(clean, config)[1] == expected                # no log-driven switching at all


# ---------------------------------------------------------------------------
# Configuration validation: rejected at alter_job and at run time, never ignored
# ---------------------------------------------------------------------------

INVALID = [
    ({"wide_window": "58 hours"}, "must be configured together"),
    ({"wide_every": "6 hours"}, "must be configured together"),
    ({"wide_window": 58, "wide_every": "6 hours"}, "wide_window must be an interval string"),
    ({"wide_window": None, "wide_every": "6 hours"}, "wide_window must be an interval string"),
    ({"wide_window": "banana", "wide_every": "6 hours"}, "wide_window must be an interval string"),
    ({"wide_window": "58 hours", "wide_every": ["6 hours"]}, "wide_every must be an interval string"),
    ({"wide_window": "58 hours", "wide_every": "30 minutes"}, r"wide_every \(00:30:00\) must be at least 1 hour"),
    ({"wide_window": "6 hours", "wide_every": "2 hours"}, r"must be longer than reconcile_window \(06:00:00\)"),
    ({"reconcile_window": "12 hours", "wide_window": "10 hours", "wide_every": "6 hours"}, "must be longer than reconcile_window"),
    ({"reconcile_window": "1 hour", "wide_window": "6 hours", "wide_every": "6 hours"}, r"must be longer than wide_every \(06:00:00\)"),
]


@pytest.mark.parametrize(("bad", "message"), INVALID)
def test_invalid_wide_config_fails_the_run_and_logs_nothing(clean, bad, message):
    config = {"lookback": "3 hours", **bad}
    with pytest.raises(psycopg.errors.InvalidParameterValue, match=message):
        with clean.transaction():
            _call(clean, config)
    assert _last(clean) is None


@pytest.mark.parametrize(("bad", "message"), INVALID)
def test_invalid_wide_config_is_rejected_by_alter_job(tx, bad, message):
    job_id, before, *_ = _job(tx)
    with pytest.raises(psycopg.errors.InvalidParameterValue, match=message):
        with tx.transaction():
            tx.execute("SELECT alter_job(%s, config => %s::jsonb)", (job_id, psycopg.types.json.Jsonb({"lookback": "3 hours", **bad})))
    assert _job(tx)[1] == before


def test_alter_job_still_applies_the_shared_rules(tx):
    job_id, *_ = _job(tx)
    for bad in ({**JOB_CONFIG, "n_max": "x"}, {**JOB_CONFIG, "unknown": "1"}, {**JOB_CONFIG, "reconcile_window": "-1 hour"}):
        with pytest.raises(psycopg.errors.RaiseException):
            with tx.transaction():
                tx.execute("SELECT alter_job(%s, config => %s::jsonb)", (job_id, psycopg.types.json.Jsonb(bad)))
    tx.execute("SELECT alter_job(%s, config => %s::jsonb)", (job_id, psycopg.types.json.Jsonb(
        {"lookback": "3 hours", "reconcile_window": "6 hours", "wide_window": "72 hours", "wide_every": "12 hours"})))
    tx.execute("SELECT alter_job(%s, config => %s::jsonb)", (job_id, psycopg.types.json.Jsonb(
        {"lookback": "3 hours", "reconcile_window": "48 hours"})))       # removing the pair is valid (305 behaviour)


# ---------------------------------------------------------------------------
# Re-finalisation and coverage of the recoverable range
# ---------------------------------------------------------------------------


def _demand_fixture(conn, tag, commit=False):
    """Org / site (automatic ASSET demand policy) / gateway / Eniscope meter
    (Energy Meter model) / asset bound by PRIMARY_METER and an ACTIVE_POWER_TOTAL
    asset_points row -- what routed energy rows (asset_id NULL) resolve through."""
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw", "dev", "asset", "model")}
    ids["uid"] = f"T306:{tag}:{uuid.uuid4().hex[:6]}"
    prof = _one(conn, "SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")[0]
    lp = _one(conn, "SELECT id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL'")[0]
    cat = _one(conn, "SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1")[0]
    code = ids["uid"].replace(":", "_").upper()
    conn.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)", (ids["org"], code, code + "_ORG"))
    conn.execute("INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, %s, %s)",
                 (ids["site"], ids["org"], code, code + "_SITE"))
    conn.execute("INSERT INTO config.telemetry_capture_policies (site_id, capture_interval_seconds, alignment_mode, "
                 "late_arrival_tolerance_seconds, effective_from, is_enabled) VALUES (%s, 60, 'WALL_CLOCK', 60, now() - INTERVAL '90 days', TRUE)",
                 (ids["site"],))
    conn.execute("INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
                 (ids["gw"], ids["org"], ids["site"], code + " GW", code + "-GW"))
    conn.execute("INSERT INTO metadata.device_models (id, vendor, model, device_type, device_category_id) "
                 "VALUES (%s, 'WiseWatts Test', %s, 'Energy Meter', %s)", (ids["model"], code, cat))
    with conn.transaction():
        conn.execute("INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id, profile_id, device_model_id) "
                     "VALUES (%s, %s, %s, %s, %s, %s, %s)", (ids["dev"], ids["org"], ids["gw"], ids["uid"], ids["uid"], prof, ids["model"]))
        conn.execute("SELECT set_config('ems.controlled_device_commissioning_id', %s, true)", (str(ids["dev"]),))
        conn.execute("UPDATE metadata.devices SET lifecycle_status = 'ACTIVE' WHERE id = %s", (ids["dev"],))
    conn.execute("INSERT INTO metadata.device_identifiers (device_id, identifier_type, identifier_value) VALUES (%s, 'MQTT_UID', %s)",
                 (ids["dev"], ids["uid"]))
    conn.execute("INSERT INTO metadata.assets (id, organization_id, site_id, name, status, metering_requirement) "
                 "VALUES (%s, %s, %s, %s, 'active', 'DIRECT_METER_REQUIRED')", (ids["asset"], ids["org"], ids["site"], code))
    conn.execute("INSERT INTO metadata.asset_devices (asset_id, device_id, relationship_type) VALUES (%s, %s, 'PRIMARY_METER')",
                 (ids["asset"], ids["dev"]))
    conn.execute("INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from) "
                 "VALUES (%s, %s, %s, %s, now() - INTERVAL '90 days')", (ids["asset"], ids["dev"], lp, ids["org"]))
    return ids


def _bucket_at(conn, age_from_cp):
    cp = _state(conn, "demand_intervals")[0]
    return _one(conn, "SELECT date_bin('15 minutes', %s::timestamptz, TIMESTAMPTZ '2000-01-01 00:00:00+00')",
                (cp - age_from_cp,))[0]


def _energy(conn, ids, b0, minutes, watts=12000):
    """Routed-style 1-minute energy rows (asset_id NULL, as the loaders write)."""
    conn.execute(
        "INSERT INTO telemetry.energy_measurements (bucket_start, received_at, source_timestamp, organization_id, site_id, "
        "gateway_id, device_id, asset_id, measurement_interval_seconds, quality_code, is_estimated, active_power_total_w) "
        "SELECT %s + n * INTERVAL '1 minute', %s + n * INTERVAL '1 minute' + INTERVAL '5 seconds', %s + n * INTERVAL '1 minute', "
        "%s, %s, %s, %s, NULL, 60, 0, FALSE, %s FROM generate_series(0, %s - 1) AS n",
        (b0, b0, b0, ids["org"], ids["site"], ids["gw"], ids["dev"], watts, minutes),
    )


def _interval(conn, ids, b0):
    return _one(conn, "SELECT quality_status, demand_kw, finalized_at FROM analytics.demand_intervals "
                      "WHERE asset_id = %s AND scope_type = 'ASSET' AND interval_start = %s", (ids["asset"], b0))


def test_recovered_energy_beyond_six_hours_is_refinalized_by_the_wide_pass_only(clean):
    fx = _demand_fixture(clean, "REFIN")
    b0 = _bucket_at(clean, timedelta(hours=30))
    _log(clean, timedelta(hours=7), WIDE)
    _call(clean)                                               # wide pass: the interval is finalised NO_DATA
    assert _interval(clean, fx, b0)[0] == "NO_DATA"
    _energy(clean, fx, b0, 15)                                 # the recovered energy arrives
    assert _call(clean)[1] == NARROW
    assert _interval(clean, fx, b0)[0] == "NO_DATA"            # out of reach of the hourly 6-hour window
    _log(clean, timedelta(hours=7), WIDE)
    clean.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals' AND ran_at > now() - INTERVAL '6 hours'")
    assert _call(clean)[:2] == ("REPAIRED", WIDE)
    status, kw, finalized = _interval(clean, fx, b0)
    assert (status, float(kw)) == ("VALID", 12.0)
    # VALID rows are frozen: the next wide pass leaves the row byte-identical.
    clean.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals'")
    assert _call(clean)[1] == WIDE
    assert _interval(clean, fx, b0) == (status, kw, finalized)


@pytest.mark.parametrize(("wide_window", "covered"), [("58 hours", True), ("48 hours", False)])
def test_the_wide_window_covers_the_oldest_recoverable_interval(clean, wide_window, covered):
    """Oldest recoverable interval at the latest wide pass that sees it: raw
    retention 48 h + routing <= 43 min + up to 6 h to the next wide pass + 1 h
    retry slack + checkpoint lag 30 min = 56 h 13 min before the checkpoint.
    58 hours reaches it; the 305 window of 48 hours does not."""
    fx = _demand_fixture(clean, "EDGE")
    b0 = _bucket_at(clean, timedelta(hours=56, minutes=13))
    _energy(clean, fx, b0, 15)
    _call(clean, {**JOB_CONFIG, "wide_window": wide_window})
    row = _interval(clean, fx, b0)
    assert (row is not None and row[0] == "VALID") is covered


# ---------------------------------------------------------------------------
# End to end: quarantined message -> recovery (1077 body) -> queue -> late-sweep
# job (1142) -> energy -> demand reconciler (wide pass)
# ---------------------------------------------------------------------------


def _quarantine(c, ids, event, watts):
    msg = _one(
        c,
        "INSERT INTO telemetry.raw_messages (received_at, source_protocol, source_topic, payload) "
        "VALUES (%s, 'MQTT', 'test/t306', jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object("
        "'uid', %s::text, 'ts', extract(epoch FROM %s::timestamptz)::text, 'P', %s::numeric, 'E', %s::numeric)))) RETURNING id",
        (event, ids["uid"], event, watts, 1000.0 + event.minute),
    )[0]
    c.execute(
        "INSERT INTO telemetry.raw_message_failures (raw_received_at, raw_message_id, failure_code, source_protocol, "
        "source_identifier, payload) VALUES (%s, %s, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', %s, "
        "jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', %s::text))))",
        (event, msg, ids["uid"], ids["uid"]),
    )
    return msg


def _cleanup(c, ids, msgs, started):
    c.execute("DELETE FROM analytics.demand_intervals WHERE site_id = %s", (ids["site"],))
    c.execute("DELETE FROM analytics.demand_state WHERE site_id = %s", (ids["site"],))
    c.execute("DELETE FROM telemetry.routing_recovery_queue WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM telemetry.energy_measurements WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM telemetry.normalized_points WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM telemetry.capture_bucket_samples WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM telemetry.raw_message_failures WHERE raw_message_id = ANY(%s)", (msgs,))
    c.execute("DELETE FROM telemetry.raw_messages WHERE id = ANY(%s)", (msgs,))
    c.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals' AND ran_at >= %s", (started,))
    for table in ("telemetry.device_point_state", "telemetry.device_telemetry_state", "telemetry.device_live_point_state",
                  "metadata.device_identifiers", "metadata.asset_points", "metadata.asset_devices"):
        c.execute(f"DELETE FROM {table} WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM metadata.assets WHERE id = %s", (ids["asset"],))
    c.execute("DELETE FROM metadata.devices WHERE id = %s", (ids["dev"],))
    c.execute("DELETE FROM metadata.device_models WHERE id = %s", (ids["model"],))
    c.execute("DELETE FROM metadata.gateways WHERE id = %s", (ids["gw"],))
    c.execute("DELETE FROM config.site_demand_policies WHERE site_id = %s", (ids["site"],))
    c.execute("DELETE FROM metadata.sites WHERE id = %s", (ids["site"],))
    c.execute("DELETE FROM metadata.organizations WHERE id = %s", (ids["org"],))


def test_end_to_end_recovered_messages_reach_demand_through_the_wide_pass():
    names = [f"{p}{s}" for p in ("energy_measurements", "environment_measurements") for s in ("", "_late_sweep", "_recovery")]
    names.append("demand_intervals")
    msgs = []
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        started = _now(c)
        saved = c.execute(
            "SELECT pipeline_name, last_received_at, last_status, last_started_at, last_completed_at, last_inserted_rows, "
            "last_error FROM telemetry.pipeline_state WHERE pipeline_name = ANY(%s)", (names,)).fetchall()
        ids = _demand_fixture(c, "E2E")
        try:
            # 15 one-minute messages of one demand interval, 47 hours old (inside
            # the 48-hour raw retention), quarantined as 1068 would.
            b0 = _one(c, "SELECT date_bin('15 minutes', now() - INTERVAL '47 hours', TIMESTAMPTZ '2000-01-01 00:00:00+00')")[0]
            for n in range(15):
                msgs.append(_quarantine(c, ids, b0 + timedelta(minutes=n, seconds=10), 12000))
            for name in ("energy_measurements", "energy_measurements_late_sweep"):
                c.execute("UPDATE telemetry.pipeline_state SET last_received_at = now() - INTERVAL '1 minute' WHERE pipeline_name = %s", (name,))

            c.execute("CALL telemetry.recover_failed_raw_messages(100)")
            assert _one(c, "SELECT count(*) FILTER (WHERE resolution_status = 'RECOVERED'), count(*) FROM telemetry.raw_message_failures "
                           "WHERE raw_message_id = ANY(%s)", (msgs,)) == (15, 15)
            c.execute("CALL telemetry.run_routing_late_sweep_job(0, '{\"max_window\": \"1 day\"}'::jsonb)")
            assert _one(c, "SELECT count(*) FROM telemetry.energy_measurements WHERE device_id = %s AND bucket_start >= %s "
                           "AND bucket_start < %s AND active_power_total_w IS NOT NULL",
                        (ids["dev"], b0, b0 + timedelta(minutes=15)))[0] == 15

            # The demand reconciler, in a rolled-back transaction of its own.
            with psycopg.connect(CONNINFO) as tx:
                try:
                    tx.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals'")
                    _set_ckpt(tx, "demand_intervals", _now(tx).replace(second=0, microsecond=0) - timedelta(minutes=15))
                    _log(tx, timedelta(hours=1), WIDE)                     # a wide pass ran an hour ago
                    assert _call(tx)[1] == NARROW
                    assert _interval(tx, ids, b0) is None                  # the hourly run cannot reach 47 h
                    tx.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals'")
                    _log(tx, timedelta(hours=6), WIDE)                     # the 6-hourly slot
                    assert _call(tx)[1] == WIDE
                    status, kw, _ = _interval(tx, ids, b0)
                    assert status == "VALID" and float(kw) > 0
                finally:
                    tx.rollback()
        finally:
            _cleanup(c, ids, msgs, started)
            for row in saved:
                c.execute(
                    "UPDATE telemetry.pipeline_state SET last_received_at = %s, last_status = %s, last_started_at = %s, "
                    "last_completed_at = %s, last_inserted_rows = %s, last_error = %s WHERE pipeline_name = %s",
                    (*row[1:], row[0]),
                )


# ---------------------------------------------------------------------------
# Rollback script (executed inside the rolled-back test transaction)
# ---------------------------------------------------------------------------


def _script_body(path):
    text = path.read_text(encoding="utf-8")
    assert text.count("\nBEGIN;\n") == 1 and text.rstrip().endswith("COMMIT;")
    return text.split("\nBEGIN;\n", 1)[1].rsplit("COMMIT;", 1)[0]


def test_rollback_restores_the_305_state(clean):
    job_before = _job(clean)
    clean.execute(_script_body(ROLLBACK_SQL))
    assert _one(clean, "SELECT md5(replace(prosrc, E'\\r', '')) FROM pg_proc WHERE oid = %s::regprocedure", (PROC,))[0] == BODY_MD5_213
    job_after = _job(clean)
    assert job_after[1] == {"lookback": "3 hours", "reconcile_window": "48 hours"}
    assert job_after[2:4] == ("config", "assert_reconciliation_job_config")
    assert job_after[0] == job_before[0] and job_after[4:] == job_before[4:]
    assert _one(clean, "SELECT to_regprocedure(%s)", (CHECK,))[0] is None
    comment = _one(clean, "SELECT obj_description(%s::regprocedure, 'pg_proc')", (PROC,))[0]
    assert comment.startswith("Migration 213:") and "306" not in comment
    # The restored procedure runs the 305 configuration as before.
    assert _call(clean, job_after[1])[1] == timedelta(hours=48)
    assert _call(clean, job_after[1])[1] == timedelta(hours=48)


def test_rollback_refuses_unless_the_306_body_is_deployed(clean):
    clean.execute(_script_body(ROLLBACK_SQL))
    with pytest.raises(psycopg.errors.RaiseException, match="306 rollback refused"):
        with clean.transaction():
            clean.execute(_script_body(ROLLBACK_SQL))


def test_rollback_script_references_only_the_demand_reconciler():
    text = ROLLBACK_SQL.read_text(encoding="utf-8")
    assert set(re.findall(r"CREATE OR REPLACE PROCEDURE (\S+)\(", text)) == {"analytics.reconcile_demand_intervals"}
    assert re.findall(r"DROP FUNCTION (\S+)\(", text) == ["config.assert_demand_reconciliation_job_config"]
    assert "DELETE " not in text and "UPDATE " not in text and "INSERT " not in text
