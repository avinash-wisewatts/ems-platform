from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / "postgres/migrations/012_demand_capability_resolution.sql").read_text()
DDL = (ROOT / "postgres/ddl/131_demand_capability_resolution.sql").read_text()


def test_migration_has_identical_canonical_mirror():
    assert SQL == DDL


def test_site_interval_idempotency_is_null_safe():
    assert "DROP CONSTRAINT IF EXISTS" in SQL
    assert "demand_intervals_interval_start_scope_type_site_id_asset_id_key" in SQL
    assert "uq_demand_intervals_site_scope" in SQL
    assert "WHERE scope_type = 'SITE'" in SQL
    assert "uq_demand_intervals_asset_scope" in SQL
    assert "WHERE scope_type = 'ASSET'" in SQL


def test_native_demand_requires_explicit_semantics():
    assert "CREATE TABLE IF NOT EXISTS config.demand_register_semantics" in SQL
    assert "native_interval_seconds" in SQL
    assert "demand_basis" in SQL
    assert "alignment_mode" in SQL
    assert "METER_NATIVE" in SQL


def test_capability_comes_from_profile_mappings_not_live_values():
    assert "config.profile_field_mapping" in SQL
    assert "config.energy_register_semantics" in SQL
    assert "config.device_point_configuration" in SQL
    assert "metadata.logical_points" in SQL
    assert "telemetry.energy_measurements" not in SQL


def test_kw_and_kva_use_independent_canonical_sources():
    for logical_point in (
        "ENERGY_IMPORT_TOTAL",
        "APPARENT_ENERGY_TOTAL",
        "ACTIVE_POWER_TOTAL",
        "APPARENT_POWER_TOTAL",
    ):
        assert logical_point in SQL

    assert "ACTIVE_POWER_KW" in SQL
    assert "APPARENT_POWER_KVA" in SQL


def test_method_priority_is_native_then_counter_then_power():
    native = SQL.index("WHEN nc.logical_point_id IS NOT NULL")
    counter = SQL.index("WHEN cc.logical_point_id IS NOT NULL", native)
    power = SQL.index("WHEN pc.logical_point_id IS NOT NULL", counter)
    assert native < counter < power
    assert "ENERGY_COUNTER_DELTA" in SQL
    assert "TIME_WEIGHTED_POWER" in SQL


def test_scope_source_selection_is_explicit():
    assert "site_energy_meter_roles" in SQL
    assert "p.site_demand_source_role" in SQL
    assert "relationship_type = 'PRIMARY_METER'" in SQL
    assert "SOURCE_NOT_CONFIGURED" in SQL


def test_unsupported_basis_is_not_faked_ready():
    assert "BASIS_NOT_SUPPORTED" in SQL
    assert "SOURCE_PROFILE_NOT_CONFIGURED" in SQL
    assert "SOURCE_POINT_NOT_ENABLED" in SQL
    assert "capability_ready" in SQL


def test_admin_readiness_uses_capability_resolver():
    assert "CREATE OR REPLACE FUNCTION admin.get_site_demand_readiness" in SQL
    assert "analytics.resolve_demand_capability" in SQL
    assert "c.capability_ready AS source_ready" in SQL
