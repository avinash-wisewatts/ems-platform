"""MVP-4 (Data Quality & Freshness) -- DB-backed contract for
analytics.get_portal_site_telemetry_freshness (migration 237).

Mirrors test_analytics_api_v1_contract.py's pattern: exercises the real
SQL function against the disposable ems_test database, since the
internal-state collapse (VALIDATED/STALE/RECEIVING/SILENT/NEVER_SEEN ->
FRESH/STALE/NO_DATA), the metric-specific device resolution (decision
pack Sec 5a), and tenant isolation all need a real Postgres engine --
every other MVP-4 test monkeypatches this function rather than calling it.

p_at is always passed explicitly (never defaulted to clock_timestamp())
so every assertion is deterministic relative to a fixed instant, the same
discipline test_analytics_api_v1_contract.py uses via its fixed T0.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import psycopg
import pytest


CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

ORG_A = "00000000-0000-0000-0000-000000f100c9"
ORG_B = "00000000-0000-0000-0000-000000f200c9"

SITE_FRESH = "00000000-0000-0000-0000-000000f300c9"       # device fresh; Demand resolves the same device
SITE_STALE = "00000000-0000-0000-0000-000000f400c9"       # device stale; no Demand policy at all
SITE_NEVER_SEEN = "00000000-0000-0000-0000-000000f500c9"  # device configured, never reported
SITE_NO_METER = "00000000-0000-0000-0000-000000f600c9"    # no SITE_CONSUMPTION meter, no Demand policy

DEVICE_FRESH = "00000000-0000-0000-0000-0000000ac9c9"
DEVICE_STALE = "00000000-0000-0000-0000-0000000bc9c9"
DEVICE_NEVER_SEEN = "00000000-0000-0000-0000-0000000cc9c9"

# metadata.devices requires a gateway in the same organization
# (trg_validate_device_physical_location) -- one gateway per site used.
GATEWAY_FRESH = "00000000-0000-0000-0000-0000000dc9c9"
GATEWAY_STALE = "00000000-0000-0000-0000-0000000ec9c9"
GATEWAY_NEVER_SEEN = "00000000-0000-0000-0000-0000000fc9c9"

# The "now" every test evaluates freshness relative to. Fixed, not
# clock_timestamp(), so results never depend on wall-clock timing.
T0 = datetime(2026, 9, 13, 12, 0, 0, tzinfo=timezone.utc)


@pytest.fixture(scope="module", autouse=True)
def seed() -> None:
    """Deterministic fixture: two orgs, four sites covering FRESH / STALE /
    NO_DATA (device configured, never reported) / UNKNOWN (no device
    resolvable), plus one cross-org portal user for tenant isolation.
    Idempotent (ON CONFLICT DO NOTHING), committed as one transaction.
    """

    with psycopg.connect(CONNINFO) as conn:  # autocommit=False
        with conn.cursor() as cur:
            for org, name in ((ORG_A, "P237 Org A"), (ORG_B, "P237 Org B")):
                cur.execute(
                    "INSERT INTO metadata.organizations (id, name, code) "
                    "VALUES (%s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (org, name, "P237_" + name.replace(" ", "_").upper()),
                )

            for site, org, code in (
                (SITE_FRESH, ORG_A, "P237_SITE_FRESH"),
                (SITE_STALE, ORG_A, "P237_SITE_STALE"),
                (SITE_NEVER_SEEN, ORG_A, "P237_SITE_NEVER_SEEN"),
                (SITE_NO_METER, ORG_A, "P237_SITE_NO_METER"),
            ):
                cur.execute(
                    "INSERT INTO metadata.sites (id, organization_id, name, code) "
                    "VALUES (%s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (site, org, code.replace("_", " "), code),
                )

            # config.validate_site_energy_meter_role() requires the device
            # to resolve to a device_model whose category is "Energy Meter"
            # (case-insensitive) -- an existing, seeded reference category;
            # only the model row is test-owned.
            cur.execute(
                "SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter'"
            )
            energy_meter_category_id = cur.fetchone()[0]
            cur.execute(
                """
                INSERT INTO metadata.device_models (id, vendor, model, device_category_id)
                VALUES (%s, 'P237 Test Vendor', 'P237 Test Energy Meter', %s)
                ON CONFLICT (id) DO NOTHING
                """,
                ("00000000-0000-0000-0000-00000001c9c9", energy_meter_category_id),
            )
            device_model_id = "00000000-0000-0000-0000-00000001c9c9"

            for gateway, org, site, name, ext in (
                (GATEWAY_FRESH, ORG_A, SITE_FRESH, "P237 Gateway Fresh", "P237-GW-FRESH"),
                (GATEWAY_STALE, ORG_A, SITE_STALE, "P237 Gateway Stale", "P237-GW-STALE"),
                (GATEWAY_NEVER_SEEN, ORG_A, SITE_NEVER_SEEN, "P237 Gateway Never Seen", "P237-GW-NEVER-SEEN"),
            ):
                cur.execute(
                    "INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) "
                    "VALUES (%s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (gateway, org, site, name, ext),
                )

            for device, org, gateway, name, ext in (
                (DEVICE_FRESH, ORG_A, GATEWAY_FRESH, "P237 Device Fresh", "P237-DEV-FRESH"),
                (DEVICE_STALE, ORG_A, GATEWAY_STALE, "P237 Device Stale", "P237-DEV-STALE"),
                (DEVICE_NEVER_SEEN, ORG_A, GATEWAY_NEVER_SEEN, "P237 Device Never Seen", "P237-DEV-NEVER-SEEN"),
            ):
                cur.execute(
                    "INSERT INTO metadata.devices "
                    "(id, organization_id, gateway_id, device_model_id, name, external_id) "
                    "VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (device, org, gateway, device_model_id, name, ext),
                )

            # --- SITE_CONSUMPTION meter role: resolves Energy and Power
            # Quality identically (decision pack Sec 5a). SITE_NO_METER
            # deliberately gets none. Neither site_id/device_id/meter_role
            # nor (site_id, policy_scope, effective_range) below has a
            # plain-column unique constraint to give ON CONFLICT DO NOTHING
            # a target (uniqueness here is enforced procedurally, by
            # trigger, against overlapping *active* rows) -- fixed,
            # explicit ids on ON CONFLICT (id) make this idempotent the
            # same way every other insert in this fixture already is.
            for row_id, site, device in (
                ("00000000-0000-0000-0000-00000002c9c9", SITE_FRESH, DEVICE_FRESH),
                ("00000000-0000-0000-0000-00000003c9c9", SITE_STALE, DEVICE_STALE),
                ("00000000-0000-0000-0000-00000004c9c9", SITE_NEVER_SEEN, DEVICE_NEVER_SEEN),
            ):
                cur.execute(
                    "INSERT INTO config.site_energy_meter_roles "
                    "(id, site_id, device_id, meter_role) VALUES (%s, %s, %s, 'SITE_CONSUMPTION') "
                    "ON CONFLICT (id) DO NOTHING",
                    (row_id, site, device),
                )

            # --- SITE-scope Demand policy: only SITE_FRESH and
            # SITE_NEVER_SEEN get one (pointing at the same device as their
            # meter role) -- SITE_STALE and SITE_NO_METER deliberately have
            # none, to prove Demand resolves independently of Energy/PQ.
            for row_id, site in (
                ("00000000-0000-0000-0000-00000005c9c9", SITE_FRESH),
                ("00000000-0000-0000-0000-00000006c9c9", SITE_NEVER_SEEN),
            ):
                cur.execute(
                    """
                    INSERT INTO config.site_demand_policies
                        (id, site_id, demand_interval_seconds, demand_basis,
                         site_demand_source_role, effective_from)
                    VALUES (%s, %s, 900, 'ACTIVE_POWER_KW', 'SITE_CONSUMPTION', '2000-01-01T00:00:00Z')
                    ON CONFLICT (id) DO NOTHING
                    """,
                    (row_id, site),
                )

            # --- device_telemetry_state: FRESH (recent valid), STALE (last
            # valid source reading older than the stale threshold, but
            # something received recently), NEVER_SEEN gets no row at all.
            cur.execute(
                """
                INSERT INTO telemetry.device_telemetry_state
                    (device_id, latest_source_timestamp, latest_received_timestamp,
                     latest_valid_source_timestamp, latest_valid_received_timestamp)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (device_id) DO NOTHING
                """,
                (DEVICE_FRESH, T0 - timedelta(seconds=60), T0 - timedelta(seconds=60),
                 T0 - timedelta(seconds=60), T0 - timedelta(seconds=60)),
            )
            cur.execute(
                """
                INSERT INTO telemetry.device_telemetry_state
                    (device_id, latest_source_timestamp, latest_received_timestamp,
                     latest_valid_source_timestamp, latest_valid_received_timestamp)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (device_id) DO NOTHING
                """,
                (DEVICE_STALE, T0 - timedelta(seconds=1000), T0 - timedelta(seconds=100),
                 T0 - timedelta(seconds=1000), T0 - timedelta(seconds=1000)),
            )
            # DEVICE_NEVER_SEEN: no device_telemetry_state row at all.

            def upsert_user(username, role, org, scope):
                cur.execute(
                    """
                    INSERT INTO admin.portal_users
                        (username, display_name, password_hash, role_code,
                         organization_id, access_scope_mode, created_by)
                    VALUES (%s, %s, '$argon2id$placeholder', %s, %s, %s, 'p237-contract-test')
                    ON CONFLICT (username) DO NOTHING
                    """,
                    (username, username, role, org, scope),
                )
                cur.execute(
                    "SELECT portal_user_id FROM admin.portal_users WHERE username = %s",
                    (username,),
                )
                return cur.fetchone()[0]

            upsert_user("p237.global@test", "ADMIN", None, "GLOBAL")
            upsert_user("p237.orgb@test", "OPERATOR", ORG_B, "ORGANIZATION")

        conn.commit()


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        yield connection


def _uid(conn, username: str) -> int:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT portal_user_id FROM admin.portal_users WHERE username = %s",
            (username,),
        )
        return cur.fetchone()[0]


def _freshness(conn, uid: int, site: str, at: datetime = T0):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT site_id, energy_state, energy_as_of,
                   demand_state, demand_as_of,
                   power_quality_state, power_quality_as_of
            FROM analytics.get_portal_site_telemetry_freshness(%s, %s, %s)
            """,
            (uid, site, at),
        )
        return cur.fetchall()


