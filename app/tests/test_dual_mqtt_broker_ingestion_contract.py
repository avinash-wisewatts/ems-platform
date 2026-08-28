"""Static contract coverage for simultaneous dual-MQTT-broker ingestion.

Everything here is parsed/constructed from repository files and the
application configuration model. No MQTT broker connection is opened and no
MQTT message is ever published or subscribed.
"""

import tomllib
from pathlib import Path

import pytest
from pydantic import ValidationError

from src.live_config import BrokerConfig, LiveSettings

ROOT = Path(__file__).resolve().parents[2]
TELEGRAF_CONF_TEXT = (ROOT / "telegraf/config/telegraf.conf").read_text()
TELEGRAF_CONF = tomllib.loads(TELEGRAF_CONF_TEXT)
LIVE_MAIN = (ROOT / "app/src/live_main.py").read_text()
LIVE_CONFIG = (ROOT / "app/src/live_config.py").read_text()
BOOTSTRAP_VALIDATE = (ROOT / "scripts/bootstrap/02_validate_env.sh").read_text()
TELEGRAF_ENV_EXAMPLE = ROOT / "telegraf/.env.example"
LIVE_ENV_EXAMPLE = (ROOT / "app/live-telemetry.env.example").read_text()

TOPIC_PATTERNS = ["wwems/v1/+/+/+/telemetry", "wwems/v1/+/+/+/+/telemetry"]


# --------------------------------------------------------------------------- #
# Telegraf: two independent mqtt_consumer instances, one PostgreSQL output    #
# --------------------------------------------------------------------------- #
def _consumers() -> list[dict]:
    return TELEGRAF_CONF["inputs"]["mqtt_consumer"]


def test_telegraf_has_exactly_two_independent_mqtt_consumers():
    assert len(_consumers()) == 2
    assert len(TELEGRAF_CONF["outputs"]["postgresql"]) == 1


def test_broker1_consumer_is_functionally_unchanged():
    broker1 = _consumers()[0]
    assert broker1["servers"] == ["ssl://${MQTT_HOST}:${MQTT_PORT}"]
    assert broker1["username"] == "${MQTT_USERNAME}"
    assert broker1["password"] == "${MQTT_PASSWORD}"
    assert broker1["name_override"] == "mqtt_staging"
    assert broker1["qos"] == 1
    assert broker1["topics"] == TOPIC_PATTERNS
    # Broker #1 carries no provenance tag (its absence is the distinguisher).
    assert "tags" not in broker1


def test_broker2_consumer_uses_dedicated_telegraf_credentials():
    broker2 = _consumers()[1]
    assert broker2["servers"] == ["ssl://${MQTT2_HOST}:${MQTT2_PORT}"]
    # Telegraf's Broker #2 identity is its OWN, not the live subscriber's.
    assert broker2["username"] == "${MQTT2_TELEGRAF_USERNAME}"
    assert broker2["password"] == "${MQTT2_TELEGRAF_PASSWORD}"


def test_broker2_telegraf_and_live_credentials_are_not_conflated():
    # The Telegraf consumer must not reference the live subscriber's creds...
    assert "${MQTT2_LIVE_USERNAME}" not in TELEGRAF_CONF_TEXT
    assert "${MQTT2_LIVE_PASSWORD}" not in TELEGRAF_CONF_TEXT
    # ...and neither path may use an ambiguous shared MQTT2_USERNAME/PASSWORD.
    assert "MQTT2_USERNAME" not in TELEGRAF_CONF_TEXT
    assert "MQTT2_PASSWORD" not in TELEGRAF_CONF_TEXT
    assert "MQTT2_USERNAME" not in LIVE_CONFIG
    assert "MQTT2_PASSWORD" not in LIVE_CONFIG
    # The live config model references only its dedicated live credentials.
    assert 'alias="MQTT2_LIVE_USERNAME"' in LIVE_CONFIG
    assert 'alias="MQTT2_LIVE_PASSWORD"' in LIVE_CONFIG
    assert "MQTT2_TELEGRAF_USERNAME" not in LIVE_CONFIG


def test_both_consumers_share_topics_qos_and_name_override():
    for consumer in _consumers():
        assert consumer["name_override"] == "mqtt_staging"
        assert consumer["qos"] == 1
        assert consumer["topics"] == TOPIC_PATTERNS
        assert consumer["data_format"] == "value"
        assert consumer["data_type"] == "string"


def test_broker2_has_operational_provenance_tag_only():
    broker2 = _consumers()[1]
    assert broker2["tags"] == {"broker": "2"}


def test_not_implemented_as_a_failover_servers_array():
    # A multi-entry servers array is Telegraf failover, not simultaneous
    # fan-in. Each consumer must point at exactly one broker.
    for consumer in _consumers():
        assert len(consumer["servers"]) == 1


def test_postgresql_output_is_unchanged_single_instance():
    output = TELEGRAF_CONF["outputs"]["postgresql"][0]
    assert output["schema"] == "public"
    assert output["tags_as_jsonb"] is True
    assert output["fields_as_jsonb"] is True
    assert "public.mqtt_staging" in TELEGRAF_CONF_TEXT or "mqtt_staging" in TELEGRAF_CONF_TEXT


