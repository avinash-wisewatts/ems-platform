"""Migration 305 (plan CI-1 / T1.4): recovered raw messages reach energy /
environment measurements.

telemetry.recover_failed_raw_messages re-inserts normalized_points rows with
their ORIGINAL platform_received_at, below the forward window and the
migration-303 late-sweep window, so before 305 they were never routed. 305
queues every pair the recovery insert adds or supersedes (same transaction),
and the hourly late-sweep job routes the queue with ems.routing_scope =
'recovery' under the loaders' advisory locks.

Loader-level tests run in one rolled-back transaction each (fixtures from the
migration-303 suite). The recovery procedure and the job procedure commit, so
their end-to-end test commits and deletes its own fixture.
"""
import time
import uuid
from datetime import timedelta

import psycopg
import psycopg.types.json
import pytest

from tests.test_routing_forward_floor_late_sweep import (
    CONNINFO,
    ENERGY,
    ENV,
    FIXTURES,
    _bucket,
    _compress_old_normalized_chunks,
    _energy_fixture,
    _forward,
    _now,
    _one,
    _routed,
    _sample,
    _set_ckpt,
    _state,
    _sweep,
)

MIGRATION_ID = "305_routing_recovery_queue"
BODY_MD5 = {
    "telemetry.load_energy_measurements_incremental(interval,interval)": "9b035f4a55edbf99ec2a5db4bb173d09",
    "telemetry.load_environment_measurements_incremental(interval,interval)": "d2d906d4da78eeba3740b2b0d082a237",
    # Migration 311 replaced the migration-305 recovery body (76e7c9e2...) with
    # the same body plus the event-time bound on its two normalized_points
    # lookups; test_recovery_lookup_event_time_bound.py covers that change.
    "telemetry.recover_failed_raw_messages(integer)": "31f4db2fbe27b6b072c0aa17bf5660d9",
    "telemetry.run_routing_late_sweep_job(integer,jsonb)": "e649c982e6bf5089a6f126dd4c330405",
}
PIPELINE = {ENERGY: "energy_measurements", ENV: "environment_measurements"}
STAMP = {ENERGY: "energy_routed_at", ENV: "environment_routed_at"}
JOBS = (
    "run_normalization_job",
    "run_energy_routing_job",
    "run_environment_routing_job",
    "run_routing_late_sweep_job",
    "run_failed_message_recovery_job",
    "run_raw_message_failure_capture_job",
)


@pytest.fixture(scope="module", autouse=True)
def quiesce_jobs():
    """Pause normalization, routing, the sweep, failure capture and recovery
    for this module; restore their scheduled state afterwards."""
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


def _enqueue(conn, ids, event_time):
    return _one(
        conn,
        "INSERT INTO telemetry.routing_recovery_queue (raw_received_at, raw_message_id, device_id, event_time) "
        "VALUES (now(), -1, %s, %s) RETURNING id",
        (ids["dev"], event_time),
    )[0]


def _stamps(conn, qid):
    return _one(conn, "SELECT energy_routed_at, environment_routed_at FROM telemetry.routing_recovery_queue WHERE id = %s",
                (qid,))


def _recovery(conn, loader):
    conn.execute("SELECT set_config('ems.routing_scope', 'recovery', true)")
    try:
        conn.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
        conn.execute(f"CALL {loader}(INTERVAL '15 minutes', INTERVAL '1 day')")
    finally:
        conn.execute("SELECT set_config('ems.routing_scope', '', true)")
    return _state(conn, PIPELINE[loader] + "_recovery")


def _recovered_row(conn, ids, age=timedelta(hours=3)):
    """A recovered sample: event and ORIGINAL receipt `age` ago, while both
    routing checkpoints are current (as when 1077 replays it)."""
    now = _now(conn)
    event = _bucket(conn, ids, now - age) + timedelta(seconds=10)
    _sample(conn, ids, event, event + timedelta(seconds=5))
    _set_ckpt(conn, PIPELINE[ids["loader"]], now - timedelta(minutes=1))
    _set_ckpt(conn, PIPELINE[ids["loader"]] + "_late_sweep", now - timedelta(minutes=50))
    return event