# ---------------------------------------------------------------------------
# Per-domain, per-state semantics -- the actual SQL, not a mock.
# ---------------------------------------------------------------------------

def test_fresh_site_resolves_energy_demand_pq_all_fresh(conn) -> None:
    """Energy and Power Quality share the SITE_CONSUMPTION device; Demand's
    SITE-scope policy points at the same device here -- all three FRESH,
    with as_of matching the device's latest_received_timestamp exactly."""

    rows = _freshness(conn, _uid(conn, "p237.global@test"), SITE_FRESH)
    assert len(rows) == 1
    site_id, energy_state, energy_as_of, demand_state, demand_as_of, pq_state, pq_as_of = rows[0]
    assert str(site_id) == SITE_FRESH
    assert (energy_state, demand_state, pq_state) == ("FRESH", "FRESH", "FRESH")
    expected_as_of = T0 - timedelta(seconds=60)
    assert energy_as_of == expected_as_of
    assert demand_as_of == expected_as_of
    assert pq_as_of == expected_as_of


def test_stale_site_energy_and_pq_stale_demand_unknown(conn) -> None:
    """Proves per-domain independence (decision pack Sec 5a): the same
    device drives Energy/PQ to STALE, while Demand -- which has no
    SITE-scope policy configured on this site at all -- independently
    reports UNKNOWN. No blended site-wide verdict exists."""

    rows = _freshness(conn, _uid(conn, "p237.global@test"), SITE_STALE)
    assert len(rows) == 1
    _, energy_state, _, demand_state, demand_as_of, pq_state, _ = rows[0]
    assert (energy_state, pq_state) == ("STALE", "STALE")
    assert demand_state == "UNKNOWN"
    assert demand_as_of is None


