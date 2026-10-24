"""Migration 310: one-time recovery of sensor history from preserved raw packets.

Every test seeds its own site (Asia/Kolkata, 60 s capture, 60 s late-arrival
tolerance), AirSense devices and preserved gateway packets inside a
transaction that is rolled back, and drives telemetry.backfill_preserved_rtdata
and its two read-only plan functions.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO

UTC = timezone.utc
CORE_SIG = "telemetry.backfill_preserved_rtdata(text, timestamptz, timestamptz, uuid[], boolean, integer)"
SAMPLES_SIG = "telemetry.preserved_rtdata_samples(timestamptz, timestamptz, uuid[])"
POINTS_SIG = "telemetry.preserved_rtdata_points(timestamptz, timestamptz, uuid[])"

# Two days back, on a whole minute: every bucket is past its deadline.
BASE = (datetime.now(UTC) - timedelta(days=2)).replace(second=0, microsecond=0)
FROM = BASE - timedelta(hours=1)
TO = BASE + timedelta(hours=2)


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


def _one(cur, sql, args=()):
    cur.execute(sql, args)
    return cur.fetchone()


class Site:
    """A site with AirSense sensors, an energy meter and a 60 s / 60 s policy."""

    def __init__(self, cur):
        self.cur = cur
        self.tag = uuid.uuid4().hex[:8].upper()
        self.org = _one(cur, "INSERT INTO metadata.organizations (name, code) VALUES (%s, %s) RETURNING id",
                        (f"P310 Org {self.tag}", f"P310_ORG_{self.tag}"))[0]
        self.site = _one(cur, "INSERT INTO metadata.sites (organization_id, name, code, timezone) VALUES (%s, %s, %s, 'Asia/Kolkata') RETURNING id",
                         (self.org, f"P310 Site {self.tag}", f"P310_SITE_{self.tag}"))[0]
        cur.execute(
            "INSERT INTO config.telemetry_capture_policies (site_id, capture_interval_seconds, alignment_mode, "
            "late_arrival_tolerance_seconds, effective_from, is_enabled) VALUES (%s, 60, 'WALL_CLOCK', 60, now() - INTERVAL '90 days', TRUE)",
            (self.site,),
        )
        self.gateway = _one(cur, "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
                            (self.org, self.site, f"P310 GW {self.tag}", f"P310_GW_{self.tag}"))[0]
        self.airsense = self._profile("ENVIRONMENT_SENSOR_AIRSENSE_V1")
        self.meter_profile = self._profile("ENERGY_METER_ENISCOPE_V1")

    def _profile(self, code):
        row = _one(self.cur, "SELECT id FROM config.device_profiles WHERE profile_code = %s", (code,))
        if row is None:
            pytest.skip(f"{code} profile is not seeded")
        return row[0]

    def device(self, name, *, profile=None, active=True):
        uid = f"P310:{self.tag}:{name}"
        dev = _one(self.cur, "INSERT INTO metadata.devices (organization_id, gateway_id, name, external_id, profile_id) "
                             "VALUES (%s, %s, %s, %s, %s) RETURNING id",
                   (self.org, self.gateway, f"{name} {self.tag}", f"P310_{name}_{self.tag}", profile or self.airsense))[0]
        if active:
            self.cur.execute("SELECT set_config('ems.controlled_device_commissioning_id', %s, true)", (str(dev),))
            self.cur.execute("UPDATE metadata.devices SET lifecycle_status = 'ACTIVE' WHERE id = %s", (dev,))
        self.cur.execute("INSERT INTO metadata.device_identifiers (device_id, identifier_type, identifier_value) VALUES (%s, 'MQTT_UID', %s)",
                         (dev, uid))
        # Every profile point enabled for the device (the platform's default).
        self.cur.execute(
            "INSERT INTO config.device_point_configuration (device_id, logical_point_id, is_enabled) "
            "SELECT %s, pfm.logical_point_id, TRUE FROM config.profile_field_mapping pfm WHERE pfm.profile_id = %s "
            "ON CONFLICT (device_id, logical_point_id) DO UPDATE SET is_enabled = TRUE",
            (dev, profile or self.airsense),
        )
        return str(dev), uid

    def enabled_points(self, device):
        return _one(self.cur, "SELECT count(*) FROM config.device_point_configuration WHERE device_id = %s AND is_enabled", (device,))[0]

    def packet(self, received_at, elements, *, message_id=None):
        message_id = message_id or (uuid.uuid4().int % 10**12)
        self.cur.execute(
            "INSERT INTO telemetry.preserved_rtdata_packets (raw_received_at, raw_message_id, source_identifier, payload, source_file) "
            "VALUES (%s, %s, %s, %s, 'test.csv.gz')",
            (received_at, message_id, elements[0]["uid"], json.dumps({"rtdata": elements})),
        )
        return received_at, message_id

    def failure(self, received_at, message_id, *, status="PERMANENT_FAILURE"):
        self.cur.execute(
            "INSERT INTO telemetry.raw_message_failures (raw_received_at, raw_message_id, detected_at, failure_code, source_protocol, payload, resolution_status) "
            "VALUES (%s, %s, now(), 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', '{}'::jsonb, %s)",
            (received_at, message_id, status),
        )


def airsense(uid, at, *, t1=25.6, rh=57.6, ll=20, pir=34737, drop=()):
    element = {"uid": uid, "did": "01", "ts": at.timestamp(), "T1": t1, "RH": rh, "LL": ll, "PIR": pir,
               "Vbat": 3.532, "Stat": 86, "ain1": 0, "ain2": 0.001, "ain3": 0, "ain4": 0}
    for key in drop:
        element.pop(key)
    return element


def meter(uid, at):
    return {"uid": uid, "did": "3", "ts": at.timestamp(), "P": 1000, "E": 123456}


def run(cur, devices, *, dry_run=True, confirm=None, frm=FROM, to=TO, actor="operator@test"):
    cur.execute(f"SELECT * FROM telemetry.backfill_preserved_rtdata(%s, %s, %s, %s::uuid[], %s, %s)",
                (actor, frm, to, list(devices), dry_run, confirm))
    names = [c.name for c in cur.description]
    return {r[names.index("device_id")].__str__(): dict(zip(names, r)) for r in cur.fetchall()}


def samples(cur, devices):
    cur.execute(f"SELECT device_id::text, event_time, sample_action FROM telemetry.preserved_rtdata_samples(%s, %s, %s::uuid[])",
                (FROM, TO, list(devices)))
    return cur.fetchall()


def points(cur, device):
    cur.execute(
        "SELECT logical_point, raw_value, numeric_value, quality_code, event_time, platform_received_at, raw_message_id "
        "FROM telemetry.normalized_points WHERE device_id = %s AND event_time >= %s AND event_time < %s ORDER BY event_time, logical_point",
        (device, FROM, TO),
    )
    return cur.fetchall()


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sig", [CORE_SIG, SAMPLES_SIG, POINTS_SIG])
def test_functions_are_ems_admin_owned_and_not_granted(tx, sig):
    cur = tx.cursor()
    owner = _one(cur, "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = %s::regprocedure", (sig,))[0]
    assert owner == "ems_admin"
    for role in ("public", "ems_app"):
        assert _one(cur, "SELECT has_function_privilege(%s, %s, 'EXECUTE')", (role, sig))[0] is False


def test_the_backfill_never_touches_pipeline_checkpoints(tx):
    """Its last_received_at write is device_point_state's (per point), never a
    telemetry.pipeline_state checkpoint (assert_analytical_reconciliation D)."""
    cur = tx.cursor()
    for sig in (CORE_SIG, SAMPLES_SIG, POINTS_SIG):
        definition = _one(cur, "SELECT pg_get_functiondef(%s::regprocedure)", (sig,))[0]
        assert "pipeline_state" not in definition


def test_preserved_packet_table_is_not_readable_by_the_app(tx):
    cur = tx.cursor()
    assert _one(cur, "SELECT has_table_privilege('ems_app', 'telemetry.preserved_rtdata_packets', 'SELECT')")[0] is False
    assert _one(cur, "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'telemetry.preserved_rtdata_packets'::regclass")[0] == "ems_admin"


@pytest.mark.parametrize(
    "kwargs, message",
    [
        ({"actor": " "}, "An actor is required"),
        ({"frm": FROM, "to": FROM}, "must be set, non-empty and at most 31 days"),
        ({"frm": FROM - timedelta(days=40)}, "must be set, non-empty and at most 31 days"),
        ({"dry_run": False}, "requires p_confirm_points"),
    ],
)
def test_invalid_calls_are_refused(tx, kwargs, message):
    cur = tx.cursor()
    site = Site(cur)
    dev, _ = site.device("Zone1")
    with pytest.raises(psycopg.errors.InvalidParameterValue, match=message):
        run(cur, [dev], **kwargs)


def test_an_inactive_or_unknown_device_is_refused(tx):
    cur = tx.cursor()
    site = Site(cur)
    dev, _ = site.device("Zone1")
    staged, _ = site.device("Staged", active=False)
    for devices in ([dev, staged], [dev, str(uuid.uuid4())], []):
        with pytest.raises(psycopg.errors.InvalidParameterValue):
            with tx.transaction():
                run(cur, devices)


# ---------------------------------------------------------------------------
# Dry run and execution
# ---------------------------------------------------------------------------


def test_dry_run_reports_the_plan_and_writes_nothing(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    z2, u2 = site.device("Zone2")
    _, mu = site.device("Meter", profile=site.meter_profile)
    for i in range(3):
        at = BASE + timedelta(minutes=5 * i)
        site.packet(at + timedelta(seconds=36), [airsense(u2, at + timedelta(seconds=3)), airsense(u1, at + timedelta(seconds=4)), meter(mu, at)])
    before = _one(cur, "SELECT count(*) FROM admin.onboarding_audit")[0]

    plan = run(cur, [z1, z2])

    for dev in (z1, z2):
        assert plan[dev]["elements"] == 3 and plan[dev]["selected"] == 3
        assert plan[dev]["points_to_insert"] == 3 * site.enabled_points(dev)
        assert plan[dev]["points_inserted"] == 0 and plan[dev]["audit_id"] is None
        assert points(cur, dev) == []
    assert _one(cur, "SELECT count(*) FROM telemetry.capture_bucket_samples WHERE site_id = %s", (site.site,))[0] == 0
    assert _one(cur, "SELECT count(*) FROM admin.onboarding_audit")[0] == before


def test_a_confirmation_mismatch_changes_nothing(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    site.packet(BASE + timedelta(seconds=40), [airsense(u1, BASE + timedelta(seconds=4))])
    planned = run(cur, [z1])[z1]["points_to_insert"]
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="Confirmation mismatch"):
        with tx.transaction():
            run(cur, [z1], dry_run=False, confirm=planned + 1)
    assert points(cur, z1) == []


def test_execution_inserts_the_payload_values_exactly_like_the_live_loader(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    at = BASE + timedelta(seconds=4.63778)
    received, msg = site.packet(BASE + timedelta(seconds=36), [airsense(u1, at, t1=25.2, rh=57, ll=15, pir=40344)])
    planned = run(cur, [z1])[z1]["points_to_insert"]

    result = run(cur, [z1], dry_run=False, confirm=planned)[z1]

    assert result["points_inserted"] == planned == site.enabled_points(z1)
    rows = {r[0]: r for r in points(cur, z1)}
    assert rows["ENV_TEMPERATURE"][1:4] == ("25.2", Decimal("25.2"), "GOOD")
    assert rows["ENV_RELATIVE_HUMIDITY"][1] == "57" and rows["ENV_ILLUMINANCE_LUX"][1] == "15"
    assert rows["OCCUPANCY_ACTIVITY"][2] == 40344
    for r in rows.values():
        assert r[4] == at                       # event_time = the element's own ts
        assert r[5] == received and r[6] == msg  # provenance: the original packet
    cbs = _one(cur, "SELECT status, event_time, raw_message_id FROM telemetry.capture_bucket_samples WHERE device_id = %s", (z1,))
    assert cbs == ("RECOVERED", at, msg)
    queued = _one(cur, "SELECT count(*), min(event_time) FROM telemetry.routing_recovery_queue WHERE device_id = %s", (z1,))
    assert queued == (1, at)
    state = _one(cur, "SELECT first_seen_at, first_valid_seen_at FROM telemetry.device_point_state dps "
                      "JOIN metadata.logical_points lp ON lp.id = dps.logical_point_id WHERE dps.device_id = %s AND lp.name = 'ENV_TEMPERATURE'", (z1,))
    assert state == (at, at)
    audit = _one(cur, "SELECT request_payload->>'operation', (result_payload->>'points_inserted')::int FROM admin.onboarding_audit WHERE id = %s",
                 (result["audit_id"],))
    assert audit == ("BACKFILL_PRESERVED_RTDATA", planned)


def test_a_missing_field_is_stored_as_missing_not_invented(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    site.packet(BASE + timedelta(seconds=36), [airsense(u1, BASE + timedelta(seconds=4), drop=("LL",))])
    planned = run(cur, [z1])[z1]["points_to_insert"]
    run(cur, [z1], dry_run=False, confirm=planned)
    lux = [r for r in points(cur, z1) if r[0] == "ENV_ILLUMINANCE_LUX"]
    assert lux and lux[0][1:4] == (None, None, "MISSING")


def test_repeat_run_is_a_no_op(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    for i in range(4):
        at = BASE + timedelta(minutes=5 * i)
        site.packet(at + timedelta(seconds=36), [airsense(u1, at + timedelta(seconds=4))])
    planned = run(cur, [z1])[z1]["points_to_insert"]
    run(cur, [z1], dry_run=False, confirm=planned)
    first = points(cur, z1)

    again = run(cur, [z1])[z1]
    assert again["bucket_taken"] == 4 and again["selected"] == 0 and again["points_to_insert"] == 0
    run(cur, [z1], dry_run=False, confirm=0)
    assert points(cur, z1) == first


# ---------------------------------------------------------------------------
# Live-loader rules: late arrivals, one sample per bucket, existing buckets
# ---------------------------------------------------------------------------


def test_a_late_element_stays_a_gap(tx):
    cur = tx.cursor()
    site = Site(cur)
    lobby, ul = site.device("Lobby")
    late_at = BASE - timedelta(minutes=30)  # received 30 min after its bucket: past the 120 s deadline
    on_time = BASE + timedelta(seconds=4)
    site.packet(BASE + timedelta(seconds=36), [airsense(ul, on_time)])
    site.packet(BASE + timedelta(minutes=5, seconds=36), [airsense(ul, late_at)])

    plan = run(cur, [lobby])[lobby]
    assert (plan["selected"], plan["late"]) == (1, 1)
    run(cur, [lobby], dry_run=False, confirm=plan["points_to_insert"])
    assert {r[4] for r in points(cur, lobby)} == {on_time}


def test_only_the_latest_element_of_a_bucket_is_the_sample(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    early, later = BASE + timedelta(seconds=4), BASE + timedelta(seconds=40)
    site.packet(BASE + timedelta(seconds=10), [airsense(u1, early, t1=20.0)])
    site.packet(BASE + timedelta(seconds=50), [airsense(u1, later, t1=21.0)])

    actions = sorted(a for _, _, a in samples(cur, [z1]))
    assert actions == ["SELECTED", "SUPERSEDED"]
    plan = run(cur, [z1])[z1]
    run(cur, [z1], dry_run=False, confirm=plan["points_to_insert"])
    temps = [(r[4], r[2]) for r in points(cur, z1) if r[0] == "ENV_TEMPERATURE"]
    assert temps == [(later, 21.0)]


def test_a_bucket_the_live_loader_already_sampled_is_never_touched(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    at = BASE + timedelta(seconds=4)
    received, msg = site.packet(BASE + timedelta(seconds=36), [airsense(u1, at, t1=30.0)])
    # The live loader's sample and point for the same bucket (another packet, another value).
    bucket = _one(cur, "SELECT bucket_start, policy_id FROM telemetry.resolve_site_capture_bucket(%s, %s)", (site.site, at))
    cur.execute(
        "INSERT INTO telemetry.capture_bucket_samples (site_id, device_id, policy_id, bucket_start, capture_interval_seconds, "
        "late_arrival_tolerance_seconds, source_timestamp, event_time, raw_received_at, raw_message_id, status) "
        "VALUES (%s, %s, %s, %s, 60, 60, %s, %s, %s, 1, 'NORMALIZED')",
        (site.site, z1, bucket[1], bucket[0], at, at, received),
    )
    temp = _one(cur, "SELECT id FROM metadata.logical_points WHERE name = 'ENV_TEMPERATURE'")[0]
    cur.execute(
        "INSERT INTO telemetry.normalized_points (event_time, organization_id, site_id, gateway_id, device_id, logical_point_id, "
        "device_uid, logical_point, raw_field_name, raw_value, numeric_value, quality_code, mapping_source, platform_received_at, raw_message_id) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s, 'ENV_TEMPERATURE', 'T1', '24.0', 24.0, 'GOOD', 'DEVICE_PROFILE', %s, 1)",
        (at, site.org, site.site, site.gateway, z1, temp, u1, received),
    )

    plan = run(cur, [z1])[z1]
    assert (plan["bucket_taken"], plan["points_to_insert"]) == (1, 0)
    run(cur, [z1], dry_run=False, confirm=0)
    assert [(r[0], r[2]) for r in points(cur, z1)] == [("ENV_TEMPERATURE", 24.0)]


def test_only_allow_listed_devices_are_processed(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    z2, u2 = site.device("Zone2")
    meter_dev, mu = site.device("Meter", profile=site.meter_profile)
    site.packet(BASE + timedelta(seconds=36),
                [airsense(u1, BASE), airsense(u2, BASE), meter(mu, BASE), airsense("UNKNOWN:UID", BASE)])

    assert {d for d, _, _ in samples(cur, [z1])} == {z1}
    plan = run(cur, [z1])
    assert set(plan) == {z1}
    run(cur, [z1], dry_run=False, confirm=plan[z1]["points_to_insert"])
    assert points(cur, z2) == [] and points(cur, meter_dev) == []


# ---------------------------------------------------------------------------
# Failure-row resolution
# ---------------------------------------------------------------------------


def test_fully_represented_packets_become_recovered_and_others_are_left(tx):
    cur = tx.cursor()
    site = Site(cur)
    z1, u1 = site.device("Zone1")
    lobby, ul = site.device("Lobby")
    good = site.packet(BASE + timedelta(seconds=36), [airsense(u1, BASE + timedelta(seconds=4)), airsense(ul, BASE + timedelta(seconds=5))])
    # Lobby's element in this packet is late and its bucket stays empty.
    partial = site.packet(BASE + timedelta(minutes=5, seconds=36),
                          [airsense(u1, BASE + timedelta(minutes=5, seconds=4)), airsense(ul, BASE - timedelta(minutes=40))])
    for received, msg in (good, partial):
        site.failure(received, msg)

    plan = run(cur, [z1, lobby])
    confirm = sum(r["points_to_insert"] for r in plan.values())
    result = run(cur, [z1, lobby], dry_run=False, confirm=confirm)

    assert next(iter(result.values()))["failures_recovered"] == 1
    status = dict(((r, m), (s, meth)) for r, m, s, meth in _rows(cur, "SELECT raw_received_at, raw_message_id, resolution_status, resolution_method "
                                                                       "FROM telemetry.raw_message_failures WHERE raw_message_id IN (%s, %s)", (good[1], partial[1])))
    assert status[good] == ("RECOVERED", "PRESERVED_PAYLOAD_BACKFILL")
    assert status[partial] == ("PERMANENT_FAILURE", None)


def _rows(cur, sql, args):
    cur.execute(sql, args)
    return cur.fetchall()
