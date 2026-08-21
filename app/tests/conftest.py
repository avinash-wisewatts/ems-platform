import os

# Test-only configuration must exist before src.main is imported.
# No live database connection is opened by the unit/route tests.
os.environ.setdefault("EMS_APP_DB_HOST", "127.0.0.1")
os.environ.setdefault("EMS_APP_DB_PORT", "55432")
os.environ.setdefault("EMS_APP_DB_NAME", "ems_test")
os.environ.setdefault("EMS_APP_DB_USER", "ems_admin")
os.environ.setdefault("EMS_APP_DB_PASSWORD", "ems_test_only_password")
os.environ.setdefault(
    "EMS_APP_SESSION_SECRET",
    "ems-route-test-secret-at-least-32-characters-long",
)
os.environ.setdefault("EMS_APP_SESSION_HTTPS_ONLY", "false")
os.environ.setdefault("EMS_APP_ENV", "test")
os.environ.setdefault(
    "EMS_GRAFANA_ADMIN_USER",
    "grafana-test-admin",
)
os.environ.setdefault(
    "EMS_GRAFANA_ADMIN_PASSWORD",
    "grafana-test-password",
)
os.environ.setdefault(
    "EMS_GRAFANA_DB_PASSWORD",
    "grafana-test-reader-password",
)

from datetime import datetime, timezone

import pytest

from src.auth.models import (
    AuthenticatedPortalUser,
    PortalUserAuthenticationRecord,
)

# Deterministic identity chain shared by the analytics Grafana routing
# contract tests (test_analytics_explorer_intervals_routing.py,
# test_analytics_grafana_electrical_routing.py). These IDs are the exact
# constants those files hardcode; see seed_grafana_tenant_fixture below.
GRAFANA_TENANT_ORGANIZATION_ID = "00000000-0000-0000-0000-0000000000a1"
GRAFANA_TENANT_SITE_ID = "00000000-0000-0000-0000-0000000001a1"
GRAFANA_TENANT_GATEWAY_ID = "00000000-0000-0000-0000-0000000004a1"
GRAFANA_TENANT_DEVICE_MODEL_ID = "00000000-0000-0000-0000-0000000005a1"
GRAFANA_TENANT_DEVICE_ID = "00000000-0000-0000-0000-0000000002a1"
GRAFANA_TENANT_ASSET_ID = "00000000-0000-0000-0000-0000000003a1"
GRAFANA_TENANT_GRAFANA_ORG_ID = 9001

_GRAFANA_TENANT_CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)


