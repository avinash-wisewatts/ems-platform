"""Migration 295: one-time narrowing of the System Energy stand-in assignments.

Every test seeds its own stand-in rows (ENERGY_IMPORT_TOTAL / ENERGY_EXPORT_TOTAL
asset_points rows starting at -infinity, created at a unique timestamp), the
meter readings and, where needed, System Energy rows, inside a transaction
that is rolled back, and drives admin.narrow_standin_energy_assignments_core.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import psycopg
import pytest

from tests.test_analytics_point_series_read import seed_15m, seed_raw
from tests.test_asset_energy_tier_read import CONNINFO, Tenant

UTC = timezone.utc
CORE = "admin.narrow_standin_energy_assignments_core"
CORE_SIG = f"{CORE}(text, timestamptz, integer, uuid, uuid[], boolean, integer)"
WRAPPER_SIG = "admin.narrow_standin_energy_assignments_20260925(text, uuid, boolean, integer)"
PLAN_SIG = "admin.standin_energy_narrow_plan(timestamptz, uuid)"
REVERT_SIG = "admin.revert_standin_energy_narrowing(text, uuid, boolean, integer)"
REVERT = "admin.revert_standin_energy_narrowing"

NOW = datetime.now(UTC).replace(second=0, microsecond=0)
PLUMBING = "8c7dc93b-37a0-4da9-a422-ccba063cf764"


def _bucket(at: datetime) -> datetime:
    return at - timedelta(minutes=at.minute % 15, seconds=at.second, microseconds=at.microsecond)


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


@pytest.fixture
def t(tx):
    return Tenant(tx.cursor())


class Standin:
    """Stand-in Energy rows created in one statement at a unique time."""

    def __init__(self, t: Tenant):
        self.t = t
        self.created = (NOW - timedelta(days=15)).replace(hour=15, minute=36, second=21) + timedelta(
            microseconds=uuid.uuid4().int % 999_999)
        self.rows = 0

    def point_id(self, name: str) -> str:
        self.t.cur.execute("SELECT id FROM metadata.logical_points WHERE name = %s", (name,))
        return str(self.t.cur.fetchone()[0])

    def bind(self, asset: str, device: str, point: str, *, start="-infinity", end=None, created=None) -> str:
        self.t.cur.execute(
            "INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, "
            "effective_from, effective_to, created_at) VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
            (asset, device, self.point_id(point), self.t.org, start, end, created or self.created),
        )
        if created is None and start == "-infinity":
            self.rows += 1
        return str(self.t.cur.fetchone()[0])

    def both(self, asset: str, device: str, **kw) -> dict[str, str]:
        return {p: self.bind(asset, device, p, **kw) for p in ("ENERGY_IMPORT_TOTAL", "ENERGY_EXPORT_TOTAL")}

    def readings(self, device: str, point: str, times: list[datetime], quality="GOOD", raw=True) -> None:
        pid = self.point_id(point)
        if raw:
            for at in times:
                seed_raw(self.t, device, pid, at, 1000, quality=quality)
        if quality == "GOOD":
            per: dict[datetime, int] = {}
            for at in times:
                per[_bucket(at)] = per.get(_bucket(at), 0) + 1
            for start, n in per.items():
                seed_15m(self.t, device, pid, start, total=1000 * n, count=n, low=1000, high=1000)

    def run(self, gateway=None, *, dry_run=True, confirm=None, excluded=(), expected=None):
        self.t.cur.execute(
            "SELECT asset_point_id, asset_name, device_name, point_name, action, "
            "CASE WHEN isfinite(current_effective_from) THEN current_effective_from END AS current_effective_from, "
            "effective_to, proposed_effective_from, audit_transaction_id "
            f"FROM {CORE}(%s, %s, %s, %s, %s::uuid[], %s, %s)",
            ("operator@test", self.created, self.rows if expected is None else expected,
             gateway or self.t.gateway, list(excluded), dry_run, confirm),
        )
        names = [c.name for c in self.t.cur.description]
        return [dict(zip(names, r)) for r in self.t.cur.fetchall()]


def _start(cur, ap_id: str):
    """effective_from, or the string '-infinity' (psycopg cannot load it)."""
    cur.execute(
        "SELECT CASE WHEN isfinite(effective_from) THEN effective_from END, effective_from::text "
        "FROM metadata.asset_points WHERE id = %s",
        (ap_id,),
    )
    value, text = cur.fetchone()
    return value if value is not None else text


def _audits(cur, op: str) -> int:
    cur.execute("SELECT count(*) FROM admin.onboarding_audit WHERE request_payload->>'operation' = %s", (op,))
    return cur.fetchone()[0]


def _by_point(plan):
    return {r["point_name"]: r for r in plan}


def _is_neg_inf(value) -> bool:
    return value == "-infinity"


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sig", [CORE_SIG, WRAPPER_SIG, PLAN_SIG, REVERT_SIG])
def test_functions_are_invoker_ems_admin_owned_and_not_granted(sig):
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT p.prosecdef, r.rolname, p.proconfig IS NOT NULL,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE')
            FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = %s::regprocedure
            """,
            (sig,),
        ).fetchone()
    assert row == (False, "ems_admin", True, False, False, False)


