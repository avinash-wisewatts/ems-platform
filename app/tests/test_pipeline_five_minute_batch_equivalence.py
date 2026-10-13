"""Migration 300: processing one 5-minute batch gives the same results as five
1-minute runs.

The pipeline jobs are cadence-independent by construction:

  * normalization finalizes a capture bucket only once its deadline
    (bucket_start + capture_interval + late_arrival_tolerance) has passed,
    selects the newest sample RECEIVED BY that deadline, and the first
    selection is final (capture_bucket_samples ON CONFLICT DO NOTHING);
  * routing re-reads normalized rows by platform_received_at with a 1-minute
    replay and upserts per (bucket_start, device_id);
  * the 1-minute consumption tier recomputes every minute in its window from
    that minute's aggregate row and the previous eligible one (value-aware
    upsert), so windows of any size that tile the timeline converge.

These tests prove it on the real procedures with the real clock. The capture
deadline is wall-clock (clock_timestamp()), so the 1-minute schedule is
time-scaled: a site policy with a 10 s capture interval and 2 s tolerance
plays the role of 60 s + 60 s, "one run per bucket" plays the 1-minute
cadence and "one run after five buckets" the 5-minute batch. The selection
rule does not depend on the interval length.

Covered: deadline boundaries (received exactly at the deadline; event exactly
at a bucket boundary), late-within-tolerance and too-late samples, a missing
bucket, a duplicate delivery, a bucket not yet due, a failed run that is
retried, and the 1-minute tier's windowing (including a minute that arrives
after its successor). Everything runs in one transaction that is rolled back;
the pipeline jobs are paused for the module and restored.
"""

from __future__ import annotations

import os
import time
import uuid
from datetime import timedelta

import psycopg
import pytest

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

PIPELINE_JOBS = (
    "run_normalization_job",
    "run_energy_routing_job",
    "run_environment_routing_job",
    "run_energy_consumption_1min_job",
)
NORMALIZATION_CONFIG = '{"overlap": "15 minutes", "max_window": "2 hours"}'
ROUTING_CONFIG = '{"overlap": "15 minutes", "max_window": "2 hours"}'
INTERVAL_S = 10
TOLERANCE_S = 2
RUN_LAG_S = 0.4  # a run starts this long after the deadline it waits for


@pytest.fixture(scope="module", autouse=True)
def quiesce_pipeline_jobs():
    """Pause the pipeline jobs for this module and restore their state."""
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        jobs = c.execute(
            """
            SELECT j.job_id, j.scheduled, s.next_start
            FROM timescaledb_information.jobs AS j
            JOIN timescaledb_information.job_stats AS s USING (job_id)
            WHERE j.proc_name = ANY(%s)
            """,
            (list(PIPELINE_JOBS),),
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


def _one(conn, sql, params=None):
    return conn.execute(sql, params).fetchone()


def _clock(conn):
    return _one(conn, "SELECT clock_timestamp()")[0]


def _sleep_until(conn, ts):
    while True:
        remaining = (ts - _clock(conn)).total_seconds()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 1.0))


# ---------------------------------------------------------------------------
# Fixture: two Eniscope energy meters on a 10 s / 2 s capture policy
# ---------------------------------------------------------------------------


