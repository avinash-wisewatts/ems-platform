from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = (ROOT / "postgres/migrations/025_live_telemetry_canonical_units.sql").read_text()


def test_live_mapping_metadata_supports_canonical_unit_conversion():
    assert "scale_to_canonical_unit" in MIGRATION
    assert "offset_to_canonical_unit" in MIGRATION
    assert "source_unit_symbol" in MIGRATION
    assert "config.profile_field_mapping" in MIGRATION
    assert "metadata.device_field_mapping" in MIGRATION


def test_eniscope_kilo_units_are_metadata_driven_not_frontend_hardcoded():
    assert "ENERGY_METER_ENISCOPE_V1" in MIGRATION
    assert "('kW','kWh','kVA','kVAh','kvar','kvarh')" in MIGRATION
    assert "THEN 0.001" in MIGRATION


def test_ingest_stores_canonical_numeric_and_text_values():
    assert "canonical_numeric_value" in MIGRATION
    assert "c.canonical_numeric_value::TEXT" in MIGRATION
    assert "trim(e.raw_value)::NUMERIC * e.scale_to_canonical_unit" in MIGRATION


def test_replay_protection_and_ambiguity_fix_remain_intact():
    assert "ON CONFLICT ON CONSTRAINT device_live_point_state_pkey" in MIGRATION
    assert "EXCLUDED.event_time > telemetry.device_live_point_state.event_time" in MIGRATION
