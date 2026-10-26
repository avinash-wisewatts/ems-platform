from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class CoreSettings(BaseSettings):
    """Configuration shared by every API process (admin portal, customer API).

    Holds only what the shared /api/v1 code, the database pool and the signed
    session need. Administration-only configuration -- Grafana credentials,
    the /app delivery switches -- lives in Settings below, so the customer API
    (src.customer_main, configured by src.customer_config) never requires or
    holds it.
    """

    db_host: str = Field(alias="EMS_APP_DB_HOST")
    db_port: int = Field(default=5432, alias="EMS_APP_DB_PORT")
    db_name: str = Field(alias="EMS_APP_DB_NAME")
    db_user: str = Field(alias="EMS_APP_DB_USER")
    db_password: str = Field(alias="EMS_APP_DB_PASSWORD")

    app_env: str = Field(
        default="production",
        alias="EMS_APP_ENV",
    )

    session_secret: str = Field(
        min_length=32,
        alias="EMS_APP_SESSION_SECRET",
    )

    session_cookie_name: str = Field(
        default="ems_admin_session",
        alias="EMS_APP_SESSION_COOKIE_NAME",
    )

    session_max_age_seconds: int = Field(
        default=28800,
        ge=300,
        le=86400,
        alias="EMS_APP_SESSION_MAX_AGE_SECONDS",
    )

    session_https_only: bool = Field(
        default=True,
        alias="EMS_APP_SESSION_HTTPS_ONLY",
    )

    # Reports tab export: off unless the environment sets it. Its database
    # objects (migrations 309 / 312) are staging-only
    # (postgres/migration_environment_scope.csv), so it is never enabled on
    # production. Gates both the report-export routes and the worker.
    reports_enabled: bool = Field(
        default=False,
        alias="EMS_REPORTS_ENABLED",
    )

    # Reports tab export (report_export_service.py / report_export_worker.py).
    # An export covers at most max_assets selected assets of a site and is
    # sized as buckets x columns over them: up to immediate_max_cells it
    # downloads in the request, up to max_cells it runs as a background job,
    # beyond that it is refused. max_cells admits the largest export the
    # contract allows: 10 assets x ~60 columns x 14 days at 1 minute
    # (20,160 buckets) is ~12 M cells.
    report_export_immediate_max_cells: int = Field(
        default=150_000,
        ge=0,
        alias="EMS_REPORT_EXPORT_IMMEDIATE_MAX_CELLS",
    )

    report_export_max_cells: int = Field(
        default=20_000_000,
        ge=1,
        alias="EMS_REPORT_EXPORT_MAX_CELLS",
    )

    report_export_max_assets: int = Field(
        default=10,
        ge=1,
        le=50,
        alias="EMS_REPORT_EXPORT_MAX_ASSETS",
    )

    # How long a completed background export stays downloadable.
    report_export_retention_hours: int = Field(
        default=24,
        ge=1,
        le=720,
        alias="EMS_REPORT_EXPORT_RETENTION_HOURS",
    )

    report_export_max_active_jobs: int = Field(
        default=3,
        ge=1,
        le=20,
        alias="EMS_REPORT_EXPORT_MAX_ACTIVE_JOBS",
    )

    report_export_worker_enabled: bool = Field(
        default=True,
        alias="EMS_REPORT_EXPORT_WORKER_ENABLED",
    )

    report_export_poll_seconds: float = Field(
        default=5.0,
        ge=1.0,
        le=300.0,
        alias="EMS_REPORT_EXPORT_POLL_SECONDS",
    )

    model_config = SettingsConfigDict(
        extra="ignore",
        case_sensitive=True,
    )

    @property
    def database_dsn(self) -> str:
        """Return a PostgreSQL connection string for psycopg."""
        return (
            f"host={self.db_host} "
            f"port={self.db_port} "
            f"dbname={self.db_name} "
            f"user={self.db_user} "
            f"password={self.db_password}"
        )


class Settings(CoreSettings):
    """Administration portal configuration (CoreSettings plus admin-only)."""

    grafana_url: str = Field(
        default="http://grafana:3000",
        alias="EMS_GRAFANA_URL",
    )

    # Same-origin proxy target for the Asset View live WebSocket (see
    # main.py's proxy_asset_live_websocket). Reuses the exact env var name
    # the grafana container already sets for its own backend plugin's
    # connection to the same service (compose.yaml) -- one internal address,
    # two independent, already-authenticated consumers.
    live_telemetry_ws_base_url: str = Field(
        default="ws://live-telemetry:8090",
        alias="EMS_LIVE_TELEMETRY_WS_BASE_URL",
    )

    # Dedicated EMS Web App container (compose service `ems-web`). When set
    # (e.g. http://ems-web:80), /app/* is served by proxying -- after the
    # existing authentication/authorization middleware -- to that container
    # instead of from the bind-mounted bundle at app/src/spa. Unset or empty
    # (the default) keeps the bind-mounted bundle hook exactly as before,
    # which is also the rollback fallback. See main.py's /app block.
    web_upstream: str | None = Field(
        default=None,
        alias="EMS_WEB_UPSTREAM",
    )

    @field_validator("web_upstream")
    @classmethod
    def _normalize_web_upstream(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        value = value.strip().rstrip("/")
        if not value.startswith(("http://", "https://")):
            raise ValueError("EMS_WEB_UPSTREAM must be an http:// or https:// URL")
        return value

    # Staff-only Administration App. When on, only GLOBAL-scope portal
    # identities (WiseWatts staff) can sign in to, or keep using, this
    # process; organization- and selected-sites-scoped identities (customers)
    # get the same generic login failure and are signed out. Off by default
    # until customers sign in through the customer API instead (ADR-023).
    admin_staff_only: bool = Field(
        default=False,
        alias="EMS_ADMIN_STAFF_ONLY",
    )

    grafana_admin_user: str = Field(
        alias="EMS_GRAFANA_ADMIN_USER",
    )

    grafana_admin_password: str = Field(
        alias="EMS_GRAFANA_ADMIN_PASSWORD",
    )

    grafana_db_password: str = Field(
        alias="EMS_GRAFANA_DB_PASSWORD",
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()


# The settings object of the running API process, for code shared by more
# than one process (src.database, the /api/v1 routers). The customer API
# registers its CustomerSettings at import (src.customer_main); the admin
# portal registers nothing and keeps using get_settings(), so its behaviour --
# and every test that patches get_settings() -- is unchanged.
_core_settings: CoreSettings | None = None


def use_core_settings(settings: CoreSettings) -> None:
    """Register the settings object of the running process."""

    global _core_settings
    _core_settings = settings


def get_core_settings() -> CoreSettings:
    """Return the running process's settings (admin portal by default)."""

    return _core_settings if _core_settings is not None else get_settings()
