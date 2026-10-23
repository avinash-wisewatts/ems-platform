from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration loaded from container environment variables."""

    db_host: str = Field(alias="EMS_APP_DB_HOST")
    db_port: int = Field(default=5432, alias="EMS_APP_DB_PORT")
    db_name: str = Field(alias="EMS_APP_DB_NAME")
    db_user: str = Field(alias="EMS_APP_DB_USER")
    db_password: str = Field(alias="EMS_APP_DB_PASSWORD")

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

    grafana_admin_user: str = Field(
        alias="EMS_GRAFANA_ADMIN_USER",
    )

    grafana_admin_password: str = Field(
        alias="EMS_GRAFANA_ADMIN_PASSWORD",
    )

    grafana_db_password: str = Field(
        alias="EMS_GRAFANA_DB_PASSWORD",
    )

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

    # Reports tab export (report_export_service.py / report_export_worker.py).
    # An export is sized as buckets x columns over the site's assets: up to
    # immediate_max_cells it downloads in the request, up to max_cells it
    # runs as a background job, beyond that it is refused.
    report_export_immediate_max_cells: int = Field(
        default=150_000,
        ge=0,
        alias="EMS_REPORT_EXPORT_IMMEDIATE_MAX_CELLS",
    )

    report_export_max_cells: int = Field(
        default=3_000_000,
        ge=1,
        alias="EMS_REPORT_EXPORT_MAX_CELLS",
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


@lru_cache
def get_settings() -> Settings:
    return Settings()
