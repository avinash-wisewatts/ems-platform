"""Migration 304 (plan T3.5 step 1): the 15-minute energy job waits for the
5-minute tier's checkpoint only while an enabled 300 s capture policy
overlaps the window it refreshes.

analytics.energy_consumption_15min is rolled up from the 1-minute tier
(buckets under a <= 60 s policy) UNION ALL the 5-minute tier (buckets under
a 300 s policy). Without a 300 s policy the 5-minute tier contributes nothing,
so a lagging or stalled 5-minute checkpoint (job 1080) must not hold the
15-minute tier back; with one -- mixed fleets included -- the migration-209
LEAST(cp_1min, cp_5min) gate must still apply, or 5-minute readings that
arrive after the 15-minute checkpoint passed would never be rolled up.

Every test is one rolled-back transaction on the disposable ems_test
database (see conftest.py). The procedure reads clock_timestamp(), so the
fixtures are placed relative to the current UTC quarter-hour W.
"""
import time
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO
from tests.test_energy_reconstruction_read_hardening import _tenant

UTC = timezone.utc
JOB_15 = "CALL analytics.run_energy_consumption_15min_job(0, '{}'::jsonb)"
JOB_HOURLY = "CALL analytics.run_energy_consumption_hourly_job(0, '{}'::jsonb)"
HELPER = "analytics.energy_5min_capture_policy_overlaps(timestamptz, timestamptz)"
TIER_JOBS = (
    "run_energy_consumption_1min_job",
    "run_energy_consumption_5min_job",
    "run_energy_consumption_15min_job",
    "run_energy_consumption_hourly_job",
    "run_energy_consumption_daily_job",
)
# Bodies migration 304 must not touch (staging 2026-10-19 = local test DB).
UNCHANGED_MD5 = {
    "run_energy_consumption_1min_job": "f6d0279a94d3f6996d63b46441b384ac",
    "run_energy_consumption_5min_job": "a163bf206b2f7c463008a2395e74d006",
    "run_energy_consumption_hourly_job": "634f6bf9df03d7c711baea0f4ac2c8a9",
    "run_energy_consumption_daily_job": "52429d2dde61282d80f441ab24535eed",
}
Q = timedelta(minutes=15)