def _site_fixture(conn, interval_s=INTERVAL_S, tolerance_s=TOLERANCE_S):
    tag = uuid.uuid4().hex[:8].upper()
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw", "d1", "d2")}
    profile = _one(conn, "SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")[0]
    conn.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)",
                 (ids["org"], f"M300 Org {tag}", f"M300_ORG_{tag}"))
    conn.execute("INSERT INTO metadata.sites (id, organization_id, name, code, timezone) VALUES (%s, %s, %s, %s, 'Asia/Kolkata')",
                 (ids["site"], ids["org"], f"M300 Site {tag}", f"M300_SITE_{tag}"))
    conn.execute(
        """
        INSERT INTO config.telemetry_capture_policies
            (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
        VALUES (%s, %s, 'WALL_CLOCK', %s, now() - INTERVAL '1 day', TRUE)
        """,
        (ids["site"], interval_s, tolerance_s),
    )
    conn.execute("INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
                 (ids["gw"], ids["org"], ids["site"], f"M300 GW {tag}", f"M300-GW-{tag}"))
    for key in ("d1", "d2"):
        conn.execute(
            "INSERT INTO metadata.devices (id, organization_id, gateway_id, profile_id, name, external_id) "
            "VALUES (%s, %s, %s, %s, %s, %s)",
            (ids[key], ids["org"], ids["gw"], profile, f"M300 {key} {tag}", f"M300-{key}-{tag}"),
        )
        ids[f"{key}_uid"] = f"M300:{key}:{tag}"
        conn.execute(
            "INSERT INTO metadata.device_identifiers (device_id, identifier_type, identifier_value) VALUES (%s, 'MQTT_UID', %s)",
            (ids[key], ids[f"{key}_uid"]),
        )
    enabled = _one(conn, "SELECT count(*) FROM config.device_point_configuration WHERE device_id = %s AND is_enabled", (ids["d1"],))[0]
    assert enabled > 0, "fixture assumption: the profile's points are enabled for the device on insert"
    ids["tag"] = tag
    return ids


def _schedule(ids, b0):
    """Raw deliveries: (label, device, bucket index, event offset s, received
    offset s, import register Wh). Offsets are seconds from that bucket's start."""
    rows = [
        # b0: one on-time sample per device
        ("b0-d1", "d1", 0, 3.0, 4.0, 1000.0),
        ("b0-d2", "d2", 0, 5.0, 6.0, 5000.0),
        # b1: d1 sends twice; the newer event wins
        ("b1-d1-early", "d1", 1, 2.0, 3.0, 1001.0),
        ("b1-d1-newer", "d1", 1, 8.0, 9.0, 1002.0),
        ("b1-d2", "d2", 1, 4.0, 5.0, 5001.0),
        # b2: d1 sample that arrives while the bucket is still open, BEFORE
        # the single-bucket run that precedes its deadline (a run must not
        # finalize it early); newer event received EXACTLY at the deadline
        # (included); d2 sends nothing (a gap must stay a gap)
        ("b2-d1-very-early", "d1", 2, 1.0, 2.0, 1002.5),
        ("b2-d1-ontime", "d1", 2, 5.0, 6.0, 1003.0),
        ("b2-d1-at-deadline", "d1", 2, 9.0, INTERVAL_S + TOLERANCE_S, 1004.0),
        # b3: d1 newer event received after the deadline (excluded);
        # d2 event exactly at the bucket start (belongs to b3)
        ("b3-d1-ontime", "d1", 3, 5.0, 6.0, 1005.0),
        ("b3-d1-too-late", "d1", 3, 9.5, INTERVAL_S + TOLERANCE_S + 0.6, 1006.0),
        ("b3-d2-at-start", "d2", 3, 0.0, 1.0, 5003.0),
        # b4: d1 event exactly at the bucket start; d1 event exactly at the
        # bucket end (belongs to b5); d2 delivered twice (duplicate)
        ("b4-d1-at-start", "d1", 4, 0.0, 1.0, 1007.0),
        ("b5-d1-at-boundary", "d1", 4, float(INTERVAL_S), INTERVAL_S + 0.5, 1008.0),
        ("b4-d2-first", "d2", 4, 3.0, 4.0, 5004.0),
        ("b4-d2-redelivered", "d2", 4, 3.0, 4.5, 5004.0),
    ]
    out = []
    for label, dev, i, ev, rcv, reg in rows:
        start = b0 + timedelta(seconds=INTERVAL_S * i)
        out.append({
            "label": label,
            "device": ids[dev],
            "uid": ids[f"{dev}_uid"],
            "event": start + timedelta(seconds=ev),
            "received": start + timedelta(seconds=rcv),
            "register": reg,
        })
    return out