# --------------------------------------------------------------------------- #
# LiveSettings: construct one or two brokers, reject partial config           #
# --------------------------------------------------------------------------- #
_MQTT2_LIVE_ENV = (
    "MQTT2_HOST",
    "MQTT2_PORT",
    "MQTT2_LIVE_USERNAME",
    "MQTT2_LIVE_PASSWORD",
    "MQTT2_LIVE_CLIENT_ID",
    "MQTT2_TLS",
)


def _clear_mqtt2(monkeypatch):
    for name in _MQTT2_LIVE_ENV:
        monkeypatch.delenv(name, raising=False)


def test_single_broker_is_the_default(monkeypatch):
    _clear_mqtt2(monkeypatch)
    configs = LiveSettings().broker_configs()
    assert len(configs) == 1
    assert isinstance(configs[0], BrokerConfig)
    assert configs[0].client_id == LiveSettings().mqtt_client_id


def test_two_brokers_when_full_mqtt2_live_set_supplied(monkeypatch):
    _clear_mqtt2(monkeypatch)
    monkeypatch.setenv("MQTT2_HOST", "second-broker.internal")
    monkeypatch.setenv("MQTT2_PORT", "8884")
    monkeypatch.setenv("MQTT2_LIVE_USERNAME", "second-live-user")
    monkeypatch.setenv("MQTT2_LIVE_PASSWORD", "second-live-pass")
    monkeypatch.setenv("MQTT2_LIVE_CLIENT_ID", "ems-live-telemetry-b2")

    configs = LiveSettings().broker_configs()
    assert len(configs) == 2
    assert configs[0].host != configs[1].host
    assert configs[1].host == "second-broker.internal"
    assert configs[1].port == 8884
    # Broker #2 live path uses its dedicated live credentials.
    assert configs[1].username == "second-live-user"
    assert configs[1].password == "second-live-pass"
    # Distinct client ids are mandatory for two concurrent MQTT connections.
    assert configs[0].client_id != configs[1].client_id
    assert configs[1].client_id == "ems-live-telemetry-b2"


def test_live_config_ignores_telegraf_broker2_credentials(monkeypatch):
    # A Telegraf-only credential set must NOT be enough to construct a live
    # Broker #2 -- the live path requires its own MQTT2_LIVE_* identity.
    _clear_mqtt2(monkeypatch)
    monkeypatch.setenv("MQTT2_HOST", "second-broker.internal")
    monkeypatch.setenv("MQTT2_TELEGRAF_USERNAME", "second-telegraf-user")
    monkeypatch.setenv("MQTT2_TELEGRAF_PASSWORD", "second-telegraf-pass")
    with pytest.raises(ValidationError) as excinfo:
        LiveSettings()
    assert "partially configured" in str(excinfo.value)


def test_partial_second_broker_is_rejected(monkeypatch):
    _clear_mqtt2(monkeypatch)
    monkeypatch.setenv("MQTT2_HOST", "second-broker.internal")
    with pytest.raises(ValidationError) as excinfo:
        LiveSettings()
    assert "partially configured" in str(excinfo.value)


def test_second_broker_reusing_broker1_client_id_is_rejected(monkeypatch):
    _clear_mqtt2(monkeypatch)
    broker1_client_id = LiveSettings().mqtt_client_id  # resolved before any MQTT2_* env
    monkeypatch.setenv("MQTT2_HOST", "second-broker.internal")
    monkeypatch.setenv("MQTT2_LIVE_USERNAME", "second-live-user")
    monkeypatch.setenv("MQTT2_LIVE_PASSWORD", "second-live-pass")
    monkeypatch.setenv("MQTT2_LIVE_CLIENT_ID", broker1_client_id)
    with pytest.raises(ValidationError) as excinfo:
        LiveSettings()
    assert "must differ" in str(excinfo.value)


def test_second_broker_tls_defaults_to_first_and_is_overridable(monkeypatch):
    _clear_mqtt2(monkeypatch)
    monkeypatch.setenv("MQTT2_HOST", "second-broker.internal")
    monkeypatch.setenv("MQTT2_LIVE_USERNAME", "second-live-user")
    monkeypatch.setenv("MQTT2_LIVE_PASSWORD", "second-live-pass")
    monkeypatch.setenv("MQTT2_LIVE_CLIENT_ID", "ems-live-telemetry-b2")
    inherited = LiveSettings()
    assert inherited.broker_configs()[1].use_tls == inherited.mqtt_tls

    monkeypatch.setenv("MQTT2_TLS", "false")
    overridden = LiveSettings().broker_configs()
    assert overridden[1].use_tls is False