def test_never_seen_device_is_no_data_not_unknown(conn) -> None:
    """A device that IS resolved (a SITE_CONSUMPTION role and a Demand
    policy both point at it) but has never reported any telemetry must be
    NO_DATA -- distinct from UNKNOWN, which means no device was resolved
    at all."""

    rows = _freshness(conn, _uid(conn, "p237.global@test"), SITE_NEVER_SEEN)
    assert len(rows) == 1
    _, energy_state, energy_as_of, demand_state, demand_as_of, pq_state, pq_as_of = rows[0]
    assert (energy_state, demand_state, pq_state) == ("NO_DATA", "NO_DATA", "NO_DATA")
    assert energy_as_of is None
    assert demand_as_of is None
    assert pq_as_of is None


def test_no_meter_configured_is_unknown_never_fabricated_fresh(conn) -> None:
    """No SITE_CONSUMPTION meter role and no Demand policy at all -- the
    non-negotiable 'unknown must never read as positive' constraint,
    proven against the real function, not a mock."""

    rows = _freshness(conn, _uid(conn, "p237.global@test"), SITE_NO_METER)
    assert len(rows) == 1
    _, energy_state, energy_as_of, demand_state, demand_as_of, pq_state, pq_as_of = rows[0]
    assert (energy_state, demand_state, pq_state) == ("UNKNOWN", "UNKNOWN", "UNKNOWN")
    assert energy_as_of is None
    assert demand_as_of is None
    assert pq_as_of is None


