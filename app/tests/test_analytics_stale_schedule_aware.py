"""Migration 302 (plan T3.10, decision D-020): schedule-aware Analytics stale flag.

analytics.get_portal_asset_energy_series flags an asset stale when
    as_of - last_data_at > capture + tolerance + pipeline allowance
and migration 302 derives the allowance from the live forward-stage jobs
(analytics.energy_stale_pipeline_allowance): for a phased pipeline the batch
cycle plus the chained phase waits plus 60 s, otherwise the migration-282 sum.

Three groups of tests:
  * the migration file contract (no database): only the stale block of the
    migration-284 body changes, the md5 pins match, manifest order;
  * a timing model of the phased batch pipeline, driven by the job settings
    of the test database (phases, retry periods), calibrated against the
    healthy peak age measured on staging, and the function's verdict for
    every scenario: healthy batching, a normalization retry, a routing /
    refresh / 1-minute-tier retry and a missed batch;
  * the helper's branches: legacy (unphased) schedules keep the 282 value,
    races, end_offset, duplicate and missing stages.

DB tests run against the disposable ems_test database; each is one
rolled-back transaction.
"""

from __future__ import annotations

import csv
import hashlib
import re
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path

import psycopg
import pytest

from tests.test_analytics_energy_series_data_quality import dq
from tests.test_asset_energy_tier_read import CONNINFO, T0, Tenant, checkpoints

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "postgres" / "migrations"
MIGRATION = MIGRATIONS / "302_analytics_stale_schedule_aware.sql"
SERIES = "CREATE OR REPLACE FUNCTION analytics.get_portal_asset_energy_series"
HELPER = "analytics.energy_stale_pipeline_allowance"
MD5_284 = "3f43cdae3e4dbb21087d31bc77c7bab0"   # live on staging 2026-10-15

# Healthy peak age of the newest 1-minute data measured on staging under
# migration 300 (2026-10-14 11:55 .. 2026-10-15 12:15 UTC, 591 cycles of two
# devices on two sites): p50 9:00, p99 9:03, max 9:03.
MEASURED_HEALTHY_PEAK = timedelta(minutes=9, seconds=3)


def _lf(path: Path) -> str:
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


def _code(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))


def _series(text: str) -> str:
    start = text.index(SERIES)
    return text[start : text.index("$function$;", start) + len("$function$;")]


# ---------------------------------------------------------------------------
# Migration file contract
# ---------------------------------------------------------------------------


def test_migration_file_is_lf_and_has_no_transaction_control():
    raw = MIGRATION.read_bytes()
    assert b"\r" not in raw
    assert not re.search(r"^\s*(BEGIN|COMMIT|ROLLBACK)\s*;", raw.decode("utf-8"), re.MULTILINE)


def test_migration_creates_the_helper_and_replaces_only_the_series_function():
    code = _code(_lf(MIGRATION))
    assert re.findall(r"CREATE (?:OR REPLACE )?(?:FUNCTION|PROCEDURE) ([a-z_.]+)", code) == [
        HELPER,
        "analytics.get_portal_asset_energy_series",
    ]
    assert not re.search(
        r"\b(DROP|TRUNCATE)\b|\bGRANT\b|\bALTER\s+(TABLE|VIEW|SYSTEM|ROLE|DATABASE)\b|\bCREATE\s+(TABLE|INDEX|VIEW|TRIGGER)\b",
        code,
        re.IGNORECASE,
    )
    for job_call in ("alter_job", "add_job", "delete_job", "set_config"):
        assert job_call not in code
    # The only ALTER / REVOKE statements concern the new helper.
    for line in code.splitlines():
        if re.match(r"\s*(ALTER|REVOKE)\b", line):
            assert f"{HELPER}(integer)" in line, line