def _insert_arrived(conn, schedule, inserted, ids):
    """Insert every delivery whose received_at has passed (it has 'arrived')."""
    now = _clock(conn)
    for r in schedule:
        if r["label"] in inserted or r["received"] > now:
            continue
        conn.execute(
            "INSERT INTO telemetry.raw_messages (received_at, source_protocol, source_topic, payload) "
            "VALUES (%s, 'MQTT', %s, jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object("
            "'uid', %s::text, 'ts', %s::text, 'E', %s::numeric, 'P', 1.5))))",
            (r["received"], f"test/m300/{ids['tag']}/{r['label']}", r["uid"],
             f"{r['event'].timestamp():.6f}", r["register"]),
        )
        inserted.add(r["label"])


def _drop_loader_temp_tables(conn):
    conn.execute("DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch")


def _normalize(conn):
    conn.execute(f"CALL telemetry.run_normalization_job(0, '{NORMALIZATION_CONFIG}'::jsonb)")
    _drop_loader_temp_tables(conn)


def _route(conn):
    conn.execute(f"CALL telemetry.run_energy_routing_job(0, '{ROUTING_CONFIG}'::jsonb)")


def _reset_checkpoints(conn, at):
    conn.execute(
        "UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name IN ('normalized_points', 'energy_measurements')",
        (at,),
    )


def _results(conn, ids):
    devices = [ids["d1"], ids["d2"]]
    label = {ids["d1"]: "d1", ids["d2"]: "d2"}
    capture = conn.execute(
        """
        SELECT s.bucket_start, s.device_id, split_part(r.source_topic, '/', 4), s.status
        FROM telemetry.capture_bucket_samples s
        JOIN telemetry.raw_messages r ON r.received_at = s.raw_received_at AND r.id = s.raw_message_id
        WHERE s.site_id = %s ORDER BY 1, 2
        """,
        (ids["site"],),
    ).fetchall()
    normalized = conn.execute(
        """
        SELECT np.event_time, np.device_id, np.logical_point, np.raw_value, np.numeric_value, np.quality_code,
               np.platform_received_at, split_part(r.source_topic, '/', 4)
        FROM telemetry.normalized_points np
        JOIN telemetry.raw_messages r ON r.id = np.raw_message_id AND r.received_at = np.platform_received_at
        WHERE np.device_id = ANY(%s) ORDER BY 1, 2, 3
        """,
        (devices,),
    ).fetchall()
    energy = conn.execute(
        # id is a serial: a rolled-back savepoint does not rewind its sequence.
        "SELECT to_jsonb(em) - 'id' FROM telemetry.energy_measurements em WHERE device_id = ANY(%s) "
        "ORDER BY bucket_start, device_id",
        (devices,),
    ).fetchall()
    point_state = conn.execute(
        "SELECT to_jsonb(s) - 'updated_at' FROM telemetry.device_point_state s WHERE device_id = ANY(%s) "
        "ORDER BY device_id, logical_point_id",
        (devices,),
    ).fetchall()
    telemetry_state = conn.execute(
        "SELECT to_jsonb(s) - 'updated_at' FROM telemetry.device_telemetry_state s WHERE device_id = ANY(%s) ORDER BY device_id",
        (devices,),
    ).fetchall()
    selected = {(b, label[d]): lab for b, d, lab, _ in capture}
    return {
        "capture": [(b, label[d], lab, st) for b, d, lab, st in capture],
        "normalized": [(e, label[d], *rest) for e, d, *rest in normalized],
        "energy": energy,
        "point_state": point_state,
        "telemetry_state": telemetry_state,
        "selected": selected,
    }