@pytest.fixture(scope="module", autouse=True)
def quiesce_tier_jobs():
    """Pause the energy tier jobs for this module (they take the same advisory
    locks and pipeline_state rows) and restore their scheduled state after."""
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        jobs = c.execute(
            """
            SELECT j.job_id, j.scheduled, s.next_start
            FROM timescaledb_information.jobs AS j
            JOIN timescaledb_information.job_stats AS s USING (job_id)
            WHERE j.proc_schema = 'analytics' AND j.proc_name = ANY(%s)
            """,
            (list(TIER_JOBS),),
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
    # The procedure bins clock_timestamp() to the quarter-hour; keep a test
    # from straddling a boundary.
    now = datetime.now(UTC)
    to_boundary = (Q - (now - datetime(2000, 1, 1, tzinfo=UTC)) % Q).total_seconds()
    if to_boundary < 20:
        time.sleep(to_boundary + 1)
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


def _w(cur):
    """The current UTC quarter-hour, as the procedure computes it."""
    cur.execute("SELECT date_bin(INTERVAL '15 minutes', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00')")
    return cur.fetchone()[0]


def _no_300s_policies(cur):
    cur.execute("UPDATE config.telemetry_capture_policies SET is_enabled = FALSE WHERE capture_interval_seconds = 300")


def _checkpoints(cur, cp15, cp1, cp5, hourly=None):
    for name, value in (("energy_consumption_15min", cp15), ("energy_consumption_1min", cp1),
                        ("energy_consumption_5min", cp5), ("energy_consumption_hourly", hourly)):
        if name == "energy_consumption_hourly" and value is None:
            continue
        cur.execute("UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = %s", (value, name))
        assert cur.rowcount == 1, name


def _cp(cur, name):
    cur.execute("SELECT last_received_at, last_status FROM telemetry.pipeline_state WHERE pipeline_name = %s", (name,))
    return cur.fetchone()


def _seed_1min(cur, t, start, end):
    """Valid 1-minute intervals for t's device, [start, end)."""
    cur.execute(
        """
        INSERT INTO analytics.energy_consumption_1min (
            bucket_start, organization_id, site_id, device_id, previous_bucket_start,
            import_register_wh, previous_import_register_wh, import_consumption_wh, import_consumption_kwh,
            import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
            export_register_wh, previous_export_register_wh, export_consumption_wh, export_consumption_kwh,
            export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected, gap_detected)
        SELECT b, %(org)s, %(site)s, %(dev)s, b - INTERVAL '1 minute',
               1000 + 10 * n, 990 + 10 * n, 10, 0.01, 'GOOD', TRUE, FALSE, FALSE,
               50, 50, 0, 0, 'GOOD', TRUE, FALSE, FALSE, FALSE
        FROM generate_series(%(start)s::timestamptz, %(end)s::timestamptz - INTERVAL '1 minute', INTERVAL '1 minute')
             WITH ORDINALITY AS g(b, n)
        """,
        {"org": t["org"], "site": t["site"], "dev": t["device"], "start": start, "end": end},
    )


def _seed_5min(cur, t, start, end):
    """Valid 5-minute intervals for t's device, [start, end)."""
    cur.execute(
        """
        INSERT INTO analytics.energy_consumption_5min (
            bucket_start, organization_id, site_id, device_id, previous_bucket_start,
            import_consumption_wh, import_consumption_kwh, import_quality_code, import_is_valid,
            import_reset_detected, import_rollover_detected,
            export_consumption_wh, export_consumption_kwh, export_quality_code, export_is_valid,
            export_reset_detected, export_rollover_detected, gap_detected)
        SELECT b, %(org)s, %(site)s, %(dev)s, b - INTERVAL '5 minutes',
               50, 0.05, 'GOOD', TRUE, FALSE, FALSE, 0, 0, 'GOOD', TRUE, FALSE, FALSE, FALSE
        FROM generate_series(%(start)s::timestamptz, %(end)s::timestamptz - INTERVAL '5 minutes', INTERVAL '5 minutes') AS g(b)
        """,
        {"org": t["org"], "site": t["site"], "dev": t["device"], "start": start, "end": end},
    )


def _tier15(cur, device, start, end):
    cur.execute(
        """
        SELECT bucket_start, source_interval_count, import_consumption_kwh
        FROM analytics.energy_consumption_15min
        WHERE device_id = %s AND bucket_start >= %s AND bucket_start < %s ORDER BY 1
        """,
        (device, start, end),
    )
    return cur.fetchall()


def _expected(start, end, per_bucket, kwh):
    out, b = [], start
    while b < end:
        out.append((b, per_bucket, kwh))
        b += Q
    return out


def _policy(cur, site, seconds, effective_from, effective_to=None, enabled=True):
    cur.execute(
        "INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, "
        "late_arrival_tolerance_seconds, effective_from, effective_to, is_enabled) "
        "VALUES (%s, %s, 'WALL_CLOCK', 60, %s, %s, %s)",
        (site, seconds, effective_from, effective_to, enabled),
    )


def _bare_site(cur):
    """A site with no capture policy of its own (holds the extra 300 s policies)."""
    cur.execute(
        "INSERT INTO metadata.organizations(name, code, timezone) "
        "VALUES ('M304 Org', 'M304_ORG_' || upper(left(md5(random()::text), 12)), 'UTC') RETURNING id"
    )
    org = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active) "
        "VALUES (%s, 'M304 bare site', 'M304_BARE_' || upper(left(md5(random()::text), 12)), 'UTC', TRUE) RETURNING id",
        (org,),
    )
    return cur.fetchone()[0]