def test_wrapper_fixes_the_staging_standin_statement_and_excludes_plumbing():
    with psycopg.connect(CONNINFO) as connection:
        body = connection.execute("SELECT pg_get_functiondef(%s::regprocedure)", (WRAPPER_SIG,)).fetchone()[0]
    assert "'2026-09-25 21:06:21.442284+05:30'" in body
    assert "108," in body
    assert PLUMBING in body


def test_wrapper_does_nothing_where_the_standin_rows_do_not_exist(t):
    t.cur.execute("SELECT * FROM admin.narrow_standin_energy_assignments_20260925('operator@test', %s, FALSE, 0)", (t.gateway,))
    assert t.cur.fetchall() == []
    assert _audits(t.cur, "NARROW_STANDIN_ENERGY_ASSIGNMENTS") == 0


def test_manifest_registers_migration_295_last():
    import csv
    from pathlib import Path

    manifest = Path(__file__).resolve().parents[2] / "postgres" / "restructure_manifest.csv"
    rows = [r for r in csv.DictReader(manifest.read_text(encoding="utf-8").splitlines()) if r["target_category"] == "migration"]
    assert rows[-1]["source_file"] == "295_standin_energy_assignment_narrowing.sql"
    assert rows[-1]["target_path"] == "postgres/migrations/295_standin_energy_assignment_narrowing.sql"


# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------


def test_an_excluded_gateway_is_refused(t):
    s = Standin(t)
    s.both(t.asset("Pump"), t.device("Pump meter"))
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="excluded"):
        s.run(excluded=[t.gateway])


def test_standin_count_mismatch_refuses(t):
    s = Standin(t)
    s.both(t.asset("Pump"), t.device("Pump meter"))
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="Stand-in mismatch"):
        s.run(expected=3)


# ---------------------------------------------------------------------------
# Dry run and execution
# ---------------------------------------------------------------------------


def test_dry_run_proposes_the_first_good_reading_and_writes_nothing(t):
    s = Standin(t)
    asset, device = t.asset("Chiller"), t.device("Chiller meter")
    ids = s.both(asset, device)
    first = NOW - timedelta(days=40, minutes=3, seconds=17)
    s.readings(device, "ENERGY_IMPORT_TOTAL", [first - timedelta(minutes=2)], quality="BAD")
    s.readings(device, "ENERGY_IMPORT_TOTAL", [first, first + timedelta(minutes=1)])
    s.readings(device, "ENERGY_EXPORT_TOTAL", [first + timedelta(seconds=1)])

    t.cur.execute("SET TRANSACTION READ ONLY")
    plan = _by_point(s.run())
    assert (plan["ENERGY_IMPORT_TOTAL"]["action"], plan["ENERGY_IMPORT_TOTAL"]["proposed_effective_from"]) == ("NARROW", first)
    assert (plan["ENERGY_EXPORT_TOTAL"]["action"], plan["ENERGY_EXPORT_TOTAL"]["proposed_effective_from"]) == (
        "NARROW", first + timedelta(seconds=1))
    assert all(r["audit_transaction_id"] is None for r in plan.values())
    assert _is_neg_inf(_start(t.cur, ids["ENERGY_IMPORT_TOTAL"]))


