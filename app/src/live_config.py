from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class LiveSettings(BaseSettings):
    """Runtime configuration for the dedicated live telemetry service."""

    db_host: str = Field(alias="EMS_APP_DB_HOST")
    db_port: int = Field(default=5432, alias="EMS_APP_DB_PORT")
    db_name: str = Field(alias="EMS_APP_DB_NAME")
    db_user: str = Field(alias="EMS_APP_DB_USER")
    db_password: str = Field(alias="EMS_APP_DB_PASSWORD")

    session_secret: str = Field(min_length=32, alias="EMS_APP_SESSION_SECRET")
    session_cookie_name: str = Field(default="ems_admin_session", alias="EMS_APP_SESSION_COOKIE_NAME")
    session_max_age_seconds: int = Field(default=28800, alias="EMS_APP_SESSION_MAX_AGE_SECONDS")
    session_https_only: bool = Field(default=True, alias="EMS_APP_SESSION_HTTPS_ONLY")

    mqtt_host: str = Field(alias="MQTT_HOST")
    mqtt_port: int = Field(default=8883, alias="MQTT_PORT")
    mqtt_username: str = Field(alias="MQTT_USERNAME")
    mqtt_password: str = Field(alias="MQTT_PASSWORD")
    mqtt_client_id: str = Field(default="ems-live-telemetry", alias="MQTT_LIVE_CLIENT_ID")
    mqtt_tls: bool = Field(default=True, alias="MQTT_TLS")

    grafana_stream_token: str = Field(min_length=32, alias="EMS_GRAFANA_STREAM_TOKEN")

    model_config = SettingsConfigDict(extra="ignore", case_sensitive=True)

    @property
    def database_dsn(self) -> str:
        return (
            f"host={self.db_host} port={self.db_port} dbname={self.db_name} "
            f"user={self.db_user} password={self.db_password}"
        )


@lru_cache
def get_live_settings() -> LiveSettings:
    return LiveSettings()