def _ckpts(conn, loader):
    return (_state(conn, PIPELINE[loader])[0], _state(conn, PIPELINE[loader] + "_late_sweep")[0])


# ---------------------------------------------------------------------------
# Deployed objects
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sig", BODY_MD5)
def test_deployed_bodies_are_the_migration_305_bodies(tx, sig):
    md5, src = _one(tx, "SELECT md5(replace(prosrc, E'\\r', '')), prosrc FROM pg_proc WHERE oid = %s::regprocedure", (sig,))
    assert md5 == BODY_MD5[sig]
    assert "EXECUTE " not in src and "format(" not in src
    assert _one(tx, "SELECT count(*) FROM admin.schema_migrations WHERE migration_id = %s", (MIGRATION_ID,))[0] == 1


@pytest.mark.parametrize("loader", [ENERGY, ENV])
def test_loader_reads_the_queue_only_in_the_recovery_scope(tx, loader):
    src = _one(tx, "SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (f"{loader}(interval,interval)",))[0]
    assert src.count("AND v_scope <> 'recovery'") == 1
    assert src.count("WHERE v_scope = 'recovery'") == 1
    assert src.count("q.id = ANY(v_queue_ids)") == 1
    assert src.count(f"SET {STAMP[loader]}=clock_timestamp()") == 1
    # 303's forward floor and late-sweep bounds are still there, once.
    assert src.count("np.event_time >= v_event_min") == 1 and src.count("np.event_time < v_event_max") == 1


def test_queue_table_is_owned_by_ems_admin_and_not_readable_by_others(tx):
    assert _one(tx, "SELECT tableowner FROM pg_tables WHERE schemaname = 'telemetry' AND tablename = 'routing_recovery_queue'")[0] == "ems_admin"
    for role in ("public", "ems_app", "grafana_reader"):
        assert _one(tx, "SELECT has_table_privilege(%s, 'telemetry.routing_recovery_queue', 'SELECT')", (role,))[0] is False
    cols = dict(tx.execute(
        "SELECT column_name, is_nullable FROM information_schema.columns "
        "WHERE table_schema = 'telemetry' AND table_name = 'routing_recovery_queue'"
    ).fetchall())
    assert cols == {"id": "NO", "raw_received_at": "NO", "raw_message_id": "NO", "device_id": "NO", "event_time": "NO",
                    "enqueued_at": "NO", "energy_routed_at": "YES", "environment_routed_at": "YES"}


def test_status_rows_demand_window_and_unchanged_sweep_schedule(tx):
    names = {r[0] for r in tx.execute(
        r"SELECT pipeline_name FROM telemetry.pipeline_state WHERE pipeline_name LIKE '%\_recovery'").fetchall()}
    assert names == {"energy_measurements_recovery", "environment_measurements_recovery"}
    # Migration 306 replaced the hourly 48-hour window with 6 hours + a 58-hour
    # wide pass every 6 hours (test_demand_reconcile_wide_cadence.py).
    cfg = tx.execute("SELECT config FROM timescaledb_information.jobs WHERE proc_name = 'reconcile_demand_intervals'").fetchall()
    assert cfg == [({"lookback": "3 hours", "reconcile_window": "6 hours", "wide_window": "58 hours", "wide_every": "6 hours"},)]
    row = _one(tx, """
        SELECT schedule_interval, fixed_schedule, max_runtime, max_retries, config,
               extract(epoch FROM initial_start)::bigint % 3600
        FROM timescaledb_information.jobs WHERE proc_name = 'run_routing_late_sweep_job'""")
    assert row == (timedelta(hours=1), True, timedelta(minutes=10), 3,
                   {"overlap": "15 minutes", "max_window": "1 day"}, 31 * 60 + 30)


def test_demand_reconciler_reads_at_least_the_last_48_hours(tx):
    # Since migration 306 the 48-hour recovery reach comes from the wide pass
    # (58 hours); with no wide pass logged the next run is wide.
    tx.execute("DELETE FROM analytics.pipeline_reconciliation_log WHERE tier = 'demand_intervals'")
    cp = _state(tx, "demand_intervals")[0]
    if cp is None:
        cp = _now(tx) - timedelta(minutes=30)
        _set_ckpt(tx, "demand_intervals", cp)
    cfg = _one(tx, "SELECT config FROM timescaledb_information.jobs WHERE proc_name = 'reconcile_demand_intervals'")[0]
    tx.execute("CALL analytics.reconcile_demand_intervals(0, %s::jsonb)", (psycopg.types.json.Jsonb(cfg),))
    ws, we = _one(tx, "SELECT window_start, window_end FROM analytics.pipeline_reconciliation_log "
                      "WHERE tier = 'demand_intervals' ORDER BY ran_at DESC LIMIT 1")
    assert (we, we - ws) == (cp, timedelta(hours=58))


# ---------------------------------------------------------------------------
# Routing: the recovered row is missed by forward and sweep, routed by recovery
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("domain", FIXTURES)
def test_recovered_row_in_an_open_chunk_is_routed_only_by_the_recovery_scope(tx, domain):
    ids = FIXTURES[domain](tx)
    event = _recovered_row(tx, ids)
    qid = _enqueue(tx, ids, event)
    loader = ids["loader"]
    _forward(tx, ids)
    _sweep(tx, ids)
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 0      # the CI-1 defect, still there for both scopes
    before = _ckpts(tx, loader)
    assert _stamps(tx, qid) == (None, None)

    assert _recovery(tx, loader)[1] == "SUCCESS"
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 1
    stamps = dict(zip((ENERGY, ENV), _stamps(tx, qid)))
    assert stamps[loader] is not None and stamps[ENV if loader == ENERGY else ENERGY] is None
    assert _ckpts(tx, loader) == before                        # forward / sweep checkpoints untouched


@pytest.mark.parametrize("domain", FIXTURES)
def test_recovered_row_in_a_compressed_chunk_is_routed_by_the_recovery_scope(tx, domain):
    """Interaction with 303: below the forward floor and received long before
    the sweep window -- neither scope can see it; the queue routes it."""
    ids = FIXTURES[domain](tx)
    now = _now(tx)
    event = _bucket(tx, ids, now - timedelta(days=40)) + timedelta(seconds=10)
    _sample(tx, ids, event, event + timedelta(seconds=5))
    floor = _compress_old_normalized_chunks(tx)
    assert event < floor
    _set_ckpt(tx, PIPELINE[ids["loader"]], now - timedelta(minutes=1))
    _set_ckpt(tx, PIPELINE[ids["loader"]] + "_late_sweep", now - timedelta(minutes=50))
    _forward(tx, ids)
    _sweep(tx, ids)
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 0
    _enqueue(tx, ids, event)
    assert _recovery(tx, ids["loader"])[1] == "SUCCESS"
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 1


@pytest.mark.parametrize("domain", FIXTURES)
def test_forward_and_sweep_scopes_leave_queue_entries_pending(tx, domain):
    ids = FIXTURES[domain](tx)
    now = _now(tx)
    event = _recovered_row(tx, ids)
    qid = _enqueue(tx, ids, event)
    _sample(tx, ids, now - timedelta(minutes=12), now - timedelta(seconds=30))   # ordinary forward work
    _forward(tx, ids)
    _sweep(tx, ids)
    assert _stamps(tx, qid) == (None, None)


def test_forward_window_read_still_skips_compressed_chunks_and_never_runs_the_recovery_arm(tx):
    """The forward read with the 305 guards, generic plan: startup chunk
    exclusion as in 303, and the queue arm is a never-executed one-time filter."""
    ids = _energy_fixture(tx)
    now = _now(tx)
    for days in (40, 33):
        _sample(tx, ids, now - timedelta(days=days), now - timedelta(days=days))
    _sample(tx, ids, now - timedelta(minutes=10), now - timedelta(minutes=9))
    floor = _compress_old_normalized_chunks(tx)
    sql = (
        "SELECT np.device_id, np.event_time, max(np.platform_received_at) FROM telemetry.normalized_points np "
        "WHERE np.platform_received_at > $1 AND np.platform_received_at <= $2 "
        "AND np.event_time >= $3 AND np.event_time < $4 AND $5 <> 'recovery' "
        "GROUP BY np.device_id, np.event_time "
        "UNION ALL "
        "SELECT np.device_id, np.event_time, max(np.platform_received_at) FROM telemetry.routing_recovery_queue q "
        "JOIN telemetry.normalized_points np ON np.device_id = q.device_id AND np.event_time = q.event_time "
        "WHERE $5 = 'recovery' AND q.id = ANY($6) GROUP BY np.device_id, np.event_time"
    )
    tx.execute("SET LOCAL plan_cache_mode = force_generic_plan")
    tx.execute("PREPARE t305(timestamptz, timestamptz, timestamptz, timestamptz, text, bigint[]) AS " + sql)
    try:
        plan = "\n".join(r[0] for r in tx.execute(
            f"EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE t305('{now - timedelta(hours=1)}', '{now}', "
            f"'{floor}', 'infinity', 'forward', '{{}}')").fetchall())
    finally:
        tx.execute("DEALLOCATE t305")
    # Decompression nodes may appear only inside the never-executed recovery arm.
    for line in plan.splitlines():
        if "ColumnarScan" in line or "DecompressChunk" in line:
            assert "(never executed)" in line, plan
    assert "Chunks excluded during startup" in plan, plan
    assert "One-Time Filter" in plan and "(never executed)" in plan, plan


# ---------------------------------------------------------------------------
# Idempotency, duplicates, late data
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("domain", FIXTURES)
def test_duplicate_entries_and_reruns_route_one_row_once(tx, domain):
    ids = FIXTURES[domain](tx)
    event = _recovered_row(tx, ids)
    q1, q2 = _enqueue(tx, ids, event), _enqueue(tx, ids, event)
    table, bucket = ids["table"], _bucket(tx, ids, event)
    _recovery(tx, ids["loader"])
    first = tx.execute(f"SELECT * FROM {table} WHERE device_id = %s AND bucket_start = %s", (ids["dev"], bucket)).fetchall()
    assert len(first) == 1
    assert all(s is not None for s in (_stamps(tx, q1)[0 if ids["loader"] == ENERGY else 1],
                                       _stamps(tx, q2)[0 if ids["loader"] == ENERGY else 1]))
    _enqueue(tx, ids, event)                                   # recovered again
    _recovery(tx, ids["loader"])
    _recovery(tx, ids["loader"])                               # and nothing pending
    again = tx.execute(f"SELECT * FROM {table} WHERE device_id = %s AND bucket_start = %s", (ids["dev"], bucket)).fetchall()
    assert again == first


def test_an_existing_newer_energy_row_is_not_overwritten_by_an_older_recovered_sample(tx):
    ids = _energy_fixture(tx)
    now = _now(tx)
    bucket = _bucket(tx, ids, now - timedelta(minutes=30))
    newer, older = bucket + timedelta(seconds=40), bucket + timedelta(seconds=10)
    _sample(tx, ids, newer, newer + timedelta(seconds=2), value_offset=5.0)
    _set_ckpt(tx, "energy_measurements", now - timedelta(minutes=40))
    _forward(tx, ids)
    row = _one(tx, "SELECT source_timestamp, import_energy_total_wh FROM telemetry.energy_measurements "
                   "WHERE device_id = %s AND bucket_start = %s", (ids["dev"], bucket))
    assert row[0] == newer
    _sample(tx, ids, older, older + timedelta(seconds=2), value_offset=-5.0)   # recovered later, older reading
    _enqueue(tx, ids, older)
    _recovery(tx, ENERGY)
    assert _one(tx, "SELECT source_timestamp, import_energy_total_wh FROM telemetry.energy_measurements "
                    "WHERE device_id = %s AND bucket_start = %s", (ids["dev"], bucket)) == row


def test_a_newer_recovered_sample_past_the_correction_deadline_does_not_rewrite_the_bucket(tx):
    ids = _energy_fixture(tx)
    now = _now(tx)
    bucket = _bucket(tx, ids, now - timedelta(hours=3))        # 60 s + 60 s policy: deadline long past
    older, newer = bucket + timedelta(seconds=10), bucket + timedelta(seconds=40)
    _sample(tx, ids, older, older + timedelta(seconds=2))
    tx.execute("SELECT set_config('ems.routing_scope', '', true)")
    _enqueue(tx, ids, older)
    _recovery(tx, ENERGY)                                       # missing row: inserted although past the deadline
    row = _one(tx, "SELECT source_timestamp FROM telemetry.energy_measurements WHERE device_id = %s AND bucket_start = %s",
               (ids["dev"], bucket))
    assert row == (older,)
    _sample(tx, ids, newer, newer + timedelta(seconds=2), value_offset=3.0)
    _enqueue(tx, ids, newer)
    _recovery(tx, ENERGY)
    assert _one(tx, "SELECT source_timestamp FROM telemetry.energy_measurements WHERE device_id = %s AND bucket_start = %s",
                (ids["dev"], bucket)) == row


def test_only_pending_entries_are_read(tx):
    """A stamped entry is not routed again (its row deleted afterwards stays deleted)."""
    ids = _energy_fixture(tx)
    event = _recovered_row(tx, ids)
    _enqueue(tx, ids, event)
    _recovery(tx, ENERGY)
    tx.execute("DELETE FROM telemetry.energy_measurements WHERE device_id = %s", (ids["dev"],))
    _recovery(tx, ENERGY)
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 0


# ---------------------------------------------------------------------------
# Retries and failures keep the entries
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("loader", [ENERGY, ENV])
def test_lock_skip_keeps_entries_pending_and_the_next_run_routes_them(tx, loader):
    ids = FIXTURES["energy" if loader == ENERGY else "environment"](tx)
    event = _recovered_row(tx, ids)
    qid = _enqueue(tx, ids, event)
    with psycopg.connect(CONNINFO, autocommit=True) as holder:
        holder.execute("SELECT pg_advisory_lock(hashtextextended(%s, 0))", (loader,))
        try:
            assert _recovery(tx, loader)[1] == "SKIPPED_LOCKED"
        finally:
            holder.execute("SELECT pg_advisory_unlock(hashtextextended(%s, 0))", (loader,))
    assert _stamps(tx, qid) == (None, None)
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 0
    assert _recovery(tx, loader)[1] == "SUCCESS"
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 1


@pytest.mark.parametrize("domain", FIXTURES)
def test_a_failed_recovery_run_rolls_back_its_rows_and_stamps_and_the_retry_succeeds(tx, domain):
    ids = FIXTURES[domain](tx)
    event = _recovered_row(tx, ids)
    qid = _enqueue(tx, ids, event)
    status_before = _state(tx, PIPELINE[ids["loader"]] + "_recovery")
    tx.execute(
        "CREATE FUNCTION pg_temp.t305_fail() RETURNS trigger LANGUAGE plpgsql AS "
        "$$BEGIN RAISE EXCEPTION 't305 injected failure'; END$$"
    )
    tx.execute("CREATE TRIGGER t305_fail BEFORE UPDATE ON telemetry.routing_recovery_queue "
               "FOR EACH ROW EXECUTE FUNCTION pg_temp.t305_fail()")
    with pytest.raises(psycopg.errors.RaiseException, match="t305 injected failure"):
        with tx.transaction():
            tx.execute("SELECT set_config('ems.routing_scope', 'recovery', true)")
            tx.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
            tx.execute(f"CALL {ids['loader']}(INTERVAL '15 minutes', INTERVAL '1 day')")
    tx.execute("SELECT set_config('ems.routing_scope', '', true)")
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 0      # the routed row rolled back with the stamp
    assert _stamps(tx, qid) == (None, None)
    assert _state(tx, PIPELINE[ids["loader"]] + "_recovery") == status_before
    tx.execute("DROP TRIGGER t305_fail ON telemetry.routing_recovery_queue")
    assert _recovery(tx, ids["loader"])[1] == "SUCCESS"
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 1


def test_unknown_scope_is_still_rejected(tx):
    with pytest.raises(psycopg.errors.RaiseException, match="must be forward, late_sweep or recovery"):
        with tx.transaction():
            tx.execute("SELECT set_config('ems.routing_scope', 'bogus', true)")
            tx.execute(f"CALL {ENERGY}(INTERVAL '15 minutes', INTERVAL '1 day')")


# ---------------------------------------------------------------------------
# End to end: quarantine -> recovery (job 1077 body) -> queue -> late-sweep job
# (both commit; the fixture is committed and deleted afterwards)
# ---------------------------------------------------------------------------


def _e2e_fixture(c, tag):
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw", "dev")}
    ids["uid"] = f"T305:{tag}"
    prof = _one(c, "SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")[0]
    c.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)", (ids["org"], f"T305 {tag}", f"T305_ORG_{tag}"))
    c.execute("INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, %s, %s)",
              (ids["site"], ids["org"], f"T305 {tag}", f"T305_SITE_{tag}"))
    c.execute("INSERT INTO config.telemetry_capture_policies (site_id, capture_interval_seconds, alignment_mode, "
              "late_arrival_tolerance_seconds, effective_from, is_enabled) VALUES (%s, 60, 'WALL_CLOCK', 60, now() - INTERVAL '90 days', TRUE)",
              (ids["site"],))
    c.execute("INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
              (ids["gw"], ids["org"], ids["site"], f"T305 GW {tag}", f"T305-GW-{tag}"))
    with c.transaction():
        c.execute("INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id, profile_id) "
                  "VALUES (%s, %s, %s, %s, %s, %s)", (ids["dev"], ids["org"], ids["gw"], ids["uid"], ids["uid"], prof))
        c.execute("SELECT set_config('ems.controlled_device_commissioning_id', %s, true)", (str(ids["dev"]),))
        c.execute("UPDATE metadata.devices SET lifecycle_status = 'ACTIVE' WHERE id = %s", (ids["dev"],))
    c.execute("INSERT INTO metadata.device_identifiers (device_id, identifier_type, identifier_value) VALUES (%s, 'MQTT_UID', %s)",
              (ids["dev"], ids["uid"]))
    return ids