def test_series_body_differs_from_migration_284_only_in_the_stale_allowance_block():
    old = _series(_lf(MIGRATIONS / "284_analytics_energy_series_set_based_quality.sql"))
    new = _series(_lf(MIGRATION))
    old_start = old.index("    -- ------------------------------------------------------------------\n    -- Stale: live forward-stage schedules")
    old_end = old.index("    ) AS st;\n", old.index("INTO v_stage_5m")) + len("    ) AS st;\n")
    new_start = new.index("    -- ------------------------------------------------------------------\n    -- Stale: pipeline allowance")
    new_end = new.index(f"    v_stage_5m := {HELPER}(300);\n") + len(f"    v_stage_5m := {HELPER}(300);\n")
    assert old[:old_start] == new[:new_start]
    assert old[old_end:] == new[new_end:]
    block = new[new_start:new_end]
    assert f"v_stage_1m := {HELPER}(60);" in block and "timescaledb_information" not in block
    # The md5 swap-back postcondition carries exactly these blocks.
    text = _lf(MIGRATION)
    assert f"$old${old[old_start:old_end]}$old$" in text
    assert f"$new${block}$new$" in text
    assert _code(text).count(MD5_284) == 2


def test_manifest_registers_migration_302_after_301():
    manifest = ROOT / "postgres" / "restructure_manifest.csv"
    rows = [r for r in csv.DictReader(manifest.read_text(encoding="utf-8").splitlines()) if r["target_category"] == "migration"]
    files = [r["source_file"] for r in rows]
    row = rows[files.index(MIGRATION.name)]
    assert row["target_path"] == f"postgres/migrations/{MIGRATION.name}"
    assert files.index(MIGRATION.name) > files.index("301_device_telemetry_state_upsert_lock_order.sql")
    assert files.index(MIGRATION.name) > files.index("300_pipeline_five_minute_batch_schedule.sql")


# ---------------------------------------------------------------------------
# Pipeline timing model
# ---------------------------------------------------------------------------

STAGES = ("normalization", "routing", "refresh", "tier")


@dataclass(frozen=True)
class Schedule:
    cycle: int                 # seconds
    phase: dict[str, float]    # seconds after the grid boundary
    retry: dict[str, float]    # retry_period, seconds
    end_offset: int            # ca_energy_1min refresh end_offset, seconds


