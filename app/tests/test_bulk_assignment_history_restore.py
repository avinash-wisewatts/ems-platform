"""Migration 294: one-time restoration of asset history for the 9 October 2026
staging bulk assignment.

Every test seeds its own small "bulk assignment" (SAVE_ASSET_POINT_ASSIGNMENTS
audit records at a unique timestamp, the asset_points rows they added, raw
readings and GOOD-only 15-minute rows) inside a transaction that is rolled
back, and drives admin.restore_bulk_assignment_history_core with that
timestamp and explicit expected counts.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone

import psycopg
import pytest

from tests.test_analytics_point_series_read import seed_15m, seed_raw
from tests.test_asset_energy_tier_read import CONNINFO, Tenant

UTC = timezone.utc
CORE = "admin.restore_bulk_assignment_history_core"
CORE_SIG = f"{CORE}(text, timestamptz, integer, integer, uuid, uuid[], timestamptz, boolean, integer)"
WRAPPER_SIG = "admin.restore_bulk_assignment_history_20261009(text, uuid, boolean, integer)"
PLAN_SIG = "admin.bulk_assignment_restore_plan(timestamptz, uuid, uuid[], timestamptz)"
FIRST_SIG = "admin.bulk_restore_first_reading(uuid, uuid, timestamptz, timestamptz)"

NOW = datetime.now(UTC).replace(second=0, microsecond=0)
AS_OF = NOW
Q = timedelta(minutes=15)


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


class Bulk:
    """A seeded bulk assignment: one audit per (asset, device) Save at a
    unique timestamp, recording the asset_points rows it added."""

    def __init__(self, t: Tenant):
        self.t = t
        # A unique, mid-bucket bulk time a few days back (inside 90 days).
        self.at = (NOW - timedelta(days=3)).replace(minute=56, second=55) + timedelta(microseconds=uuid.uuid4().int % 999_999)
        self.audits = 0
        self.rows = 0

    def point_id(self, name: str) -> str:
        self.t.cur.execute("SELECT id FROM metadata.logical_points WHERE name = %s", (name,))
        row = self.t.cur.fetchone()
        if row is None:
            pytest.skip(f"logical point {name} is not seeded")
        return str(row[0])

    def bind(self, asset: str, device: str, point: str, start=None, end=None) -> str:
        self.t.cur.execute(
            "INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
            (asset, device, self.point_id(point), self.t.org, start or self.at, end),
        )
        return str(self.t.cur.fetchone()[0])

    def save(self, asset: str, device: str, points: list[str]) -> dict[str, str]:
        """Bulk-add `points` for (asset, device) and record the audit."""
        ids = {p: self.bind(asset, device, p) for p in points}
        self.audit(asset, device, list(ids.values()))
        return ids

    def audit(self, asset: str, device: str, asset_point_ids: list[str]) -> None:
        self.t.cur.execute(
            "INSERT INTO admin.onboarding_audit (requested_by, request_payload, result_payload, created_at) "
            "VALUES ('admin_test', %s, %s, %s)",
            (
                json.dumps({"operation": "SAVE_ASSET_POINT_ASSIGNMENTS", "asset_id": asset, "device_id": device}),
                json.dumps({"added": [{"asset_point_id": i} for i in asset_point_ids], "success": True}),
                self.at,
            ),
        )
        self.audits += 1
        self.rows += len(asset_point_ids)

    def readings(self, device: str, point: str, times: list[datetime], quality="GOOD") -> None:
        """Raw readings plus the GOOD-only 15-minute rows they produce."""
        pid = self.point_id(point)
        for at in times:
            seed_raw(self.t, device, pid, at, 10, quality=quality)
        if quality == "GOOD":
            per_bucket: dict[datetime, int] = {}
            for at in times:
                per_bucket[_bucket(at)] = per_bucket.get(_bucket(at), 0) + 1
            for start, n in per_bucket.items():
                seed_15m(self.t, device, pid, start, total=10 * n, count=n, low=10, high=10)

    def run(self, gateway=None, *, dry_run=True, confirm=None, excluded=(), as_of=AS_OF, audits=None, rows=None):
        self.t.cur.execute(
            f"SELECT * FROM {CORE}(%s, %s, %s, %s, %s, %s::uuid[], %s, %s, %s)",
            ("operator@test", self.at, self.audits if audits is None else audits,
             self.rows if rows is None else rows, gateway or self.t.gateway, list(excluded),
             as_of, dry_run, confirm),
        )
        names = [c.name for c in self.t.cur.description]
        return [dict(zip(names, r)) for r in self.t.cur.fetchall()]


def _start(cur, asset_point_id: str):
    cur.execute("SELECT effective_from FROM metadata.asset_points WHERE id = %s", (asset_point_id,))
    return cur.fetchone()[0]


def _restore_audits(cur) -> int:
    cur.execute("SELECT count(*) FROM admin.onboarding_audit WHERE request_payload->>'operation' = 'RESTORE_BULK_ASSIGNMENT_HISTORY'")
    return cur.fetchone()[0]


def _by_point(plan):
    return {r["point_name"]: r for r in plan}


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sig", [CORE_SIG, WRAPPER_SIG, PLAN_SIG, FIRST_SIG])
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


def test_wrapper_fixes_the_staging_bulk_and_excludes_heatventunit_01():
    with psycopg.connect(CONNINFO) as connection:
        body = connection.execute("SELECT pg_get_functiondef(%s::regprocedure)", (WRAPPER_SIG,)).fetchone()[0]
    assert "'2026-10-09 12:56:55.116554+05:30'" in body
    assert "55," in body and "3021," in body
    assert "2ac4031d-b2dc-4cf1-9549-2763f633092a" in body
    assert "now()" in body


def test_wrapper_does_nothing_where_the_bulk_assignment_does_not_exist(t):
    t.cur.execute("SELECT * FROM admin.restore_bulk_assignment_history_20261009('operator@test', %s, FALSE, 0)", (t.gateway,))
    assert t.cur.fetchall() == []
    assert _restore_audits(t.cur) == 0


def test_manifest_registers_migration_294():
    import csv
    from pathlib import Path

    manifest = Path(__file__).resolve().parents[2] / "postgres" / "restructure_manifest.csv"
    rows = [r for r in csv.DictReader(manifest.read_text(encoding="utf-8").splitlines()) if r["target_category"] == "migration"]
    files = [r["source_file"] for r in rows]
    row = rows[files.index("294_bulk_assignment_history_restore.sql")]
    assert row["target_path"] == "postgres/migrations/294_bulk_assignment_history_restore.sql"
    assert files.index("294_bulk_assignment_history_restore.sql") > files.index("293_analytics_point_series_planner_fences.sql")


# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------


def test_unknown_bulk_time_is_nothing_to_do(t):
    b = Bulk(t)
    assert b.run(audits=1, rows=1) == []


def test_audit_or_row_count_mismatch_refuses(t):
    b = Bulk(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    for kw in ({"audits": 2}, {"rows": 5}):
        t.cur.execute("SAVEPOINT s")
        with pytest.raises(psycopg.errors.InvalidParameterValue, match="audit mismatch"):
            b.run(**kw)
        t.cur.execute("ROLLBACK TO SAVEPOINT s")


def test_actor_is_required(t):
    b = Bulk(t)
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="p_actor"):
        t.cur.execute(f"SELECT * FROM {CORE}('  ', %s, 1, 1, %s, '{{}}', %s, TRUE, NULL)", (b.at, t.gateway, AS_OF))


def test_gateway_must_exist(t):
    b = Bulk(t)
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="does not exist"):
        t.cur.execute(f"SELECT * FROM {CORE}('op', %s, 1, 1, %s, '{{}}', %s, TRUE, NULL)", (b.at, str(uuid.uuid4()), AS_OF))


# ---------------------------------------------------------------------------
# Dry run and execution
# ---------------------------------------------------------------------------


def test_dry_run_proposes_the_first_good_reading_and_writes_nothing(t):
    b = Bulk(t)
    asset, device = t.asset("Chiller"), t.device("Chiller meter")
    ids = b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    first_good = b.at - timedelta(days=20, minutes=7, seconds=12)
    b.readings(device, "ACTIVE_POWER_TOTAL", [first_good - timedelta(minutes=2)], quality="BAD")  # not valid
    b.readings(device, "ACTIVE_POWER_TOTAL", [first_good, first_good + timedelta(minutes=1), b.at - timedelta(days=1)])

    plan = b.run()
    assert [(r["point_name"], r["action"], r["current_effective_from"], r["proposed_effective_from"], r["audit_transaction_id"])
            for r in plan] == [("ACTIVE_POWER_TOTAL", "RESTORE", b.at, first_good, None)]
    assert _start(t.cur, ids["ACTIVE_POWER_TOTAL"]) == b.at
    assert _restore_audits(t.cur) == 0


def test_dry_run_runs_in_a_read_only_transaction(t):
    b = Bulk(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    b.readings(device, "ACTIVE_POWER_TOTAL", [b.at - timedelta(days=2)])
    t.cur.execute("SET TRANSACTION READ ONLY")
    assert [r["action"] for r in b.run()] == ["RESTORE"]


def test_execution_moves_the_start_earlier_and_writes_one_audit_with_before_and_after(t):
    b = Bulk(t)
    asset, device = t.asset("Chiller"), t.device("Chiller meter")
    ids = b.save(asset, device, ["ACTIVE_POWER_TOTAL", "CURRENT_TOTAL", "FREQUENCY"])
    p_first = b.at - timedelta(days=30, seconds=5)
    c_first = b.at - timedelta(days=29, minutes=3)
    b.readings(device, "ACTIVE_POWER_TOTAL", [p_first])
    b.readings(device, "CURRENT_TOTAL", [c_first])
    # FREQUENCY has no reading before the bulk time -> unchanged

    result = _by_point(b.run(dry_run=False, confirm=2))
    assert {p: (r["action"], r["proposed_effective_from"]) for p, r in result.items()} == {
        "ACTIVE_POWER_TOTAL": ("RESTORE", p_first),
        "CURRENT_TOTAL": ("RESTORE", c_first),
        "FREQUENCY": ("NO_CHANGE_NO_HISTORY", None),
    }
    assert _start(t.cur, ids["ACTIVE_POWER_TOTAL"]) == p_first
    assert _start(t.cur, ids["CURRENT_TOTAL"]) == c_first
    assert _start(t.cur, ids["FREQUENCY"]) == b.at

    audit_id = result["ACTIVE_POWER_TOTAL"]["audit_transaction_id"]
    t.cur.execute("SELECT requested_by, request_payload, result_payload FROM admin.onboarding_audit WHERE id = %s", (audit_id,))
    actor, request, outcome = t.cur.fetchone()
    assert actor == "operator@test"
    assert request["operation"] == "RESTORE_BULK_ASSIGNMENT_HISTORY" and request["confirm_restore_count"] == 2
    assert outcome["restored_count"] == 2
    restored = {r["logical_point_name"]: r for r in outcome["restored"]}
    assert set(restored) == {"ACTIVE_POWER_TOTAL", "CURRENT_TOTAL"}
    assert datetime.fromisoformat(restored["ACTIVE_POWER_TOTAL"]["effective_from_before"]) == b.at
    assert datetime.fromisoformat(restored["ACTIVE_POWER_TOTAL"]["effective_from_after"]) == p_first
    assert [(r["logical_point_name"], r["action"]) for r in outcome["not_restored"]] == [("FREQUENCY", "NO_CHANGE_NO_HISTORY")]
    assert _restore_audits(t.cur) == 1


def test_a_second_execution_changes_nothing(t):
    b = Bulk(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    ids = b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    first = b.at - timedelta(days=4)
    b.readings(device, "ACTIVE_POWER_TOTAL", [first])
    b.run(dry_run=False, confirm=1)

    again = b.run(dry_run=False, confirm=0)
    assert [r["action"] for r in again] == ["SKIPPED_START_CHANGED"]
    assert _start(t.cur, ids["ACTIVE_POWER_TOTAL"]) == first


@pytest.mark.parametrize("confirm", [None, 0, 2])
def test_confirmation_mismatch_changes_nothing(tx, confirm):
    t = Tenant(tx.cursor())
    b = Bulk(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    ids = b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    b.readings(device, "ACTIVE_POWER_TOTAL", [b.at - timedelta(days=4)])
    t.cur.execute("SAVEPOINT s")
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="Confirmation mismatch"):
        b.run(dry_run=False, confirm=confirm)
    t.cur.execute("ROLLBACK TO SAVEPOINT s")
    assert _start(t.cur, ids["ACTIVE_POWER_TOTAL"]) == b.at
    assert _restore_audits(t.cur) == 0


# ---------------------------------------------------------------------------
# Start-date rules
# ---------------------------------------------------------------------------


def test_never_earlier_than_the_90_day_limit(t):
    b = Bulk(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    too_old = AS_OF - timedelta(days=95)
    inside = AS_OF - timedelta(days=80, minutes=2)
    b.readings(device, "ACTIVE_POWER_TOTAL", [too_old, inside])

    (row,) = b.run()
    assert row["lower_bound"] == AS_OF - timedelta(days=90)
    assert row["proposed_effective_from"] == inside


def test_a_bucket_straddling_the_lower_bound_uses_only_readings_after_it(t):
    """The AirSense case: the meter's earlier relationship ended mid-bucket;
    a reading in the same 15 minutes but before the boundary is never used."""

    b = Bulk(t)
    asset, device = t.asset("Banquet AHU"), t.device("AirSense sensor")
    b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    boundary = _bucket(b.at - timedelta(days=10)) + timedelta(minutes=7, seconds=30)
    before, after = boundary - timedelta(minutes=3), boundary + timedelta(seconds=50)
    b.readings(device, "ACTIVE_POWER_TOTAL", [before, after])
    t.cur.execute(
        "INSERT INTO metadata.asset_device_relationship_history "
        "(relationship_id, asset_id, device_id, relationship_type, relationship_created_at, archived_at, "
        " archive_action, archive_reason, audit_transaction_id) "
        "VALUES (gen_random_uuid(), %s, %s, 'TEMPERATURE_SENSOR', %s, %s, 'REMOVED', 'moved to another AHU', gen_random_uuid())",
        (t.asset("Other AHU"), device, boundary - timedelta(hours=9), boundary),
    )

    (row,) = b.run()
    assert row["lower_bound"] == boundary
    assert row["proposed_effective_from"] == after


def test_never_minus_infinity_and_only_ever_earlier(t):
    b = Bulk(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    b.save(asset, device, ["ACTIVE_POWER_TOTAL", "CURRENT_TOTAL"])
    b.readings(device, "ACTIVE_POWER_TOTAL", [b.at + timedelta(hours=1)])   # only after the bulk time
    b.readings(device, "CURRENT_TOTAL", [b.at - timedelta(days=1)])
    plan = _by_point(b.run())
    assert plan["ACTIVE_POWER_TOTAL"]["action"] == "NO_CHANGE_NO_HISTORY"
    assert plan["CURRENT_TOTAL"]["proposed_effective_from"] < b.at
    assert all(r["proposed_effective_from"] is None or r["proposed_effective_from"] > datetime(2000, 1, 1, tzinfo=UTC)
               for r in plan.values())


# ---------------------------------------------------------------------------
# Exclusions and scope
# ---------------------------------------------------------------------------


def test_a_deliberate_gap_is_preserved(t):
    """Banquet 2 AHU Energy Export: the same meter point had an earlier,
    closed assignment; the bulk row must not reach back over the gap."""

    b = Bulk(t)
    asset, device = t.asset("Banquet 2 AHU"), t.device("Banquet 2 meter")
    closed_at = b.at - timedelta(days=4)
    b.bind(asset, device, "ENERGY_EXPORT_TOTAL", start=b.at - timedelta(days=60), end=closed_at)
    ids = b.save(asset, device, ["ENERGY_EXPORT_TOTAL", "ACTIVE_POWER_TOTAL"])
    b.readings(device, "ENERGY_EXPORT_TOTAL", [b.at - timedelta(days=50), b.at - timedelta(days=2)])
    b.readings(device, "ACTIVE_POWER_TOTAL", [b.at - timedelta(days=50)])

    plan = _by_point(b.run(dry_run=False, confirm=1))
    assert plan["ENERGY_EXPORT_TOTAL"]["action"] == "EXCLUDED_OTHER_BINDING"
    assert _start(t.cur, ids["ENERGY_EXPORT_TOTAL"]) == b.at
    assert plan["ACTIVE_POWER_TOTAL"]["action"] == "RESTORE"


def test_excluded_inactive_closed_and_changed_rows_are_left_alone(t):
    b = Bulk(t)
    excluded_asset, d1 = t.asset("HeatVentUnit-01"), t.device("HVU meter")
    inactive_asset, d2 = t.asset("Retired", lifecycle="INACTIVE"), t.device("Retired meter")
    asset, d3 = t.asset("Pump"), t.device("Pump meter")
    e = b.save(excluded_asset, d1, ["ACTIVE_POWER_TOTAL"])
    i = b.save(inactive_asset, d2, ["ACTIVE_POWER_TOTAL"])
    rows = b.save(asset, d3, ["ACTIVE_POWER_TOTAL", "CURRENT_TOTAL"])
    for d in (d1, d2, d3):
        b.readings(d, "ACTIVE_POWER_TOTAL", [b.at - timedelta(days=5)])
    b.readings(d3, "CURRENT_TOTAL", [b.at - timedelta(days=5)])
    t.cur.execute("UPDATE metadata.asset_points SET effective_to = %s WHERE id = %s", (b.at + timedelta(hours=2), rows["ACTIVE_POWER_TOTAL"]))
    t.cur.execute("UPDATE metadata.asset_points SET effective_from = %s WHERE id = %s", (b.at + timedelta(minutes=1), rows["CURRENT_TOTAL"]))

    plan = {(r["asset_name"], r["point_name"]): r["action"] for r in b.run(excluded=[excluded_asset])}
    assert plan == {
        ("HeatVentUnit-01", "ACTIVE_POWER_TOTAL"): "EXCLUDED_ASSET",
        ("Retired", "ACTIVE_POWER_TOTAL"): "EXCLUDED_ASSET_NOT_ACTIVE",
        ("Pump", "ACTIVE_POWER_TOTAL"): "SKIPPED_CLOSED",
        ("Pump", "CURRENT_TOTAL"): "SKIPPED_START_CHANGED",
    }
    assert _start(t.cur, e["ACTIVE_POWER_TOTAL"]) == b.at and _start(t.cur, i["ACTIVE_POWER_TOTAL"]) == b.at


def test_a_meter_related_to_another_asset_is_excluded(t):
    b = Bulk(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    b.readings(device, "ACTIVE_POWER_TOTAL", [b.at - timedelta(days=5)])
    t.cur.execute(
        "INSERT INTO metadata.asset_devices (asset_id, device_id, relationship_type) VALUES (%s, %s, 'SECONDARY_METER')",
        (t.asset("Neighbour"), device),
    )
    assert [r["action"] for r in b.run()] == ["EXCLUDED_SHARED_METER"]


def test_only_rows_added_by_the_bulk_audits_and_only_the_requested_gateway(t):
    b = Bulk(t)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    b.save(asset, device, ["ACTIVE_POWER_TOTAL"])
    unaudited = b.bind(asset, device, "CURRENT_TOTAL")   # same start, not in any audit
    b.readings(device, "ACTIVE_POWER_TOTAL", [b.at - timedelta(days=5)])
    b.readings(device, "CURRENT_TOTAL", [b.at - timedelta(days=5)])

    t.cur.execute(
        "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
        (t.org, t.site, f"Other GW {t.tag}", f"OTHER_GW_{t.tag}"),
    )
    other_gateway = str(t.cur.fetchone()[0])
    t.cur.execute(
        "INSERT INTO metadata.devices (organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
        "VALUES (%s, %s, %s, %s, 'Far meter', %s) RETURNING id",
        (t.org, other_gateway, t.model_id, t.profile_id, f"FAR_{t.tag}"),
    )
    far_device = str(t.cur.fetchone()[0])
    far_asset = t.asset("Far pump")
    b.save(far_asset, far_device, ["ACTIVE_POWER_TOTAL"])
    b.readings(far_device, "ACTIVE_POWER_TOTAL", [b.at - timedelta(days=5)])

    here = b.run(dry_run=False, confirm=1)
    assert [(r["asset_name"], r["point_name"]) for r in here] == [("Pump", "ACTIVE_POWER_TOTAL")]
    assert _start(t.cur, unaudited) == b.at
    there = b.run(gateway=other_gateway)
    assert [(r["asset_name"], r["action"]) for r in there] == [("Far pump", "RESTORE")]
