from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "032_validated_energy_semantic_rollups.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "144_validated_energy_semantic_rollups.sql"
)


def test_native_semantic_union_uses_only_persisted_layers():
    sql = MIGRATION.read_text()

    assert "analytics.energy_consumption_1min" in sql
    assert "analytics.energy_consumption_5min" in sql

    assert "telemetry.ca_energy_1min" not in sql
    assert "telemetry.ca_energy_5min" not in sql


def test_reporting_rollups_exist():
    sql = MIGRATION.read_text()

    assert (
        "CREATE OR REPLACE VIEW "
        "analytics.v_energy_semantic_rollup_5min"
        in sql
    )

    assert (
        "CREATE OR REPLACE VIEW "
        "analytics.v_energy_semantic_rollup_15min"
        in sql
    )


def test_reporting_layer_never_reclassifies_registers():
    sql = MIGRATION.read_text()

    assert "classify_energy_register_delta" not in sql
    assert "resolve_interval_quality_rule" not in sql
    assert "energy_register_semantics" not in sql


def test_rollups_sum_only_valid_energy():
    sql = MIGRATION.read_text()

    assert "WHERE n.import_is_valid" in sql
    assert "WHERE n.export_is_valid" in sql
    assert "sum(n.import_consumption_kwh)" in sql
    assert "sum(n.export_consumption_kwh)" in sql


def test_rollups_preserve_quality_child_counts():
    sql = MIGRATION.read_text()

    required = (
        "valid_import_intervals",
        "invalid_import_intervals",
        "valid_export_intervals",
        "invalid_export_intervals",
        "import_gap_intervals",
        "export_gap_intervals",
        "import_reset_intervals",
        "export_reset_intervals",
        "import_rollover_intervals",
        "export_rollover_intervals",
    )

    for name in required:
        assert name in sql


def test_rollups_preserve_register_endpoints():
    sql = MIGRATION.read_text()

    assert "previous_import_register_wh" in sql
    assert "import_register_wh" in sql
    assert "previous_export_register_wh" in sql
    assert "export_register_wh" in sql
    assert "first_native_bucket_start" in sql
    assert "last_native_bucket_start" in sql


def test_rollups_expose_native_resolution_context():
    sql = MIGRATION.read_text()

    assert "native_resolution_seconds" in sql
    assert "minimum_native_resolution_seconds" in sql
    assert "maximum_native_resolution_seconds" in sql


def test_rollup_quality_status_does_not_hide_invalid_children():
    sql = MIGRATION.read_text()

    assert "INVALID_INTERVALS" in sql
    assert "RESET_DETECTED" in sql
    assert "GAPS_DETECTED" in sql
    assert "ROLLOVER_DETECTED" in sql
    assert "GOOD" in sql


def test_rollup_views_are_internal():
    sql = MIGRATION.read_text()

    assert "REVOKE ALL" in sql
    assert "FROM PUBLIC" in sql

    assert "TO grafana_reader" not in sql
    assert "TO ems_readonly" not in sql
    assert "TO ems_app" not in sql


def test_existing_public_views_are_not_replaced():
    sql = MIGRATION.read_text()

    assert (
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_5min"
        not in sql
    )

    assert (
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_15min"
        not in sql
    )

    assert (
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily"
        not in sql
    )

    assert (
        "CREATE OR REPLACE VIEW analytics.v_site_energy_balance_daily"
        not in sql
    )


def test_canonical_mirror_matches():
    assert MIRROR.read_text() == MIGRATION.read_text()
