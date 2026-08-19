from pathlib import Path
import csv

SQL = Path("postgres/migrations/005_parameterized_domain_routing.sql").read_text()
CANONICAL = Path("postgres/ddl/124_parameterized_domain_routing.sql").read_text()


def test_forward_migration_matches_canonical_layer():
    assert SQL == CANONICAL


def test_energy_expansion_uses_parameterized_lateral_probe():
    energy = SQL.split("CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental", 1)[1]
    energy = energy.split("CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental", 1)[0]
    assert "FROM window_events we" in energy
    assert "CROSS JOIN LATERAL" in energy
    assert "FROM telemetry.normalized_points src_np" in energy
    assert "src_np.device_id = we.device_id" in energy
    assert "src_np.event_time = we.event_time" in energy
    assert "OFFSET 0" in energy
    assert "FROM telemetry.normalized_points np\n  JOIN window_events we" not in energy


def test_environment_expansion_uses_parameterized_lateral_probe():
    env = SQL.split("CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental", 1)[1]
    assert "FROM window_events we" in env
    assert "CROSS JOIN LATERAL" in env
    assert "FROM telemetry.normalized_points src_np" in env
    assert "src_np.device_id = we.device_id" in env
    assert "src_np.event_time = we.event_time" in env
    assert "OFFSET 0" in env
    assert "FROM telemetry.normalized_points np\nJOIN window_events we" not in env


def test_public_route_views_are_not_redefined_by_005():
    assert "CREATE VIEW telemetry.v_energy_measurements_route" not in SQL
    assert "CREATE OR REPLACE VIEW telemetry.v_energy_measurements_route" not in SQL
    assert "CREATE VIEW telemetry.v_environment_measurements_route" not in SQL
    assert "CREATE OR REPLACE VIEW telemetry.v_environment_measurements_route" not in SQL


def test_manifest_registers_005_and_124():
    with Path("postgres/restructure_manifest.csv").open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    by_source = {r["source_file"]: r for r in rows}
    assert by_source["005_parameterized_domain_routing.sql"]["target_category"] == "migration"
    assert by_source["124_parameterized_domain_routing.sql"]["target_category"] == "canonical_mirror"