def test_execution_narrows_and_writes_one_audit_with_before_and_after(t):
    s = Standin(t)
    asset, device = t.asset("Chiller"), t.device("Chiller meter")
    ids = s.both(asset, device)
    first = NOW - timedelta(days=40, minutes=3)
    s.readings(device, "ENERGY_IMPORT_TOTAL", [first])
    s.readings(device, "ENERGY_EXPORT_TOTAL", [first])

    result = s.run(dry_run=False, confirm=2)
    assert {r["action"] for r in result} == {"NARROW"}
    assert _start(t.cur, ids["ENERGY_IMPORT_TOTAL"]) == first
    audit_id = result[0]["audit_transaction_id"]
    t.cur.execute("SELECT requested_by, request_payload, result_payload FROM admin.onboarding_audit WHERE id = %s", (audit_id,))
    actor, request, outcome = t.cur.fetchone()
    assert actor == "operator@test" and request["operation"] == "NARROW_STANDIN_ENERGY_ASSIGNMENTS"
    assert outcome["narrowed_count"] == 2
    assert {r["effective_from_before"] for r in outcome["narrowed"]} == {"-infinity"}
    assert {datetime.fromisoformat(r["effective_from_after"]) for r in outcome["narrowed"]} == {first}

    # A second call still passes the stand-in count guard and changes nothing.
    again = s.run(dry_run=False, confirm=0)
    assert {r["action"] for r in again} == {"SKIPPED_NOT_INFINITY"}
    assert _start(t.cur, ids["ENERGY_IMPORT_TOTAL"]) == first


@pytest.mark.parametrize("confirm", [None, 0, 3])
def test_confirmation_mismatch_changes_nothing(t, confirm):
    s = Standin(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    ids = s.both(asset, device)
    s.readings(device, "ENERGY_IMPORT_TOTAL", [NOW - timedelta(days=5)])
    s.readings(device, "ENERGY_EXPORT_TOTAL", [NOW - timedelta(days=5)])
    t.cur.execute("SAVEPOINT s")
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="Confirmation mismatch"):
        s.run(dry_run=False, confirm=confirm)
    t.cur.execute("ROLLBACK TO SAVEPOINT s")
    assert _is_neg_inf(_start(t.cur, ids["ENERGY_IMPORT_TOTAL"]))
    assert _audits(t.cur, "NARROW_STANDIN_ENERGY_ASSIGNMENTS") == 0


# ---------------------------------------------------------------------------
# Guards on the proposed start
# ---------------------------------------------------------------------------


