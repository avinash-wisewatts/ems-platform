from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = (ROOT / "postgres/migrations/022_live_telemetry_state.sql").read_text()
COMPOSE = (ROOT / "compose.yaml").read_text()
LIVE_MAIN = (ROOT / "app/src/live_main.py").read_text()
BROKER = (ROOT / "app/src/live_telemetry/broker.py").read_text()


def test_live_state_is_separate_from_historian():
    assert "telemetry.device_live_point_state" in MIGRATION
    assert "PRIMARY KEY (device_id, logical_point_id)" in MIGRATION
    ingest = MIGRATION.split("CREATE OR REPLACE FUNCTION telemetry.ingest_live_rtdata", 1)[1]
    assert "FROM telemetry.normalized_points" not in ingest
    assert "FROM telemetry.energy_measurements" not in ingest


def test_live_ingest_reuses_metadata_mappings_and_rejects_replay_overwrite():
    assert "config.profile_field_mapping" in MIGRATION
    assert "metadata.device_field_mapping" in MIGRATION
    assert "config.device_point_configuration" in MIGRATION
    assert "EXCLUDED.event_time > telemetry.device_live_point_state.event_time" in MIGRATION


def test_live_service_keeps_mqtt_credentials_server_side():
    assert "live-telemetry" in COMPOSE
    assert "MQTT_USERNAME" in BROKER or "username" in BROKER
    assert "/api/live/assets/{asset_id}/ws" in LIVE_MAIN
    assert "get_portal_asset_live_state" in LIVE_MAIN


def test_grafana_fallback_contract_is_tenant_scoped_without_mqtt_credentials():
    assert "analytics.get_grafana_asset_live_state" in MIGRATION
    assert "metadata.grafana_organization_map" in MIGRATION
    assert "GRANT EXECUTE ON FUNCTION analytics.get_grafana_asset_live_state" in MIGRATION
    assert "grafana_reader" in MIGRATION
