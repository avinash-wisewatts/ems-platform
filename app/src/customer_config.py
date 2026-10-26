"""Customer API configuration (ADR-023).

CoreSettings plus the customer-only switches. Deliberately has no Grafana,
MQTT or administration fields: the customer API container is configured by
its own env file (app/customer-api.env) and never receives the
administration secrets.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator

from src.config import CoreSettings

# The Administration App's cookie name. The customer API refuses to reuse it,
# so a customer-host session can never be mistaken for, or replayed as, an
# administration session (each host also uses its own signing secret).
ADMIN_SESSION_COOKIE_NAME = "ems_admin_session"


class CustomerSettings(CoreSettings):
    """Configuration of the customer API process (src.customer_main)."""

    session_cookie_name: str = Field(
        default="ems_session",
        alias="EMS_APP_SESSION_COOKIE_NAME",
    )

    # Whether WiseWatts staff (GLOBAL-scope identities) may sign in to the
    # customer application, e.g. for support. Off by default: the customer
    # host then accepts only organization- and selected-sites-scoped
    # identities. Data access is re-derived in the database either way.
    customer_allow_staff: bool = Field(
        default=False,
        alias="EMS_CUSTOMER_ALLOW_STAFF",
    )

    # The Reports export worker stays in the admin portal until the customer
    # API takes over Reports traffic (ADR-023 stage 3); two workers would be
    # safe (jobs are claimed FOR UPDATE SKIP LOCKED) but are not wanted.
    report_export_worker_enabled: bool = Field(
        default=False,
        alias="EMS_REPORT_EXPORT_WORKER_ENABLED",
    )

    @field_validator("session_cookie_name")
    @classmethod
    def _distinct_cookie_name(cls, value: str) -> str:
        if value == ADMIN_SESSION_COOKIE_NAME:
            raise ValueError(
                "The customer API must not use the Administration App session cookie name."
            )
        return value


@lru_cache
def get_customer_settings() -> CustomerSettings:
    return CustomerSettings()