def _run15(cur):
    cur.execute(JOB_15)
    return _cp(cur, "energy_consumption_15min")


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


def test_helper_is_invoker_sql_stable_owned_by_ems_admin_and_not_granted(tx):
    cur = tx.cursor()
    cur.execute(
        """
        SELECT l.lanname, p.provolatile, p.prosecdef, p.proconfig, r.rolname,
               has_function_privilege('public', p.oid, 'EXECUTE'),
               has_function_privilege('ems_app', p.oid, 'EXECUTE'),
               has_function_privilege('grafana_reader', p.oid, 'EXECUTE')
        FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = %s::regprocedure
        """,
        (HELPER,),
    )
    assert cur.fetchone() == ("sql", "s", False, None, "ems_admin", False, False, False)


def test_job_keeps_definer_owner_search_path_and_other_tier_bodies_are_unchanged(tx):
    cur = tx.cursor()
    cur.execute(
        """
        SELECT p.prosecdef, r.rolname, p.proconfig
        FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = 'analytics.run_energy_consumption_15min_job(integer, jsonb)'::regprocedure
        """
    )
    assert cur.fetchone() == (True, "ems_admin", ["search_path=pg_catalog, analytics"])
    cur.execute(
        """
        SELECT p.proname, md5(pg_get_functiondef(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'analytics' AND p.proname = ANY(%s)
        """,
        (list(UNCHANGED_MD5),),
    )
    assert dict(cur.fetchall()) == UNCHANGED_MD5


@pytest.mark.parametrize(
    "policy_from, policy_to, enabled, seconds, expected",
    [
        # window under test: [10:00, 11:00)
        ("2026-01-01 09:00", None, True, 300, True),           # open-ended, started before
        ("2026-01-01 10:59:59", None, True, 300, True),        # starts inside the last second
        ("2026-01-01 11:00", None, True, 300, False),          # starts at the window end ([) )
        ("2026-01-01 09:00", "2026-01-01 10:00", True, 300, False),     # ended at the window start
        ("2026-01-01 09:00", "2026-01-01 10:00:01", True, 300, True),   # ended one second inside
        ("2026-01-01 10:10", "2026-01-01 10:20", True, 300, True),      # wholly inside
        ("2026-01-01 09:00", None, False, 300, False),         # disabled
        ("2026-01-01 09:00", None, True, 900, False),          # not 300 s
        ("2026-01-01 09:00", None, True, 60, False),
    ],
)
def test_helper_overlap_is_half_open_enabled_and_300s_only(tx, policy_from, policy_to, enabled, seconds, expected):
    cur = tx.cursor()
    _no_300s_policies(cur)
    _policy(cur, _bare_site(cur), seconds, policy_from + "+00", policy_to and policy_to + "+00", enabled)
    cur.execute(f"SELECT {HELPER.split('(')[0]}(%s, %s)",
                (datetime(2026, 1, 1, 10, tzinfo=UTC), datetime(2026, 1, 1, 11, tzinfo=UTC)))
    assert cur.fetchone()[0] is expected


def test_helper_never_raises_on_an_empty_or_inverted_window(tx):
    cur = tx.cursor()
    t = datetime(2026, 1, 1, 10, tzinfo=UTC)
    _no_300s_policies(cur)
    _policy(cur, _bare_site(cur), 300, t - timedelta(days=1))
    cur.execute(f"SELECT {HELPER.split('(')[0]}(%s, %s), {HELPER.split('(')[0]}(%s, %s)", (t, t, t + Q, t))
    empty, inverted = cur.fetchone()
    assert isinstance(empty, bool) and isinstance(inverted, bool)


