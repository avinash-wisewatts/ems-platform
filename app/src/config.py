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
