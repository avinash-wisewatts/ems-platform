from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "033_energy_semantic_reporting_contract.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "145_energy_semantic_reporting_contract.sql"
)


def test_reporting_views_exist():
    sql = MIGRATION.read_text()

    assert (
        "CREATE OR REPLACE VIEW analytics.v_energy_reporting_5min"
        in sql
    )

    assert (
        "CREATE OR REPLACE VIEW analytics.v_energy_reporting_15min"
        in sql
    )


def test_reporting_views_are_security_barriers():
    sql = MIGRATION.read_text()

    assert sql.count("WITH (security_barrier = true)") == 2


def test_reporting_views_use_semantic_rollups():
    sql = MIGRATION.read_text()

    assert "analytics.v_energy_semantic_rollup_5min" in sql
    assert "analytics.v_energy_semantic_rollup_15min" in sql


def test_reporting_views_do_not_reclassify():
    sql = MIGRATION.read_text()

    forbidden = (
        "classify_energy_register_delta",
        "resolve_interval_quality_rule",
        "energy_register_semantics",
        "telemetry.ca_energy_",
    )

    for token in forbidden:
        assert token not in sql


def test_tenant_mapping_is_explicit():
    sql = MIGRATION.read_text()

    assert "metadata.grafana_organization_map" in sql
    assert "gom.organization_id = r.organization_id" in sql
    assert "gom.is_active = TRUE" in sql


def test_device_identity_is_tenant_bound():
    sql = MIGRATION.read_text()

    assert "metadata.devices d" in sql
    assert "d.id = r.device_id" in sql
    assert "d.organization_id = r.organization_id" in sql

    assert "d.external_id" in sql
    assert "d.name AS device_name" in sql


def test_rich_quality_contract_is_preserved():
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
        "import_quality_codes",
        "export_quality_codes",
        "quality_status",
    )

    for token in required:
        assert token in sql


def test_native_resolution_context_is_preserved():
    sql = MIGRATION.read_text()

    assert "minimum_native_resolution_seconds" in sql
    assert "maximum_native_resolution_seconds" in sql


def test_existing_consumption_views_are_not_replaced():
    sql = MIGRATION.read_text()

    forbidden = (
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_5min",
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_15min",
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily",
        "CREATE OR REPLACE VIEW analytics.v_site_energy_balance_daily",
        "CREATE OR REPLACE VIEW analytics.v_grafana_asset_energy_intervals",
    )

    for token in forbidden:
        assert token not in sql


def test_reporting_contract_is_not_yet_exposed_to_consumers():
    sql = MIGRATION.read_text()

    assert "TO grafana_reader" not in sql
    assert "TO ems_app" not in sql
    assert "TO ems_readonly" not in sql


def test_canonical_mirror_matches():
    assert MIRROR.read_text() == MIGRATION.read_text()