def test_platform_default_300s_policy_counts_even_when_shadowed_by_site_policies(tx):
    """Conservative: a 300 s platform default gates although every existing
    site overrides it with its own policy."""
    cur = tx.cursor()
    _no_300s_policies(cur)
    cur.execute("UPDATE config.telemetry_capture_policies SET is_enabled = FALSE WHERE site_id IS NULL")
    _policy(cur, None, 300, "2026-01-01 00:00+00")
    cur.execute(f"SELECT {HELPER.split('(')[0]}(%s, %s)",
                (datetime(2026, 1, 1, 10, tzinfo=UTC), datetime(2026, 1, 1, 11, tzinfo=UTC)))
    assert cur.fetchone()[0] is True


# ---------------------------------------------------------------------------
# Gate behaviour
# ---------------------------------------------------------------------------


def test_no_300s_policy_lagging_5min_checkpoint_no_longer_holds_the_15min_tier(tx):
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    a = _tenant(cur, 60)
    _seed_1min(cur, a, w - 2 * timedelta(hours=1), w)
    _checkpoints(cur, cp15=w - 5 * Q, cp1=w, cp5=w - 4 * Q)
    assert _run15(cur) == (w, "SUCCESS")
    # Every 1-minute reading of the window is rolled up: 15 intervals per bucket.
    assert _tier15(cur, a["device"], w - 7 * Q, w) == _expected(w - 7 * Q, w, 15, Decimal("0.15"))


def test_no_300s_policy_stalled_5min_checkpoint_does_not_stall_the_hourly_cascade(tx):
    """1080 stalled (or parked, T3.5 step 2) three hours back: 15-minute and
    hourly keep advancing. Under migration 209 the 15-minute run is a no-op."""
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    cur.execute("SELECT date_bin(INTERVAL '1 hour', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00')")
    h = cur.fetchone()[0]
    a = _tenant(cur, 60)
    _seed_1min(cur, a, h - timedelta(hours=3), w)
    _checkpoints(cur, cp15=w - 5 * Q, cp1=w, cp5=w - timedelta(hours=3), hourly=h - timedelta(hours=2))
    assert _run15(cur) == (w, "SUCCESS")
    cur.execute(JOB_HOURLY)
    assert _cp(cur, "energy_consumption_hourly")[0] == h


def test_mixed_policy_fleet_still_waits_for_the_5min_checkpoint(tx):
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    a, b = _tenant(cur, 60), _tenant(cur, 300)
    _seed_1min(cur, a, w - 2 * timedelta(hours=1), w)
    _seed_5min(cur, b, w - 2 * timedelta(hours=1), w)
    _checkpoints(cur, cp15=w - 5 * Q, cp1=w, cp5=w - 4 * Q)
    assert _run15(cur) == (w - 4 * Q, "SUCCESS")


def test_mixed_policy_fleet_rolls_up_every_5min_reading_that_arrives_after_the_15min_run(tx):
    """The 5-minute tier is computed only up to cp_5min when the 15-minute job
    runs; the rest arrives later. Without the gate the 15-minute checkpoint
    would pass those buckets for good (outside the next run's 30-min overlap)."""
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    a, b = _tenant(cur, 60), _tenant(cur, 300)
    start = w - 2 * timedelta(hours=1)
    _seed_1min(cur, a, start, w)
    _seed_5min(cur, b, start, w - 4 * Q)                 # computed so far
    _checkpoints(cur, cp15=w - 6 * Q, cp1=w, cp5=w - 4 * Q)
    assert _run15(cur)[0] == w - 4 * Q
    _seed_5min(cur, b, w - 4 * Q, w)                     # 1080 catches up
    _checkpoints(cur, cp15=_cp(cur, "energy_consumption_15min")[0], cp1=w, cp5=w)
    assert _run15(cur) == (w, "SUCCESS")
    assert _tier15(cur, b["device"], w - 8 * Q, w) == _expected(w - 8 * Q, w, 3, Decimal("0.15"))
    assert _tier15(cur, a["device"], w - 8 * Q, w) == _expected(w - 8 * Q, w, 15, Decimal("0.15"))


