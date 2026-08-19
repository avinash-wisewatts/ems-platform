from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SQL = (
    ROOT
    / "postgres"
    / "migrations"
    / "011_site_demand_policy_contract.sql"
).read_text()


def test_site_demand_policy_is_effective_dated():
    assert "CREATE TABLE IF NOT EXISTS config.site_demand_policies" in SQL
    assert "effective_from TIMESTAMPTZ NOT NULL" in SQL
    assert "effective_to TIMESTAMPTZ" in SQL
    assert "effective_range TSTZRANGE" in SQL
    assert "ex_site_demand_policy_no_overlap" in SQL


def test_demand_interval_is_independent_of_capture_policy():
    assert "demand_interval_seconds IN (900, 1800)" in SQL
    assert "telemetry_capture_policies" not in SQL
    assert "ca_energy_15min" in SQL  # migration comment explicitly rejects it as authoritative


def test_demand_basis_supports_kw_and_kva():
    assert "ACTIVE_POWER_KW" in SQL
    assert "APPARENT_POWER_KVA" in SQL


def test_site_demand_source_is_explicit():
    assert "site_demand_source_role" in SQL
    assert "is_demand_source_eligible" in SQL
    assert "GRID_IMPORT" in SQL
    assert "SITE_CONSUMPTION" in SQL


def test_demand_storage_tracks_quality_and_source():
    assert "CREATE TABLE IF NOT EXISTS analytics.demand_intervals" in SQL
    assert "CREATE TABLE IF NOT EXISTS analytics.demand_state" in SQL

    for value in (
        "METER_NATIVE",
        "ENERGY_COUNTER_DELTA",
        "TIME_WEIGHTED_POWER",
        "VALID",
        "INCOMPLETE",
        "NO_DATA",
        "INVALID_SOURCE",
        "INSUFFICIENT_SOURCE_RESOLUTION",
    ):
        assert value in SQL


def test_current_demand_is_separate_from_instantaneous_power():
    assert "Current provisional demand-interval state" in SQL
    assert "instantaneous electrical power" in SQL


def test_admin_contract_is_scope_checked_and_audited():
    assert "admin.portal_user_has_permission" in SQL
    assert "admin.portal_user_can_access_site" in SQL
    assert "admin.write_audit_event" in SQL
    assert "SET_SITE_DEMAND_POLICY" in SQL


def test_readiness_does_not_fake_zero_demand():
    assert "SOURCE_NOT_CONFIGURED" in SQL
    assert "NOT_CONFIGURED" in SQL
    assert "source_ready" in SQL