def test_one_five_bucket_batch_equals_five_single_bucket_runs(tx):
    ids = _site_fixture(tx)
    c0 = _clock(tx)
    # First bucket chosen so its deadline is 1-11 s in the future.
    b0 = _one(tx, "SELECT date_bin(make_interval(secs => %s), %s::timestamptz - INTERVAL '11 seconds', "
                  "TIMESTAMPTZ '2000-01-01') + make_interval(secs => %s)", (INTERVAL_S, c0, INTERVAL_S))[0]
    deadlines = [b0 + timedelta(seconds=INTERVAL_S * i + INTERVAL_S + TOLERANCE_S) for i in range(6)]
    schedule = _schedule(ids, b0)
    start_cp = c0 - timedelta(minutes=5)

    # Mode A: one run per bucket ("every minute").
    tx.execute("SAVEPOINT mode_a")
    _reset_checkpoints(tx, start_cp)
    inserted: set[str] = set()
    for d in deadlines[:5]:
        _sleep_until(tx, d + timedelta(seconds=RUN_LAG_S))
        _insert_arrived(tx, schedule, inserted, ids)
        _normalize(tx)
        _route(tx)
    a = _results(tx, ids)
    a_cp = _one(tx, "SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points'")[0]
    tx.execute("ROLLBACK TO SAVEPOINT mode_a")

    # Mode B: one run after five buckets (the 5-minute batch; equivalently,
    # four missed runs caught up by the fifth).
    tx.execute("SAVEPOINT mode_b")
    _reset_checkpoints(tx, start_cp)
    inserted = set()
    _insert_arrived(tx, schedule, inserted, ids)
    assert _clock(tx) < deadlines[5], "mode B must run before the sixth bucket is due"
    _normalize(tx)
    _route(tx)
    b = _results(tx, ids)
    b_cp = _one(tx, "SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points'")[0]

    # Identical outputs, field by field.
    assert a["capture"] == b["capture"]
    assert a["normalized"] == b["normalized"]
    assert a["energy"] == b["energy"]
    assert a["point_state"] == b["point_state"]
    assert a["telemetry_state"] == b["telemetry_state"]
    assert a_cp == b_cp

    # And the selections are the ones the capture rules require.
    bucket = {i: b0 + timedelta(seconds=INTERVAL_S * i) for i in range(6)}
    assert b["selected"] == {
        (bucket[0], "d1"): "b0-d1",
        (bucket[0], "d2"): "b0-d2",
        (bucket[1], "d1"): "b1-d1-newer",
        (bucket[1], "d2"): "b1-d2",
        (bucket[2], "d1"): "b2-d1-at-deadline",
        (bucket[3], "d1"): "b3-d1-ontime",
        (bucket[3], "d2"): "b3-d2-at-start",
        (bucket[4], "d1"): "b4-d1-at-start",
        (bucket[4], "d2"): "b4-d2-redelivered",
    }, "b2/d2 is a gap; b5 is not yet due; the too-late b3 sample is never selected"
    assert {st for *_, st in b["capture"]} == {"NORMALIZED"}
    assert b["normalized"], "the fixture must produce normalized rows"
    assert b["energy"], "the fixture must produce routed energy rows"
    assert len(b["energy"]) == 9  # one per selected (bucket, device)

    # Retry: a failed batch leaves no trace; the retry equals mode B.
    tx.execute("ROLLBACK TO SAVEPOINT mode_b")
    _reset_checkpoints(tx, start_cp)
    inserted = set()
    _insert_arrived(tx, schedule, inserted, ids)
    tx.execute(
        """
        CREATE FUNCTION pg_temp.m300_fail() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
            IF current_setting('m300.fail', true) = 'on' THEN
                RAISE EXCEPTION 'm300 injected failure';
            END IF;
            RETURN NEW;
        END $$
        """
    )
    tx.execute("CREATE TRIGGER m300_fail BEFORE INSERT ON telemetry.normalized_points "
               "FOR EACH ROW EXECUTE FUNCTION pg_temp.m300_fail()")
    tx.execute("SELECT set_config('m300.fail', 'on', true)")
    tx.execute("SAVEPOINT attempt")
    with pytest.raises(psycopg.errors.RaiseException, match="m300 injected failure"):
        tx.execute(f"CALL telemetry.run_normalization_job(0, '{NORMALIZATION_CONFIG}'::jsonb)")
    tx.execute("ROLLBACK TO SAVEPOINT attempt")
    assert _one(tx, "SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'normalized_points'")[0] == start_cp
    assert _one(tx, "SELECT count(*) FROM telemetry.capture_bucket_samples WHERE site_id = %s", (ids["site"],))[0] == 0
    tx.execute("SELECT set_config('m300.fail', 'off', true)")
    _normalize(tx)
    _route(tx)
    c = _results(tx, ids)
    if _clock(tx) >= deadlines[5]:
        # The retry may run after the sixth bucket's deadline; compare the
        # five batched buckets only.
        assert [r for r in c["capture"] if r[0] < bucket[5]] == b["capture"]
        assert [r for r in c["normalized"] if r[0] < bucket[5]] == b["normalized"]
    else:
        assert c["capture"] == b["capture"]
        assert c["normalized"] == b["normalized"]
        assert c["energy"] == b["energy"]