def _quarantine(c, ids, event, value):
    msg = _one(
        c,
        "INSERT INTO telemetry.raw_messages (received_at, source_protocol, source_topic, payload) "
        "VALUES (%s, 'MQTT', 'test/t305', jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object("
        "'uid', %s::text, 'ts', extract(epoch FROM %s::timestamptz)::text, 'E', %s::numeric)))) RETURNING id",
        (event, ids["uid"], event, value),
    )[0]
    c.execute(
        "INSERT INTO telemetry.raw_message_failures (raw_received_at, raw_message_id, failure_code, source_protocol, "
        "source_identifier, payload) VALUES (%s, %s, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', %s, "
        "jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', %s::text))))",
        (event, msg, ids["uid"], ids["uid"]),
    )
    return msg


def _cleanup(c, ids, msgs):
    c.execute("DELETE FROM telemetry.routing_recovery_queue WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM telemetry.energy_measurements WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM telemetry.normalized_points WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM telemetry.capture_bucket_samples WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM telemetry.raw_message_failures WHERE raw_message_id = ANY(%s)", (msgs,))
    c.execute("DELETE FROM telemetry.raw_messages WHERE id = ANY(%s)", (msgs,))
    for table in ("telemetry.device_point_state", "telemetry.device_telemetry_state", "telemetry.device_live_point_state",
                  "metadata.device_identifiers"):
        c.execute(f"DELETE FROM {table} WHERE device_id = %s", (ids["dev"],))
    c.execute("DELETE FROM metadata.devices WHERE id = %s", (ids["dev"],))
    c.execute("DELETE FROM metadata.gateways WHERE id = %s", (ids["gw"],))
    c.execute("DELETE FROM metadata.sites WHERE id = %s", (ids["site"],))
    c.execute("DELETE FROM metadata.organizations WHERE id = %s", (ids["org"],))