# --------------------------------------------------------------------------- #
# live_main: two brokers run together, /health aggregates, readiness strict   #
# --------------------------------------------------------------------------- #
def test_live_main_starts_and_stops_every_configured_broker():
    assert "brokers: list[LiveTelemetryBroker]" in LIVE_MAIN
    assert "for broker_config in settings.broker_configs()" in LIVE_MAIN
    assert "await live_broker.start()" in LIVE_MAIN
    assert "await live_broker.stop()" in LIVE_MAIN
    # Reuses the existing broker implementation, not a second one.
    assert LIVE_MAIN.count("from src.live_telemetry.broker import LiveTelemetryBroker") == 1


def test_live_main_health_aggregates_all_brokers():
    assert "broker_states = [live_broker.health_snapshot() for live_broker in brokers]" in LIVE_MAIN
    assert '"brokers_expected": expected_brokers' in LIVE_MAIN
    assert '"brokers": broker_states' in LIVE_MAIN


def test_live_main_readiness_requires_every_broker_and_subscription():
    assert "len(broker_states) == expected_brokers" in LIVE_MAIN
    assert "all(_broker_state_ready(state) for state in broker_states)" in LIVE_MAIN
    assert "ready = bool(db_ok and subscriptions_ready)" in LIVE_MAIN
    assert '"status": "ok" if ready else "degraded"' in LIVE_MAIN
    assert "status_code=200 if ready else 503" in LIVE_MAIN


# --------------------------------------------------------------------------- #
# bootstrap env validation: MQTT2 group is all-or-nothing, nothing weakened   #
# --------------------------------------------------------------------------- #
def test_bootstrap_validates_both_distinct_broker2_credential_pairs():
    assert "check_all_or_none" in BOOTSTRAP_VALIDATE
    # Telegraf group: dedicated Telegraf credentials.
    assert (
        "MQTT2_HOST MQTT2_PORT MQTT2_TELEGRAF_USERNAME MQTT2_TELEGRAF_PASSWORD"
        in BOOTSTRAP_VALIDATE
    )
    # Live group: dedicated live credentials + distinct client id.
    assert (
        "MQTT2_HOST MQTT2_PORT MQTT2_LIVE_USERNAME MQTT2_LIVE_PASSWORD MQTT2_LIVE_CLIENT_ID"
        in BOOTSTRAP_VALIDATE
    )
    # The ambiguous shared names must not appear anywhere in validation.
    assert "MQTT2_USERNAME" not in BOOTSTRAP_VALIDATE
    assert "MQTT2_PASSWORD" not in BOOTSTRAP_VALIDATE
    # Existing Broker #1 checks remain intact.
    for name in ("MQTT_HOST", "MQTT_PORT", "MQTT_USERNAME", "MQTT_PASSWORD"):
        assert f'check_variable "${{TELEGRAF_ENV}}" "{name}"' in BOOTSTRAP_VALIDATE


# --------------------------------------------------------------------------- #
# Placeholder-only example files                                             #
# --------------------------------------------------------------------------- #
def test_telegraf_env_example_uses_dedicated_telegraf_broker2_creds_placeholders():
    assert TELEGRAF_ENV_EXAMPLE.is_file()
    text = TELEGRAF_ENV_EXAMPLE.read_text()
    for name in (
        "MQTT_HOST",
        "MQTT_USERNAME",
        "MQTT2_HOST",
        "MQTT2_PORT",
        "MQTT2_TELEGRAF_USERNAME",
        "MQTT2_TELEGRAF_PASSWORD",
        "POSTGRES_USER",
        "POSTGRES_DB",
    ):
        assert name in text
    # No live creds, no ambiguous shared names in the Telegraf template.
    assert "MQTT2_LIVE_USERNAME" not in text
    assert "MQTT2_USERNAME" not in text
    assert "MQTT2_PASSWORD" not in text
    assert "replace-me" in text
    assert "hivemq.cloud" not in text or "your-cluster" in text


def test_live_env_example_uses_dedicated_live_broker2_creds_placeholders():
    for name in ("MQTT2_HOST", "MQTT2_LIVE_USERNAME", "MQTT2_LIVE_PASSWORD", "MQTT2_LIVE_CLIENT_ID"):
        assert name in LIVE_ENV_EXAMPLE
    # No Telegraf creds, no ambiguous shared names in the live template.
    assert "MQTT2_TELEGRAF_USERNAME" not in LIVE_ENV_EXAMPLE
    assert "MQTT2_USERNAME" not in LIVE_ENV_EXAMPLE
    assert "MQTT2_PASSWORD" not in LIVE_ENV_EXAMPLE
    assert "NOT failover" in LIVE_ENV_EXAMPLE or "not failover" in LIVE_ENV_EXAMPLE.lower()


# --------------------------------------------------------------------------- #
# Guard: this contract test never touches a live broker                       #
# --------------------------------------------------------------------------- #
def test_this_module_never_imports_or_drives_an_mqtt_client():
    import_lines = [
        line.strip()
        for line in Path(__file__).read_text().splitlines()
        if line.strip().startswith(("import ", "from "))
    ]
    assert not any("paho" in line for line in import_lines)
    assert not any("socket" in line for line in import_lines)