def _floor(t: float, step: int) -> int:
    return int(t // step) * step


def peak_age(s: Schedule, *, capture=60, tolerance=60, run_seconds=3.0, fail=None, miss=None) -> float:
    """Highest age (seconds) of the newest published 1-minute interval end.

    Each stage runs at k * cycle + phase, takes run_seconds and reads what its
    parent had committed when it started:
      normalization finalizes every bucket whose deadline (end + tolerance)
        has passed;
      routing copies the normalized frontier;
      the ca_energy_1min refresh materializes routed buckets that end before
        run_start - end_offset (the watermark is data-driven);
      the 1-minute tier publishes the materialized frontier.
    fail=(stage, cycle): that run fails and is retried once retry_period after
    it finished (succeeds). miss=(stage, cycle): the slot produces nothing (all
    retries fail before the next slot).
    """

    cycles = 8
    runs = []
    for k in range(cycles):
        for order, name in enumerate(STAGES):
            start = k * s.cycle + s.phase[name]
            if miss == (name, k):
                continue
            if fail == (name, k):
                start = start + run_seconds + s.retry[name]
            runs.append((start, order, name))
    runs.sort()

    commits = {name: [(float("-inf"), 0.0)] for name in STAGES}

    def committed(name: str, at: float) -> float:
        return max(v for c, v in commits[name] if c <= at)

    for start, _, name in runs:
        if name == "normalization":
            value = _floor(start - tolerance, capture)
        elif name == "routing":
            value = committed("normalization", start)
        elif name == "refresh":
            value = min(committed("routing", start), _floor(start - s.end_offset, capture))
        else:
            value = min(committed("refresh", start), _floor(start, capture))
        value = max(value, committed(name, start))
        commits[name].append((start + run_seconds, value))

    # The age is highest at the instant before each publication commits.
    # Observe cycles 3 (warm) to 7; scenarios inject in cycle 4.
    lo, hi = 3 * s.cycle, 7 * s.cycle
    tier = sorted(commits["tier"][1:])
    return max(c - prev for (_, prev), (c, _) in zip(tier, tier[1:]) if lo <= c <= hi)


def _schedule(cur) -> Schedule:
    cur.execute(
        """
        SELECT CASE WHEN j.proc_name = 'run_normalization_job' THEN 'normalization'
                    WHEN j.proc_name = 'run_energy_routing_job' THEN 'routing'
                    WHEN j.proc_name = 'run_energy_consumption_1min_job' THEN 'tier'
                    ELSE 'refresh' END,
               extract(epoch FROM j.schedule_interval)::int,
               mod(extract(epoch FROM j.initial_start), extract(epoch FROM j.schedule_interval))::float,
               extract(epoch FROM j.retry_period)::float,
               extract(epoch FROM (j.config ->> 'end_offset')::interval)::int
        FROM timescaledb_information.jobs AS j
        WHERE (j.proc_schema, j.proc_name) IN (('telemetry', 'run_normalization_job'),
                                               ('telemetry', 'run_energy_routing_job'),
                                               ('analytics', 'run_energy_consumption_1min_job'))
           OR (j.proc_name = 'policy_refresh_continuous_aggregate' AND j.hypertable_name = 'ca_energy_1min')
        """
    )
    rows = cur.fetchall()
    assert sorted(r[0] for r in rows) == sorted(STAGES)
    assert {r[1] for r in rows} == {300}
    return Schedule(
        cycle=300,
        phase={r[0]: r[2] for r in rows},
        retry={r[0]: r[3] for r in rows},
        end_offset=next(r[4] for r in rows if r[0] == "refresh"),
    )


MIGRATION_300 = Schedule(
    cycle=300,
    phase={"normalization": 160, "routing": 250, "refresh": 280, "tier": 0},
    retry={"normalization": 60, "routing": 60, "refresh": 60, "tier": 300},
    end_offset=60,
)


def test_test_database_runs_the_migration_300_schedule():
    with psycopg.connect(CONNINFO) as connection, connection.cursor() as cur:
        assert _schedule(cur) == MIGRATION_300


def test_model_reproduces_the_healthy_peak_measured_on_staging():
    assert peak_age(MIGRATION_300) == MEASURED_HEALTHY_PEAK.total_seconds()


@pytest.mark.parametrize(
    ("scenario", "kwargs", "expected_peak"),
    [
        ("healthy", {}, timedelta(minutes=9, seconds=3)),
        # 1000 fails at +2:40, retried at ~+3:43: still before routing (+4:10).
        ("normalization retry", {"fail": ("normalization", 4)}, timedelta(minutes=9, seconds=3)),
        # 1001 retried at ~+5:13: after the refresh (+4:40) and the tier (+0:00).
        ("routing retry", {"fail": ("routing", 4)}, timedelta(minutes=14, seconds=3)),
        ("refresh retry", {"fail": ("refresh", 4)}, timedelta(minutes=14, seconds=3)),
        ("1-minute tier retry", {"fail": ("tier", 4)}, timedelta(minutes=14, seconds=3)),
        ("missed normalization batch", {"miss": ("normalization", 4)}, timedelta(minutes=14, seconds=3)),
        ("missed routing batch", {"miss": ("routing", 4)}, timedelta(minutes=14, seconds=3)),
    ],
)
def test_model_peak_age_per_scenario(scenario, kwargs, expected_peak):
    assert peak_age(MIGRATION_300, **kwargs) == expected_peak.total_seconds(), scenario


def _stale_at(t: Tenant, asset, as_of) -> bool | None:
    rows = dq(t, [asset], T0, T0 + timedelta(hours=3), "1h", as_of=as_of)
    return rows[0]["import_stale"]


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


@pytest.fixture
def stale_asset(tx):
    """One asset on a 60 s capture / 60 s tolerance site with one hour of data;
    returns (tenant, asset, last_data_at, cursor)."""

    cur = tx.cursor()
    t = Tenant(cur)
    asset, device = t.simple_asset("Batch stale")
    t.seed(device, T0, T0 + timedelta(hours=1))
    t.refresh(T0, T0 + timedelta(hours=1))
    checkpoints(cur)
    return t, asset, T0 + timedelta(hours=1), cur


def test_threshold_under_migration_300_is_ten_minutes_twenty(stale_asset):
    t, asset, last, cur = stale_asset
    cur.execute(f"SELECT {HELPER}(60)")
    assert cur.fetchone()[0] == timedelta(minutes=8, seconds=20)
    threshold = timedelta(minutes=10, seconds=20)
    assert _stale_at(t, asset, last + threshold - timedelta(seconds=1)) is False
    assert _stale_at(t, asset, last + threshold) is False
    assert _stale_at(t, asset, last + threshold + timedelta(seconds=1)) is True


def test_healthy_five_minute_batching_never_flags_stale(stale_asset):
    """Every age the healthy phased pipeline reaches (one publication cycle:
    from the publication delay of 4:00 up to the 9:03 peak, plus 60 s of
    scheduler slack) is below the threshold."""

    t, asset, last, cur = stale_asset
    schedule = _schedule(cur)
    peak = timedelta(seconds=peak_age(schedule))
    assert peak == MEASURED_HEALTHY_PEAK
    age = timedelta(minutes=4)
    while age <= peak + timedelta(seconds=60):
        assert _stale_at(t, asset, last + age) is False, age
        age += timedelta(seconds=20)


def test_one_normalization_retry_is_tolerated(stale_asset):
    t, asset, last, cur = stale_asset
    schedule = _schedule(cur)
    peak = timedelta(seconds=peak_age(schedule, fail=("normalization", 4)))
    assert peak == MEASURED_HEALTHY_PEAK
    assert _stale_at(t, asset, last + peak) is False
    # Even if the retry cost its whole retry_period downstream, still not stale.
    assert _stale_at(t, asset, last + peak + timedelta(seconds=schedule.retry["normalization"])) is False


@pytest.mark.parametrize(
    "kwargs",
    [{"miss": ("normalization", 4)}, {"miss": ("routing", 4)}, {"fail": ("routing", 4)},
     {"fail": ("refresh", 4)}, {"fail": ("tier", 4)}],
    ids=["missed normalization batch", "missed routing batch", "routing retry", "refresh retry", "1-minute tier retry"],
)
def test_a_batch_delayed_by_a_whole_cycle_is_flagged(stale_asset, kwargs):
    """A missed batch delays the newest data by one cycle (peak 14:03), which
    is flagged. A routing / refresh / tier retry lands after the 1-minute tier's
    slot and has the same effect; it shows stale until the next publication
    (decided by the user, run 22: detect the missed batch rather than tolerate
    a routing retry; the two are indistinguishable at this read)."""

    t, asset, last, cur = stale_asset
    peak = timedelta(seconds=peak_age(_schedule(cur), **kwargs))
    assert peak == timedelta(minutes=14, seconds=3)
    assert _stale_at(t, asset, last + peak) is True


def test_stopped_data_is_flagged_and_stays_flagged(stale_asset):
    t, asset, last, _ = stale_asset
    for age in (timedelta(minutes=11), timedelta(minutes=30), timedelta(hours=1, minutes=30)):
        assert _stale_at(t, asset, last + age) is True


def test_semantics_kept_for_no_data_ended_binding_and_out_of_range(stale_asset):
    t, asset, last, cur = stale_asset
    # Never-reported asset: no last data -> FALSE (not NULL), whatever the age.
    empty, _ = t.simple_asset("Never reported")
    rows = dq(t, [empty], T0, T0 + timedelta(hours=3), "1h", as_of=last + timedelta(hours=1))
    assert (rows[0]["import_last_data_at"], rows[0]["import_stale"]) == (None, False)
    # last_data_at outside the requested range -> not stale.
    rows = dq(t, [asset], T0 + timedelta(hours=2), T0 + timedelta(hours=3), "1h", as_of=last + timedelta(hours=1))
    assert rows[0]["import_stale"] is False
    # Binding ended at last data (device removed, not offline) -> not stale.
    cur.execute("UPDATE metadata.asset_points SET effective_to = %s WHERE asset_id = %s", (last, asset))
    assert _stale_at(t, asset, last + timedelta(minutes=30)) is False


# ---------------------------------------------------------------------------
# Helper branches
# ---------------------------------------------------------------------------


def _jobs(cur) -> dict[str, int]:
    cur.execute(
        """
        SELECT CASE WHEN j.proc_name = 'run_normalization_job' THEN 'normalization'
                    WHEN j.proc_name = 'run_energy_routing_job' THEN 'routing'
                    WHEN j.proc_name = 'run_energy_consumption_1min_job' THEN 'tier'
                    ELSE 'refresh' END, j.job_id
        FROM timescaledb_information.jobs AS j
        WHERE (j.proc_schema, j.proc_name) IN (('telemetry', 'run_normalization_job'),
                                               ('telemetry', 'run_energy_routing_job'),
                                               ('analytics', 'run_energy_consumption_1min_job'))
           OR (j.proc_name = 'policy_refresh_continuous_aggregate' AND j.hypertable_name = 'ca_energy_1min')
        """
    )
    return dict(cur.fetchall())


def _allowance(cur, native=60):
    cur.execute(f"SELECT {HELPER}(%s)", (native,))
    return cur.fetchone()[0]


LEGACY_SUM_SQL = """
    SELECT CASE WHEN COUNT(*) = 4 THEN SUM(st.si) + COALESCE(MAX(st.eo), INTERVAL '0') END
    FROM (
        SELECT j.proc_schema, j.proc_name, MAX(j.schedule_interval) AS si,
               MAX((j.config ->> 'end_offset')::INTERVAL) AS eo
        FROM timescaledb_information.jobs AS j
        WHERE (j.proc_schema, j.proc_name) IN (('telemetry', 'run_normalization_job'),
                                               ('telemetry', 'run_energy_routing_job'),
                                               ('analytics', %(tier)s))
           OR (j.proc_name = 'policy_refresh_continuous_aggregate'
               AND j.hypertable_schema = 'telemetry' AND j.hypertable_name = %(cagg)s)
        GROUP BY j.proc_schema, j.proc_name
    ) AS st
"""


def _legacy(cur, native=60):
    """The migration-282/284 allowance, verbatim."""
    tier, cagg = (("run_energy_consumption_1min_job", "ca_energy_1min") if native == 60
                  else ("run_energy_consumption_5min_job", "ca_energy_5min"))
    cur.execute(LEGACY_SUM_SQL, {"tier": tier, "cagg": cagg})
    return cur.fetchone()[0]


def test_pre_migration_300_one_minute_schedule_keeps_the_282_value(tx):
    """Production before migration 300: every stage 1 minute, the CAGG
    refresh not on a fixed schedule -> not phased -> the 282 sum (5 minutes,
    threshold 7 minutes), unchanged."""

    with tx.cursor() as cur:
        jobs = _jobs(cur)
        for name, job in jobs.items():
            cur.execute("SELECT alter_job(%s, schedule_interval => INTERVAL '1 minute', fixed_schedule => %s)",
                        (job, name != "refresh"))
        assert _allowance(cur) == _legacy(cur) == timedelta(minutes=5)


@pytest.mark.parametrize(
    "phases",
    [
        # Production at migration 265 (2026-10-14 job listing): normalization
        # every minute at :24; the other phases are not recorded, so several
        # combinations are covered -- with a drifting refresh they cannot matter.
        {"normalization": 24, "routing": 24.5, "tier": 30},
        {"normalization": 24, "routing": 51, "tier": 2},
        {"normalization": 24, "routing": 0, "tier": 24},
    ],
    ids=["routing-0.5s-after", "spread", "same-as-normalization"],
)
def test_production_one_minute_schedule_keeps_the_seven_minute_threshold(stale_asset, phases):
    """Production before migration 300: normalization, routing and the
    1-minute job on fixed 1-minute schedules; the ca_energy_1min refresh
    policy registered without initial_start (ddl/121), i.e. drifting. The
    helper returns the migration-282 sum (4 x 1 + 1 = 5 minutes) whatever the
    phases, and the series function flags stale exactly as before: at
    60 s + 60 s + 5 min = 7 minutes. A missing stage still gives NULL."""

    t, asset, last, cur = stale_asset
    for name, job in _jobs(cur).items():
        if name == "refresh":
            cur.execute("SELECT alter_job(%s, schedule_interval => INTERVAL '1 minute', fixed_schedule => FALSE)", (job,))
        else:
            cur.execute(
                "SELECT alter_job(%s, schedule_interval => INTERVAL '1 minute', fixed_schedule => TRUE, "
                "initial_start => TIMESTAMPTZ '2026-08-01 00:00:00+00' + make_interval(secs => %s))",
                (job, phases[name]),
            )
    assert _allowance(cur) == _legacy(cur) == timedelta(minutes=5)
    seven = timedelta(minutes=7)
    assert _stale_at(t, asset, last + seven - timedelta(seconds=1)) is False
    assert _stale_at(t, asset, last + seven) is False
    assert _stale_at(t, asset, last + seven + timedelta(seconds=1)) is True
    cur.execute("SELECT delete_job(%s)", (_jobs(cur)["tier"],))
    assert _allowance(cur) is None
    assert _stale_at(t, asset, last + timedelta(hours=1)) is None


def test_five_minute_path_is_unphased_and_keeps_the_282_value(tx):
    with tx.cursor() as cur:
        assert _allowance(cur, 300) == _legacy(cur, 300)
        assert _allowance(cur, 300) is not None


@pytest.mark.parametrize(
    ("phases", "expected"),
    [
        # Ordered 1-minute phases, refresh 20 s after normalization: the 60 s
        # end_offset can exclude the routed batch -> not phased -> 282 sum.
        ({"normalization": 0, "routing": 10, "refresh": 20, "tier": 30}, timedelta(minutes=5)),
        # Ordered with a refresh wait (40 + 25 s) >= end_offset: 60 + 75 + 60 s.
        ({"normalization": 0, "routing": 40, "refresh": 5, "tier": 15}, timedelta(seconds=60 + 75 + 60)),
        # Same second for every stage: each wait is a race -> one more cycle each.
        ({"normalization": 5, "routing": 5, "refresh": 5, "tier": 5}, timedelta(seconds=60 + 180 + 60)),
        # Routing 2 s after normalization (it would route the previous batch): race.
        ({"normalization": 0, "routing": 2, "refresh": 30, "tier": 40}, timedelta(seconds=60 + (62 + 28 + 10) + 60)),
    ],
    ids=["ordered-end-offset-fallback", "ordered", "all-same-phase", "routing-race"],
)
def test_phased_one_minute_schedules(tx, phases, expected):
    with tx.cursor() as cur:
        for name, job in _jobs(cur).items():
            cur.execute(
                "SELECT alter_job(%s, schedule_interval => INTERVAL '1 minute', fixed_schedule => TRUE, "
                "initial_start => TIMESTAMPTZ '2026-01-01 00:00:00+00' + make_interval(secs => %s))",
                (job, phases[name]),
            )
        assert _allowance(cur) == expected


def test_end_offset_beyond_the_refresh_wait_falls_back_to_the_282_sum(tx):
    with tx.cursor() as cur:
        refresh = _jobs(cur)["refresh"]
        cur.execute(
            "SELECT alter_job(j.job_id, config => jsonb_set(j.config, '{end_offset}', '\"3 minutes\"')) "
            "FROM timescaledb_information.jobs AS j WHERE j.job_id = %s", (refresh,))
        assert _allowance(cur) == _legacy(cur) == timedelta(minutes=23)


def test_unequal_stage_intervals_fall_back_to_the_282_sum(tx):
    with tx.cursor() as cur:
        cur.execute("SELECT alter_job(%s, schedule_interval => INTERVAL '1 minute')", (_jobs(cur)["tier"],))
        assert _allowance(cur) == _legacy(cur) == timedelta(minutes=17)


def test_unfixed_stage_falls_back_to_the_282_sum(tx):
    with tx.cursor() as cur:
        cur.execute("SELECT alter_job(%s, fixed_schedule => FALSE)", (_jobs(cur)["routing"],))
        assert _allowance(cur) == _legacy(cur) == timedelta(minutes=21)


def test_missing_stage_gives_no_allowance_and_no_stale_verdict(stale_asset):
    t, asset, last, cur = stale_asset
    cur.execute("SELECT delete_job(%s)", (_jobs(cur)["routing"],))
    assert _allowance(cur) is None
    assert _stale_at(t, asset, last + timedelta(hours=1)) is None


def test_helper_is_sql_stable_invoker_and_not_directly_executable():
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT l.lanname, p.provolatile, p.prosecdef, p.proconfig, r.rolname,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE')
            FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner JOIN pg_language AS l ON l.oid = p.prolang
            WHERE p.oid = %s::regprocedure
            """,
            (f"{HELPER}(integer)",),
        ).fetchone()
    assert row == ("sql", "s", False, None, "ems_admin", False, False, False)


def test_series_function_md5_swap_back_equals_migration_284():
    """The live postcondition, repeated: replacing the helper calls with the
    284 block reproduces the 284 definition byte for byte."""

    text = _lf(MIGRATION)
    old_block = text.split("$old$")[1]
    new_block = text.split("$new$")[1]
    with psycopg.connect(CONNINFO) as connection:
        definition = connection.execute(
            "SELECT pg_get_functiondef('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)'::regprocedure)"
        ).fetchone()[0]
    assert definition.count(new_block) == 1
    assert hashlib.md5(definition.replace(new_block, old_block).encode("utf-8")).hexdigest() == MD5_284