def test_end_to_end_recovered_message_is_queued_atomically_and_routed_by_the_sweep_job():
    tag = uuid.uuid4().hex[:8].upper()
    names = [f"{p}{s}" for p in ("energy_measurements", "environment_measurements") for s in ("", "_late_sweep", "_recovery")]
    msgs = []
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        saved = c.execute(
            "SELECT pipeline_name, last_received_at, last_status, last_started_at, last_completed_at, last_inserted_rows, "
            "last_error FROM telemetry.pipeline_state WHERE pipeline_name = ANY(%s)", (names,)).fetchall()
        ids = _e2e_fixture(c, tag)
        try:
            now = _now(c)
            event = now.replace(second=0, microsecond=0) - timedelta(hours=3) + timedelta(seconds=10)
            msgs.append(_quarantine(c, ids, event, 1234.0))
            # Both routing checkpoints are current: the recovered row is behind them.
            for name in ("energy_measurements", "energy_measurements_late_sweep"):
                c.execute("UPDATE telemetry.pipeline_state SET last_received_at = now() - INTERVAL '1 minute' WHERE pipeline_name = %s", (name,))

            # A failing queue insert rolls the recovery insert back with it.
            c.execute("CREATE FUNCTION telemetry.t305_fail() RETURNS trigger LANGUAGE plpgsql AS "
                      "$$BEGIN RAISE EXCEPTION 't305 queue insert failure'; END$$")
            c.execute("CREATE TRIGGER t305_fail BEFORE INSERT ON telemetry.routing_recovery_queue "
                      "FOR EACH ROW EXECUTE FUNCTION telemetry.t305_fail()")
            try:
                try:
                    c.execute("CALL telemetry.recover_failed_raw_messages(10)")
                except psycopg.Error:
                    pass
                assert _one(c, "SELECT count(*) FROM telemetry.normalized_points WHERE device_id = %s", (ids["dev"],))[0] == 0
                assert _one(c, "SELECT count(*) FROM telemetry.routing_recovery_queue WHERE device_id = %s", (ids["dev"],))[0] == 0
                assert _one(c, "SELECT resolution_status FROM telemetry.raw_message_failures WHERE raw_message_id = %s",
                            (msgs[0],))[0] != "RECOVERED"
            finally:
                c.execute("DROP TRIGGER t305_fail ON telemetry.routing_recovery_queue")
                c.execute("DROP FUNCTION telemetry.t305_fail()")
            c.execute("UPDATE telemetry.raw_message_failures SET resolution_status = 'OPEN', next_replay_at = NULL "
                      "WHERE raw_message_id = %s", (msgs[0],))

            c.execute("CALL telemetry.recover_failed_raw_messages(10)")
            assert _one(c, "SELECT resolution_status FROM telemetry.raw_message_failures WHERE raw_message_id = %s",
                        (msgs[0],))[0] == "RECOVERED"
            queued = c.execute("SELECT raw_message_id, event_time, energy_routed_at FROM telemetry.routing_recovery_queue "
                               "WHERE device_id = %s", (ids["dev"],)).fetchall()
            assert queued == [(msgs[0], event, None)]
            bucket = event.replace(second=0)
            assert _one(c, "SELECT count(*) FROM telemetry.energy_measurements WHERE device_id = %s AND bucket_start = %s",
                        (ids["dev"], bucket))[0] == 0

            c.execute("CALL telemetry.run_routing_late_sweep_job(0, '{\"max_window\": \"1 day\"}'::jsonb)")
            assert _one(c, "SELECT count(*) FROM telemetry.energy_measurements WHERE device_id = %s AND bucket_start = %s",
                        (ids["dev"], bucket))[0] == 1
            stamps = _one(c, "SELECT energy_routed_at, environment_routed_at FROM telemetry.routing_recovery_queue "
                             "WHERE device_id = %s", (ids["dev"],))
            assert stamps[0] is not None and stamps[1] is not None
            assert c.execute("SELECT current_setting('ems.routing_scope', true)").fetchone()[0] in (None, "")

            # The prune drops entries both loaders routed more than 7 days ago.
            c.execute("UPDATE telemetry.routing_recovery_queue SET energy_routed_at = now() - INTERVAL '8 days', "
                      "environment_routed_at = now() - INTERVAL '8 days' WHERE device_id = %s", (ids["dev"],))
            c.execute("CALL telemetry.run_routing_late_sweep_job(0, '{\"max_window\": \"1 day\"}'::jsonb)")
            assert _one(c, "SELECT count(*) FROM telemetry.routing_recovery_queue WHERE device_id = %s", (ids["dev"],))[0] == 0
        finally:
            _cleanup(c, ids, msgs)
            for row in saved:
                c.execute(
                    "UPDATE telemetry.pipeline_state SET last_received_at = %s, last_status = %s, last_started_at = %s, "
                    "last_completed_at = %s, last_inserted_rows = %s, last_error = %s WHERE pipeline_name = %s",
                    (*row[1:], row[0]),
                )
