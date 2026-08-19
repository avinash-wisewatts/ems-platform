from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIVE_MAIN = (ROOT / "app/src/live_main.py").read_text()
LIVE_CONFIG = (ROOT / "app/src/live_config.py").read_text()
HUB = (ROOT / "app/src/live_telemetry/hub.py").read_text()


def test_grafana_adapter_uses_same_live_service_not_mqtt():
    assert '/api/live/grafana/{grafana_org_id}/assets/{asset_id}/ws' in LIVE_MAIN
    assert 'analytics.get_grafana_asset_live_state' in LIVE_MAIN
    assert 'MQTT_' not in LIVE_MAIN


def test_grafana_stream_requires_service_bearer_token():
    assert 'EMS_GRAFANA_STREAM_TOKEN' in LIVE_CONFIG
    assert 'secrets.compare_digest' in LIVE_MAIN
    assert 'authorization' in LIVE_MAIN.lower()


def test_grafana_stream_is_tenant_scoped_by_grafana_org_and_asset():
    assert '(grafana_org_id, asset_id)' in LIVE_MAIN
    assert 'fetch_grafana_asset_state(subscriber.grafana_org_id, asset_id)' in LIVE_MAIN


def test_portal_and_grafana_subscribers_remain_separate_auth_boundaries():
    assert 'AssetLiveHub' in HUB
    assert 'GrafanaAssetLiveHub' in HUB
    assert 'deserialize_authenticated_user' in LIVE_MAIN
    assert 'grafana_stream_authorized' in LIVE_MAIN
