import asyncio
import json
import logging
import threading
from datetime import datetime, timezone
from typing import Awaitable, Callable

import paho.mqtt.client as mqtt
from psycopg_pool import AsyncConnectionPool

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


class LiveTelemetryBroker:
    """Subscribe to MQTT and persist only canonical latest state, never history."""

    def __init__(
        self,
        *,
        pool: AsyncConnectionPool,
        host: str,
        port: int,
        username: str,
        password: str,
        client_id: str,
        use_tls: bool,
        on_device_update: Callable[[str], Awaitable[None]],
    ) -> None:
        self.pool = pool
        self.host = host
        self.port = port
        self.on_device_update = on_device_update
        self.loop: asyncio.AbstractEventLoop | None = None
        self._state_lock = threading.Lock()
        self._mqtt_connected = False
        self._subscription_mids: set[int] = set()
        self._confirmed_subscription_mids: set[int] = set()
        self._last_connect_at: datetime | None = None
        self._last_disconnect_at: datetime | None = None
        self._last_message_at: datetime | None = None
        self._last_ingest_success_at: datetime | None = None
        self._last_ingest_error_at: datetime | None = None
        self._last_ingest_error: str | None = None
        self._message_count = 0
        self._ingest_success_count = 0
        self._ingest_failure_count = 0
        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=client_id,
            protocol=mqtt.MQTTv311,
        )
        self.client.username_pw_set(username, password)
        if use_tls:
            self.client.tls_set()
        self.client.on_connect = self._on_connect
        self.client.on_subscribe = self._on_subscribe
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)

    async def start(self) -> None:
        self.loop = asyncio.get_running_loop()
        self.client.connect_async(self.host, self.port, keepalive=60)
        self.client.loop_start()

    async def stop(self) -> None:
        self.client.disconnect()
        self.client.loop_stop()

    def health_snapshot(self) -> dict[str, object]:
        """Return non-secret broker/ingest state suitable for health reporting."""
        with self._state_lock:
            return {
                "mqtt_connected": self._mqtt_connected,
                "subscriptions_confirmed": len(self._confirmed_subscription_mids),
                "subscriptions_expected": len(self._subscription_mids),
                "last_connect_at": self._iso(self._last_connect_at),
                "last_disconnect_at": self._iso(self._last_disconnect_at),
                "last_message_at": self._iso(self._last_message_at),
                "last_ingest_success_at": self._iso(self._last_ingest_success_at),
                "last_ingest_error_at": self._iso(self._last_ingest_error_at),
                "last_ingest_error": self._last_ingest_error,
                "message_count": self._message_count,
                "ingest_success_count": self._ingest_success_count,
                "ingest_failure_count": self._ingest_failure_count,
            }

    @staticmethod
    def _iso(value: datetime | None) -> str | None:
        return value.isoformat() if value is not None else None

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        now = datetime.now(timezone.utc)
        if reason_code != 0:
            with self._state_lock:
                self._mqtt_connected = False
                self._last_connect_at = now
                self._subscription_mids.clear()
                self._confirmed_subscription_mids.clear()
            logger.error("Live MQTT connection failed: %s", reason_code)
            return

        with self._state_lock:
            self._mqtt_connected = True
            self._last_connect_at = now
            self._subscription_mids.clear()
            self._confirmed_subscription_mids.clear()

        for topic in (
            "wwems/v1/+/+/+/telemetry",
            "wwems/v1/+/+/+/+/telemetry",
        ):
            result, mid = client.subscribe(topic, qos=1)
            if result == mqtt.MQTT_ERR_SUCCESS:
                with self._state_lock:
                    self._subscription_mids.add(mid)
            else:
                logger.error(
                    "Live MQTT subscribe request failed topic=%s result=%s",
                    topic,
                    result,
                )
        logger.info("Live MQTT subscriber connected")

    def _on_subscribe(self, client, userdata, mid, reason_codes, properties) -> None:
        accepted = bool(reason_codes) and all(
            not getattr(code, "is_failure", False) for code in reason_codes
        )
        if accepted:
            with self._state_lock:
                self._confirmed_subscription_mids.add(mid)
            logger.info("Live MQTT subscription confirmed mid=%s", mid)
        else:
            logger.error(
                "Live MQTT subscription rejected mid=%s reason_codes=%s",
                mid,
                reason_codes,
            )

    def _on_disconnect(
        self,
        client,
        userdata,
        disconnect_flags,
        reason_code,
        properties,
    ) -> None:
        with self._state_lock:
            self._mqtt_connected = False
            self._last_disconnect_at = datetime.now(timezone.utc)
            self._subscription_mids.clear()
            self._confirmed_subscription_mids.clear()
        logger.warning("Live MQTT subscriber disconnected: %s", reason_code)

    def _on_message(self, client, userdata, message) -> None:
        if self.loop is None:
            logger.error("Ignoring live MQTT message before event loop initialization")
            return
        try:
            payload = json.loads(message.payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            logger.warning("Ignoring invalid live MQTT JSON on %s", message.topic)
            return

        received_at = datetime.now(timezone.utc)
        with self._state_lock:
            self._last_message_at = received_at
            self._message_count += 1

        future = asyncio.run_coroutine_threadsafe(
            self._ingest(message.topic, payload, received_at),
            self.loop,
        )
        future.add_done_callback(self._ingest_done)

    def _ingest_done(self, future) -> None:
        try:
            future.result()
        except Exception:
            # _ingest records the health-state failure. This callback ensures the
            # exception can never disappear inside run_coroutine_threadsafe().
            logger.exception("Live MQTT ingest task failed")

    async def _ingest(self, topic: str, payload: dict, received_at: datetime) -> None:
        try:
            async with self.pool.connection() as connection:
                async with connection.cursor() as cursor:
                    await cursor.execute(
                        """
                        SELECT device_id
                        FROM telemetry.ingest_live_rtdata(%s, %s::jsonb, %s)
                        """,
                        (topic, json.dumps(payload), received_at),
                    )
                    rows = await cursor.fetchall()
                await connection.commit()

            now = datetime.now(timezone.utc)
            with self._state_lock:
                self._last_ingest_success_at = now
                self._last_ingest_error = None
                self._ingest_success_count += 1

            for row in rows:
                await self.on_device_update(str(row["device_id"]))
        except Exception as exc:
            now = datetime.now(timezone.utc)
            error_text = f"{type(exc).__name__}: {exc}"
            with self._state_lock:
                self._last_ingest_error_at = now
                self._last_ingest_error = error_text[:500]
                self._ingest_failure_count += 1
            raise
