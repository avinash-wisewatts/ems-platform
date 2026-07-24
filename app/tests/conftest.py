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


@pytest.fixture
def authenticated_operator() -> AuthenticatedPortalUser:
    """Return a safe authenticated operator identity."""

    return AuthenticatedPortalUser(
        portal_user_id=10,
        username="operator@example.com",
        display_name="Test Operator",
        role_code="OPERATOR",
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
