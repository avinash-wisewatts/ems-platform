from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "035_combined_energy_quality_counters.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "147_combined_energy_quality_counters.sql"
)


def test_native_combined_event_flags_are_explicit():
    sql = MIGRATION.read_text()

    assert "AS reset_detected" in sql
    assert "AS rollover_detected" in sql
    assert "AS invalid_detected" in sql

    assert "gap_detected" in sql


def test_invalid_combines_import_and_export_validity():
    sql = MIGRATION.read_text()

    assert "import_is_valid IS NOT TRUE" in sql
    assert "export_is_valid IS NOT TRUE" in sql


def test_reset_and_rollover_use_boolean_or_not_addition():
    sql = MIGRATION.read_text()

    assert "COALESCE(import_reset_detected, FALSE)" in sql
    assert "COALESCE(export_reset_detected, FALSE)" in sql

    assert "COALESCE(import_rollover_detected, FALSE)" in sql
    assert "COALESCE(export_rollover_detected, FALSE)" in sql


def test_rollups_count_combined_native_events():
    sql = MIGRATION.read_text()

    required = (
        "count(*) FILTER (WHERE n.gap_detected)",
        "count(*) FILTER (WHERE n.reset_detected)",
        "count(*) FILTER (WHERE n.rollover_detected)",
        "count(*) FILTER (WHERE n.invalid_detected)",
    )

    for token in required:
        assert token in sql


def test_combined_counters_are_exposed_upward():
    sql = MIGRATION.read_text()

    required = (
        "gap_interval_count",
        "reset_interval_count",
        "rollover_interval_count",
        "invalid_interval_count",
    )

    for token in required:
        assert token in sql


def test_daily_sums_combined_counts_not_import_export_counts():
    sql = MIGRATION.read_text()

    assert "sum(r.gap_interval_count)" in sql
    assert "sum(r.reset_interval_count)" in sql
    assert "sum(r.rollover_interval_count)" in sql
    assert "sum(r.invalid_interval_count)" in sql


def test_no_register_reclassification():
    sql = MIGRATION.read_text()

    forbidden = (
        "classify_energy_register_delta",
        "resolve_interval_quality_rule",
        "energy_register_semantics",
        "telemetry.ca_energy_",
    )

    for token in forbidden:
        assert token not in sql


def test_no_public_consumer_cutover():
    sql = MIGRATION.read_text()

    forbidden = (
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily",
        "CREATE OR REPLACE VIEW analytics.v_site_energy_balance_daily",
        "TO grafana_reader",
        "TO ems_app",
        "TO ems_readonly",
    )

    for token in forbidden:
        assert token not in sql


def test_canonical_mirror_matches():
    assert MIRROR.read_text() == MIGRATION.read_text()