@pytest.fixture(scope="session")
def seed_grafana_tenant_fixture():
    """Create the deterministic organization -> site -> gateway -> Energy
    Meter device model -> device -> asset -> PRIMARY_METER asset_device ->
    grafana_organization_map identity chain that the analytics Grafana
    routing contract tests resolve their tenant/asset context through.

    Every INSERT satisfies the real metadata schema constraints and
    ownership/relationship triggers (tenant-site ownership, physical
    location, PRIMARY_METER/Energy-Meter category compatibility) rather
    than bypassing them, and uses ON CONFLICT DO NOTHING against the fixed
    IDs so it is safe to depend on from multiple test modules within the
    same disposable ems_test database.
    """

    import psycopg

    with psycopg.connect(_GRAFANA_TENANT_CONNINFO, autocommit=True) as connection:
        with connection.cursor() as cur:
            cur.execute(
                """
                INSERT INTO metadata.organizations (id, name, code)
                VALUES (%s, 'Grafana Routing Test Org', 'GRAFANA_ROUTING_TEST_ORG')
                ON CONFLICT (id) DO NOTHING
                """,
                (GRAFANA_TENANT_ORGANIZATION_ID,),
            )

            cur.execute(
                """
                INSERT INTO metadata.sites (id, organization_id, name, code)
                VALUES (%s, %s, 'Grafana Routing Test Site', 'GRAFANA_ROUTING_TEST_SITE')
                ON CONFLICT (id) DO NOTHING
                """,
                (GRAFANA_TENANT_SITE_ID, GRAFANA_TENANT_ORGANIZATION_ID),
            )

            cur.execute(
                """
                INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id)
                VALUES (%s, %s, %s, 'Grafana Routing Test Gateway', 'GRAFANA_ROUTING_TEST_GW')
                ON CONFLICT (id) DO NOTHING
                """,
                (
                    GRAFANA_TENANT_GATEWAY_ID,
                    GRAFANA_TENANT_ORGANIZATION_ID,
                    GRAFANA_TENANT_SITE_ID,
                ),
            )

            cur.execute(
                """
                INSERT INTO metadata.device_models (id, vendor, model, device_category_id)
                SELECT %s, 'WiseWatts Test Fixtures', 'Deterministic Energy Meter', dc.id
                FROM config.device_categories AS dc
                WHERE lower(dc.name) = 'energy meter'
                ON CONFLICT (id) DO NOTHING
                """,
                (GRAFANA_TENANT_DEVICE_MODEL_ID,),
            )

            cur.execute(
                """
                INSERT INTO metadata.devices (
                    id, organization_id, gateway_id, device_model_id, name, external_id
                )
                VALUES (%s, %s, %s, %s, 'Grafana Routing Test Device', 'GRAFANA_ROUTING_TEST_DEV')
                ON CONFLICT (id) DO NOTHING
                """,
                (
                    GRAFANA_TENANT_DEVICE_ID,
                    GRAFANA_TENANT_ORGANIZATION_ID,
                    GRAFANA_TENANT_GATEWAY_ID,
                    GRAFANA_TENANT_DEVICE_MODEL_ID,
                ),
            )

            cur.execute(
                """
                INSERT INTO metadata.assets (
                    id, organization_id, site_id, name, external_id, metering_requirement
                )
                VALUES (%s, %s, %s, 'Grafana Routing Test Asset', 'GRAFANA_ROUTING_TEST_ASSET', 'DIRECT_METER_REQUIRED')
                ON CONFLICT (id) DO NOTHING
                """,
                (
                    GRAFANA_TENANT_ASSET_ID,
                    GRAFANA_TENANT_ORGANIZATION_ID,
                    GRAFANA_TENANT_SITE_ID,
                ),
            )

            cur.execute(
                """
                INSERT INTO metadata.asset_devices (asset_id, device_id, relationship_type)
                VALUES (%s, %s, 'PRIMARY_METER')
                ON CONFLICT (asset_id, device_id, relationship_type) DO NOTHING
                """,
                (GRAFANA_TENANT_ASSET_ID, GRAFANA_TENANT_DEVICE_ID),
            )

            cur.execute(
                """
                INSERT INTO metadata.grafana_organization_map (
                    grafana_org_id, organization_id, is_active
                )
                VALUES (%s, %s, true)
                ON CONFLICT (grafana_org_id) DO NOTHING
                """,
                (GRAFANA_TENANT_GRAFANA_ORG_ID, GRAFANA_TENANT_ORGANIZATION_ID),
            )

            # analytics.get_canonical_energy_read (exercised transitively by
            # test_analytics_grafana_routing.py via get_grafana_asset_energy_intervals,
            # which shares this fixture's GRAFANA_ORG_ID/ASSET_ID) resolves every
            # query through telemetry.resolve_site_capture_bucket, which requires a
            # config.telemetry_capture_policies row covering the queried timestamp.
            # A freshly-deployed database's only policy is the platform-default
            # (site_id IS NULL) row, whose effective_from is deploy time, so any
            # range reaching further back than "when the DB was deployed" fails to
            # resolve. A site-scoped policy with an effective_from far in the past
            # is part of this identity chain's real prerequisites, not a bypass:
            # the no-overlap trigger only compares policies sharing the same
            # site_id, so this cannot conflict with the platform default.
            cur.execute(
                """
                INSERT INTO config.telemetry_capture_policies (
                    site_id, capture_interval_seconds, effective_from
                )
                SELECT %s, 900, TIMESTAMPTZ '2000-01-01 00:00:00+00'
                WHERE NOT EXISTS (
                    SELECT 1 FROM config.telemetry_capture_policies
                    WHERE site_id = %s
                )
                """,
                (GRAFANA_TENANT_SITE_ID, GRAFANA_TENANT_SITE_ID),
            )


@pytest.fixture
def authenticated_operator() -> AuthenticatedPortalUser:
    """Return a safe authenticated operator identity."""

    return AuthenticatedPortalUser(
        portal_user_id=10,
        username="operator@example.com",
        display_name="Test Operator",
        role_code="OPERATOR",
        organization_id=(
            "11111111-1111-1111-1111-111111111111"
        ),
        access_scope_mode="ORGANIZATION",
        site_ids=(),
    )


@pytest.fixture
def active_authentication_record() -> PortalUserAuthenticationRecord:
    """Return an active, unlocked authentication record."""

    return PortalUserAuthenticationRecord(
        portal_user_id=10,
        username="operator@example.com",
        display_name="Test Operator",
        password_hash="$argon2id$test-placeholder",
        role_code="OPERATOR",
        is_active=True,
        failed_login_count=0,
        locked_until=None,
        organization_id=(
            "11111111-1111-1111-1111-111111111111"
        ),
        access_scope_mode="ORGANIZATION",
        site_ids=(),
    )


@pytest.fixture
def fixed_utc_time() -> datetime:
    """Return a deterministic timezone-aware instant."""

    return datetime(
        2026,
        7,
        21,
        12,
        0,
        0,
        tzinfo=timezone.utc,
    )


@pytest.fixture
def portal_app():
    """
    Return the FastAPI application without entering its lifespan.

    TestClient is deliberately not used as a context manager here. Therefore,
    the production database pool startup hook is not executed.
    """

    from src.main import app

    return app


@pytest.fixture
def portal_client(portal_app):
    """Return a no-redirect HTTP client with cookie persistence."""

    from fastapi.testclient import TestClient

    return TestClient(
        portal_app,
        follow_redirects=False,
    )