def test_300s_policy_that_ended_before_the_window_does_not_gate(tx):
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    cp15 = w - 5 * Q
    # The run refreshes [cp15 - 30 min, w): a policy ending at its start is out.
    _policy(cur, _bare_site(cur), 300, w - timedelta(days=2), cp15 - timedelta(minutes=30))
    _checkpoints(cur, cp15=cp15, cp1=w, cp5=w - 4 * Q)
    assert _run15(cur)[0] == w


def test_300s_policy_ending_one_second_inside_the_window_gates(tx):
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    cp15 = w - 5 * Q
    _policy(cur, _bare_site(cur), 300, w - timedelta(days=2), cp15 - timedelta(minutes=30) + timedelta(seconds=1))
    _checkpoints(cur, cp15=cp15, cp1=w, cp5=w - 4 * Q)
    assert _run15(cur)[0] == w - 4 * Q


def test_future_300s_policy_gates_only_once_the_window_reaches_it(tx):
    """A site switched to 300 s from F: windows ending at or before F are not
    held; the first window that reaches past F waits for the 5-minute tier."""
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    f = w - 2 * Q
    _policy(cur, _bare_site(cur), 300, f)
    _checkpoints(cur, cp15=w - 6 * Q, cp1=f, cp5=w - 5 * Q)
    assert _run15(cur)[0] == f                            # window [.., f): not gated
    _checkpoints(cur, cp15=f, cp1=w, cp5=w - 5 * Q)
    # [f - 30 min, w) overlaps: held at cp5 < f (migration-209 no-op status)
    assert _run15(cur) == (f, "NO_SOURCE_DATA")


def test_disabled_300s_policy_does_not_gate(tx):
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    _policy(cur, _bare_site(cur), 300, w - timedelta(days=2), enabled=False)
    _checkpoints(cur, cp15=w - 5 * Q, cp1=w, cp5=w - 4 * Q)
    assert _run15(cur)[0] == w


# ---------------------------------------------------------------------------
# Migration-209 edge semantics kept
# ---------------------------------------------------------------------------


def test_null_1min_checkpoint_falls_back_to_the_5min_checkpoint(tx):
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    _checkpoints(cur, cp15=w - 5 * Q, cp1=None, cp5=w - 2 * Q)
    assert _run15(cur)[0] == w - 2 * Q


def test_both_checkpoints_null_is_a_no_op(tx):
    cur = tx.cursor()
    w = _w(cur)
    _checkpoints(cur, cp15=w - 5 * Q, cp1=None, cp5=None)
    assert _run15(cur) == (w - 5 * Q, "NO_SOURCE_DATA")


def test_null_5min_checkpoint_with_a_300s_policy_uses_the_1min_checkpoint(tx):
    cur = tx.cursor()
    w = _w(cur)
    _policy(cur, _bare_site(cur), 300, w - timedelta(days=2))
    _checkpoints(cur, cp15=w - 5 * Q, cp1=w, cp5=None)
    assert _run15(cur)[0] == w


def test_5min_checkpoint_ahead_of_1min_is_bounded_by_1min_either_way(tx):
    cur = tx.cursor()
    w = _w(cur)
    _policy(cur, _bare_site(cur), 300, w - timedelta(days=2))
    _checkpoints(cur, cp15=w - 5 * Q, cp1=w - 2 * Q, cp5=w)
    assert _run15(cur)[0] == w - 2 * Q


@pytest.mark.parametrize("with_300s", [False, True])
def test_caught_up_checkpoint_is_success_and_unchanged(tx, with_300s):
    cur = tx.cursor()
    _no_300s_policies(cur)
    w = _w(cur)
    if with_300s:
        _policy(cur, _bare_site(cur), 300, w - timedelta(days=2))
    _checkpoints(cur, cp15=w, cp1=w, cp5=w)
    assert _run15(cur) == (w, "SUCCESS")
