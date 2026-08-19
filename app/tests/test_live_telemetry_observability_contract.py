from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIVE_MAIN = (ROOT / "app/src/live_main.py").read_text()
BROKER = (ROOT / "app/src/live_telemetry/broker.py").read_text()
COMPOSE = (ROOT / "compose.yaml").read_text()


def test_async_ingest_failures_cannot_disappear_silently():
    assert "future.add_done_callback(self._ingest_done)" in BROKER
    assert "future.result()" in BROKER
    assert 'logger.exception("Live MQTT ingest task failed")' in BROKER
    assert "_ingest_failure_count += 1" in BROKER
    assert "_last_ingest_error" in BROKER


def test_broker_tracks_connection_subscription_and_ingest_state():
    assert "self.client.on_subscribe = self._on_subscribe" in BROKER
    assert '"mqtt_connected"' in BROKER
    assert '"subscriptions_confirmed"' in BROKER
    assert '"last_message_at"' in BROKER
    assert '"last_ingest_success_at"' in BROKER
    assert '"ingest_success_count"' in BROKER


def test_health_checks_database_and_live_broker_readiness():
    assert 'await cursor.execute("SELECT 1")' in LIVE_MAIN
    assert "broker.health_snapshot()" in LIVE_MAIN
    assert '"status": "ok" if ready else "degraded"' in LIVE_MAIN
    assert "status_code=200 if ready else 503" in LIVE_MAIN
    assert "subscriptions_ready" in LIVE_MAIN


def test_compose_healthcheck_requires_application_health_ok():
    assert "data.get('status') == 'ok'" in COMPOSE
