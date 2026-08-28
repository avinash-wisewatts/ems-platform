from dataclasses import dataclass
from functools import lru_cache

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


@dataclass(frozen=True)
class BrokerConfig:
    """Connection parameters for one MQTT broker the live service subscribes to."""

    host: str
    port: int
    username: str
    password: str
    client_id: str
    use_tls: bool


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

    # Optional second MQTT broker consumed simultaneously (not failover).
    # Host/port/TLS are shared with the Telegraf consumer; the live subscriber
    # uses its OWN dedicated credentials (MQTT2_LIVE_USERNAME /
    # MQTT2_LIVE_PASSWORD) and client id, distinct from the Telegraf consumer's
    # MQTT2_TELEGRAF_* identity -- mirroring Broker #1's per-path split.
    # Either supply the full live set (MQTT2_HOST, MQTT2_PORT,
    # MQTT2_LIVE_USERNAME, MQTT2_LIVE_PASSWORD, MQTT2_LIVE_CLIENT_ID) or none
    # of it. A partial set is a configuration error and is rejected below.
    # When unset, the service behaves exactly as before with a single broker.
    mqtt2_host: str | None = Field(default=None, alias="MQTT2_HOST")
    mqtt2_port: int = Field(default=8883, alias="MQTT2_PORT")
    mqtt2_live_username: str | None = Field(default=None, alias="MQTT2_LIVE_USERNAME")
    mqtt2_live_password: str | None = Field(default=None, alias="MQTT2_LIVE_PASSWORD")
    mqtt2_client_id: str | None = Field(default=None, alias="MQTT2_LIVE_CLIENT_ID")
    # Defaults to the Broker #1 TLS setting when not explicitly provided.
    mqtt2_tls: bool | None = Field(default=None, alias="MQTT2_TLS")

    grafana_stream_token: str = Field(min_length=32, alias="EMS_GRAFANA_STREAM_TOKEN")

    # Bounds concurrent telemetry.ingest_live_rtdata() calls so an MQTT burst
    # (e.g. the retained-message flood on reconnect) cannot occupy every
    # connection in the live-telemetry DB pool. Kept below the pool's
    # max_size=10 (see live_main.py's lifespan()) so the live-tile read path
    # (fetch_grafana_asset_state) always has pool capacity available, even
    # under maximum ingest concurrency.
    live_ingest_max_concurrency: int = Field(default=6, alias="EMS_LIVE_INGEST_MAX_CONCURRENCY")

    # Bounded retry for a transient pool-acquisition timeout on the live-tile
    # WebSocket connect path. Finite by construction: at most this many
    # attempts, each separated by the fixed backoff below.
    live_pool_acquire_max_attempts: int = Field(default=3, alias="EMS_LIVE_POOL_ACQUIRE_MAX_ATTEMPTS")
    live_pool_acquire_retry_backoff_seconds: float = Field(
        default=0.5, alias="EMS_LIVE_POOL_ACQUIRE_RETRY_BACKOFF_SECONDS"
    )

    model_config = SettingsConfigDict(extra="ignore", case_sensitive=True)

    @model_validator(mode="after")
    def _validate_second_broker(self) -> "LiveSettings":
        second_broker_fields = {
            "MQTT2_HOST": self.mqtt2_host,
            "MQTT2_LIVE_USERNAME": self.mqtt2_live_username,
            "MQTT2_LIVE_PASSWORD": self.mqtt2_live_password,
            "MQTT2_LIVE_CLIENT_ID": self.mqtt2_client_id,
        }
        supplied = {name for name, value in second_broker_fields.items() if value}
        if not supplied:
            return self
        missing = sorted(set(second_broker_fields) - supplied)
        if missing:
            raise ValueError(
                "Second MQTT broker is partially configured. Supply all of "
                f"{sorted(second_broker_fields)} or none. Missing: {missing}."
            )
        if self.mqtt2_client_id == self.mqtt_client_id:
            raise ValueError(
                "MQTT2_LIVE_CLIENT_ID must differ from MQTT_LIVE_CLIENT_ID; "
                "an MQTT broker rejects a second connection reusing a client id."
            )
        return self

    @property
    def database_dsn(self) -> str:
        return (
            f"host={self.db_host} port={self.db_port} dbname={self.db_name} "
            f"user={self.db_user} password={self.db_password}"
        )

    def broker_configs(self) -> list[BrokerConfig]:
        """Every MQTT broker the live service must subscribe to, in order.

        Always contains Broker #1 (the existing MQTT_* variables). Contains a
        second entry only when the full MQTT2_* set is supplied; partial
        configuration is already rejected by ``_validate_second_broker``.
        """
        brokers = [
            BrokerConfig(
                host=self.mqtt_host,
                port=self.mqtt_port,
                username=self.mqtt_username,
                password=self.mqtt_password,
                client_id=self.mqtt_client_id,
                use_tls=self.mqtt_tls,
            )
        ]
        if self.mqtt2_host:
            brokers.append(
                BrokerConfig(
                    host=self.mqtt2_host,
                    port=self.mqtt2_port,
                    username=self.mqtt2_live_username,
                    password=self.mqtt2_live_password,
                    client_id=self.mqtt2_client_id,
                    use_tls=self.mqtt_tls if self.mqtt2_tls is None else self.mqtt2_tls,
                )
            )
        return brokers


@lru_cache
def get_live_settings() -> LiveSettings:
    return LiveSettings()