# ---------------------------------------------------------------------------
# Tenant isolation -- matches the zero-rows-on-denial convention every
# other analytics.get_portal_* function uses (e.g. get_portal_site_energy_consumption).
# ---------------------------------------------------------------------------

def test_cross_org_user_gets_zero_rows(conn) -> None:
    assert _freshness(conn, _uid(conn, "p237.orgb@test"), SITE_FRESH) == []


def test_unknown_site_gets_zero_rows(conn) -> None:
    assert _freshness(
        conn, _uid(conn, "p237.global@test"), "ffffffff-ffff-ffff-ffff-ffffffffffff"
    ) == []


# ---------------------------------------------------------------------------
# Grants / definer discipline -- consistent with
# test_boundary_functions_are_definer_stable_and_scoped's pattern.
# ---------------------------------------------------------------------------

def test_function_is_definer_stable_and_correctly_scoped(conn) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT p.prosecdef, p.provolatile, r.rolname AS owner,
                   has_function_privilege('ems_app', p.oid, 'EXECUTE') AS ems_app_exec,
                   has_function_privilege('public',  p.oid, 'EXECUTE') AS public_exec
            FROM pg_proc p
            JOIN pg_roles r ON r.oid = p.proowner
            WHERE p.pronamespace = 'analytics'::regnamespace
              AND p.proname = 'get_portal_site_telemetry_freshness'
            """
        )
        rows = cur.fetchall()
    assert len(rows) == 1
    secdef, volatile, owner, ems_app_exec, public_exec = rows[0]
    assert secdef is True
    assert volatile == "s"
    assert owner == "ems_admin"
    assert ems_app_exec is True
    assert public_exec is False


def test_function_body_never_references_demand_calculation_status_objects(conn) -> None:
    """Direct proof (not just the migration's own apply-time postcondition)
    that this function never reads analytics.demand_state,
    analytics.demand_intervals, or analytics.resolve_demand_capability --
    the architectural guard decision pack Sec 5 requires."""

    with conn.cursor() as cur:
        cur.execute(
            "SELECT lower(pg_get_functiondef("
            "'analytics.get_portal_site_telemetry_freshness(bigint,uuid,timestamptz)'::regprocedure))"
        )
        body = cur.fetchone()[0]
    for forbidden in ("demand_intervals", "resolve_demand_capability"):
        assert forbidden not in body, forbidden
    # demand_state legitimately appears as this function's own output
    # column name (see migration 237's postcondition fix) -- assert the
    # real table reference (schema-qualified, as every write/read path in
    # this codebase spells it) is absent instead of the bare word.
    assert "analytics.demand_state" not in body
