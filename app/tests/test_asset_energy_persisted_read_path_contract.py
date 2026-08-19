from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "029_asset_energy_persisted_read_path.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "141_asset_energy_persisted_read_path.sql"
)


def test_asset_energy_contract_keeps_existing_function_signature():
    sql = MIGRATION.read_text()

    assert (
        "analytics.get_grafana_asset_energy_intervals("
        in sql
    )

    assert "p_grafana_org_id BIGINT" in sql
    assert "p_asset_id UUID" in sql
    assert "p_from TIMESTAMPTZ" in sql
    assert "p_to TIMESTAMPTZ" in sql


def test_asset_energy_contract_reads_persisted_layer():
    sql = MIGRATION.read_text()

    assert "analytics.energy_consumption_1min" in sql
    assert "telemetry.energy_measurements" not in sql
    assert "classify_energy_register_delta" not in sql
    assert "resolve_interval_quality_rule" not in sql


def test_asset_energy_contract_preserves_tenant_boundary():
    sql = MIGRATION.read_text()

    assert "metadata.grafana_organization_map" in sql
    assert "gom.grafana_org_id = p_grafana_org_id" in sql
    assert "gom.is_active" in sql
    assert "a.organization_id = gom.organization_id" in sql
    assert "a.id = p_asset_id" in sql


def test_asset_energy_contract_requires_primary_meter():
    sql = MIGRATION.read_text()

    assert "metadata.asset_devices" in sql
    assert "ad.relationship_type = 'PRIMARY_METER'" in sql


def test_asset_energy_contract_preserves_expected_outputs():
    sql = MIGRATION.read_text()

    for name in (
        "interval_start",
        "device_id",
        "device_name",
        "elapsed_minutes",
        "import_consumption_kwh",
        "export_consumption_kwh",
        "import_quality_code",
        "export_quality_code",
        "reset_detected",
        "gap_detected",
    ):
        assert name in sql


def test_asset_energy_contract_preserves_least_privilege():
    sql = MIGRATION.read_text()

    assert "SECURITY DEFINER" in sql
    assert "REVOKE ALL" in sql
    assert "FROM PUBLIC" in sql
    assert "grafana_reader" in sql
    assert "ems_readonly" in sql
    assert "ems_app" in sql


def test_canonical_mirror_matches_migration():
    assert MIRROR.read_text() == MIGRATION.read_text()