# ---------------------------------------------------------------------------
# 1-minute consumption tier: five 1-minute windows == one 5-minute window
# ---------------------------------------------------------------------------


def _mat_table(conn):
    return _one(
        conn,
        """
        SELECT format('%I.%I', ht.schema_name, ht.table_name)
        FROM _timescaledb_catalog.continuous_agg ca
        JOIN _timescaledb_catalog.hypertable ht ON ht.id = ca.mat_hypertable_id
        WHERE ca.user_view_name = 'ca_energy_1min'
        """,
    )[0]


def _seed_minute(conn, mat, ids, minute, register):
    conn.execute(
        f"INSERT INTO {mat} (bucket_start, organization_id, site_id, device_id, sample_count, "
        "import_energy_total_wh_max, import_energy_total_wh_min, export_energy_total_wh_max, export_energy_total_wh_min) "
        "VALUES (%s, %s, %s, %s, 1, %s, %s, 0, 0)",
        (minute, ids["org"], ids["site"], ids["d1"], register, register),
    )


def _tier_rows(conn, ids):
    return conn.execute(
        "SELECT to_jsonb(c) - 'calculated_at' FROM analytics.energy_consumption_1min c "
        "WHERE device_id = %s ORDER BY bucket_start",
        (ids["d1"],),
    ).fetchall()


def test_one_minute_tier_five_windows_equal_one_window(tx):
    """1079's run windows are [checkpoint - overlap, new checkpoint). Five
    1-minute steps and one 5-minute step over the same aggregate rows give the
    same tier, including when a minute lands in the aggregate only after its
    successor (a late device within a 1-minute cadence)."""
    ids = _site_fixture(tx, interval_s=60, tolerance_s=60)
    mat = _mat_table(tx)
    overlap = timedelta(minutes=2)
    t0 = _one(tx, "SELECT date_trunc('minute', now()) - INTERVAL '30 minutes'")[0]
    minutes = [t0 + timedelta(minutes=i) for i in range(11)]
    registers = [10_000.0 + 7.5 * i for i in range(11)]

    def refresh(frm, to):
        _one(tx, "SELECT analytics.refresh_energy_consumption_1min(%s, %s)", (frm, to))

    # Mode A: 1-minute steps; minute 6 reaches the aggregate one step after minute 7.
    tx.execute("SAVEPOINT tier_a")
    _seed_minute(tx, mat, ids, minutes[0], registers[0])
    cp = minutes[1]
    refresh(minutes[0] - overlap, cp)
    for i in range(1, 11):
        if i == 6:
            # This device's minute 6 is not in the aggregate yet, but the
            # data-driven watermark has moved past it (other devices): the
            # run covers minute 6 and finds nothing for this device.
            refresh(cp - overlap, minutes[7])
            cp = minutes[7]
            continue
        _seed_minute(tx, mat, ids, minutes[i], registers[i])
        if i == 7:
            _seed_minute(tx, mat, ids, minutes[6], registers[6])
        new_cp = minutes[i] + timedelta(minutes=1)
        refresh(cp - overlap, new_cp)
        cp = new_cp
    a = _tier_rows(tx, ids)
    tx.execute("ROLLBACK TO SAVEPOINT tier_a")

    # Mode B: all minutes present, 5-minute steps.
    for i in range(11):
        _seed_minute(tx, mat, ids, minutes[i], registers[i])
    cp = minutes[0]
    for new_cp in (minutes[1], minutes[6], minutes[10] + timedelta(minutes=1)):
        refresh(cp - overlap, new_cp)
        cp = new_cp
    b = _tier_rows(tx, ids)

    assert len(b) == 11
    assert a == b