def test_expired_raw_readings_are_never_replaced_by_a_later_reading(t):
    """The first 15-minute row exists but its raw readings are gone: no change
    (a later raw reading must not become the start)."""

    s = Standin(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    s.both(asset, device)
    old = NOW - timedelta(days=60)
    s.readings(device, "ENERGY_IMPORT_TOTAL", [old], raw=False)               # 15-minute row only
    s.readings(device, "ENERGY_IMPORT_TOTAL", [NOW - timedelta(days=10)])      # a later, complete reading
    assert _by_point(s.run())["ENERGY_IMPORT_TOTAL"]["action"] == "NO_CHANGE_RAW_EXPIRED"


def test_no_reading_is_no_change(t):
    s = Standin(t)
    s.both(t.asset("Pump"), t.device("Pump meter"))
    assert {r["action"] for r in s.run()} == {"NO_CHANGE_NO_READING"}


def test_narrowing_that_would_hide_system_energy_is_refused(t):
    s = Standin(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    ids = s.both(asset, device)
    first = NOW - timedelta(days=20)
    s.readings(device, "ENERGY_IMPORT_TOTAL", [first])
    s.readings(device, "ENERGY_EXPORT_TOTAL", [first])
    t.seed(device, _bucket(first) - timedelta(hours=1), _bucket(first) - timedelta(minutes=45))   # valid 1-minute Energy before it
    plan = _by_point(s.run(dry_run=False, confirm=0))
    assert plan["ENERGY_IMPORT_TOTAL"]["action"] == "NO_CHANGE_WOULD_HIDE_ENERGY"
    assert plan["ENERGY_EXPORT_TOTAL"]["action"] == "NO_CHANGE_WOULD_HIDE_ENERGY"
    assert _is_neg_inf(_start(t.cur, ids["ENERGY_IMPORT_TOTAL"]))


def test_system_energy_in_the_straddling_minute_does_not_block(t):
    s = Standin(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    s.both(asset, device)
    first = _bucket(NOW - timedelta(days=20)) + timedelta(minutes=4, seconds=30)
    s.readings(device, "ENERGY_IMPORT_TOTAL", [first])
    s.readings(device, "ENERGY_EXPORT_TOTAL", [first])
    t.seed(device, first.replace(second=0), first.replace(second=0) + timedelta(minutes=10))   # starts in the same minute
    assert {r["action"] for r in s.run()} == {"NARROW"}


def test_a_closed_row_is_narrowed_only_before_its_end(t):
    s = Standin(t)
    asset, device = t.asset("Banquet 2 AHU"), t.device("Banquet 2 meter")
    end = NOW - timedelta(days=30)
    s.bind(asset, device, "ENERGY_EXPORT_TOTAL", end=end)
    imp = s.bind(asset, device, "ENERGY_IMPORT_TOTAL")
    s.readings(device, "ENERGY_EXPORT_TOTAL", [end + timedelta(days=1)])        # first reading after the end
    s.readings(device, "ENERGY_IMPORT_TOTAL", [end - timedelta(days=5)])
    plan = _by_point(s.run())
    assert plan["ENERGY_EXPORT_TOTAL"]["action"] == "NO_CHANGE_AFTER_END"
    assert plan["ENERGY_IMPORT_TOTAL"]["action"] == "NARROW"


def test_only_the_standin_statement_and_the_requested_gateway(t):
    s = Standin(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    s.both(asset, device)
    other_asset, other_device = t.asset("Other"), t.device("Other meter")
    other = s.bind(other_asset, other_device, "ENERGY_IMPORT_TOTAL", created=s.created + timedelta(seconds=1))
    for d in (device, other_device):
        s.readings(d, "ENERGY_IMPORT_TOTAL", [NOW - timedelta(days=5)])
    s.readings(device, "ENERGY_EXPORT_TOTAL", [NOW - timedelta(days=5)])

    t.cur.execute(
        "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
        (t.org, t.site, f"Far GW {t.tag}", f"FAR_GW_{t.tag}"),
    )
    far_gateway = str(t.cur.fetchone()[0])
    t.cur.execute(
        "INSERT INTO metadata.devices (organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
        "VALUES (%s, %s, %s, %s, 'Far meter', %s) RETURNING id",
        (t.org, far_gateway, t.model_id, t.profile_id, f"FAR_{t.tag}"),
    )
    far_device = str(t.cur.fetchone()[0])
    s.both(t.asset("Far pump"), far_device)

    here = s.run(dry_run=False, confirm=2)
    assert [(r["asset_name"], r["point_name"]) for r in here] == [("Pump", "ENERGY_EXPORT_TOTAL"), ("Pump", "ENERGY_IMPORT_TOTAL")]
    assert _is_neg_inf(_start(t.cur, other))
    assert {r["asset_name"] for r in s.run(gateway=far_gateway)} == {"Far pump"}


# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------


def test_revert_puts_minus_infinity_back_only_on_unchanged_rows(t):
    s = Standin(t)
    asset, device = t.asset("Chiller"), t.device("Chiller meter")
    ids = s.both(asset, device)
    first = NOW - timedelta(days=40)
    s.readings(device, "ENERGY_IMPORT_TOTAL", [first])
    s.readings(device, "ENERGY_EXPORT_TOTAL", [first])
    audit_id = s.run(dry_run=False, confirm=2)[0]["audit_transaction_id"]
    # someone changes the export row afterwards: it must not be reverted
    t.cur.execute("UPDATE metadata.asset_points SET effective_from = %s WHERE id = %s",
                  (first + timedelta(hours=1), ids["ENERGY_EXPORT_TOTAL"]))

    t.cur.execute(f"SELECT logical_point_name, action FROM {REVERT}('operator@test', %s, TRUE, NULL)", (audit_id,))
    dry = dict(t.cur.fetchall())
    assert dry == {"ENERGY_IMPORT_TOTAL": "REVERT", "ENERGY_EXPORT_TOTAL": "SKIPPED_CHANGED"}

    t.cur.execute(f"SELECT action FROM {REVERT}('operator@test', %s, FALSE, 1)", (audit_id,))
    t.cur.fetchall()
    assert _is_neg_inf(_start(t.cur, ids["ENERGY_IMPORT_TOTAL"]))
    assert _start(t.cur, ids["ENERGY_EXPORT_TOTAL"]) == first + timedelta(hours=1)
    assert _audits(t.cur, "REVERT_STANDIN_ENERGY_NARROWING") == 1


def test_revert_refuses_other_audit_records(t):
    t.cur.execute(
        "INSERT INTO admin.onboarding_audit (requested_by, request_payload, result_payload) "
        "VALUES ('x', '{\"operation\": \"SAVE_ASSET_POINT_ASSIGNMENTS\"}', '{}') RETURNING id"
    )
    other = t.cur.fetchone()[0]
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="not a NARROW"):
        t.cur.execute(f"SELECT * FROM {REVERT}('operator@test', %s, TRUE, NULL)", (other,))
