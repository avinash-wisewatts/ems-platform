from pathlib import Path
import csv

SQL = Path("postgres/migrations/004_bounded_domain_routing.sql").read_text()
CANONICAL = Path("postgres/ddl/123_bounded_domain_routing.sql").read_text()


def test_forward_migration_matches_canonical_layer():
    assert SQL == CANONICAL


def test_energy_loader_is_bounded_before_pivot_and_ranking():
    energy = SQL.split("CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental", 1)[1]
    energy = energy.split("CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental", 1)[0]
    assert "window_events AS MATERIALIZED" in energy
    assert "np.platform_received_at > v_window_start" in energy
    assert "np.platform_received_at <= v_window_end" in energy
    assert "JOIN window_events we" in energy
    assert "full_resolution AS MATERIALIZED" in energy
    assert "FROM telemetry.v_energy_measurements_route" not in energy
    assert "JOIN telemetry.v_energy_measurements_route" not in energy
    assert "we.platform_received_at" in energy


def test_environment_loader_is_bounded_before_pivot_and_ranking():
    env = SQL.split("CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental", 1)[1]
    assert "window_events AS MATERIALIZED" in env
    assert "np.platform_received_at > v_window_start" in env
    assert "np.platform_received_at <= v_window_end" in env
    assert "dp.profile_code='ENVIRONMENT_SENSOR_AIRSENSE_V1'" in env
    assert "JOIN window_events we" in env
    assert "FROM telemetry.v_environment_measurements_route" not in env
    assert "JOIN telemetry.v_environment_measurements_route" not in env


def test_public_route_views_are_not_redefined_by_004():
    assert "CREATE VIEW telemetry.v_energy_measurements_route" not in SQL
    assert "CREATE OR REPLACE VIEW telemetry.v_energy_measurements_route" not in SQL
    assert "CREATE VIEW telemetry.v_environment_measurements_route" not in SQL
    assert "CREATE OR REPLACE VIEW telemetry.v_environment_measurements_route" not in SQL


def test_manifest_registers_004_and_123():
    with Path("postgres/restructure_manifest.csv").open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    by_source = {r["source_file"]: r for r in rows}
    assert by_source["004_bounded_domain_routing.sql"]["target_category"] == "migration"
    assert by_source["123_bounded_domain_routing.sql"]["target_category"] == "canonical_mirror"
