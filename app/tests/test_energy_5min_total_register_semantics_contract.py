from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "030_fix_5min_total_register_semantics.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "142_fix_5min_total_register_semantics.sql"
)


def test_5min_view_uses_total_register_semantics():
    sql = MIGRATION.read_text()

    assert "CREATE OR REPLACE VIEW analytics.v_energy_consumption_5min" in sql
    assert "ENERGY_IMPORT_TOTAL" in sql
    assert "ENERGY_EXPORT_TOTAL" in sql

    assert (
        "import_sem.logical_point_id"
        in sql
    )
    assert (
        "export_sem.logical_point_id"
        in sql
    )


def test_5min_view_retains_authoritative_classifier():
    sql = MIGRATION.read_text()

    assert "resolve_interval_quality_rule" in sql
    assert sql.count("classify_energy_register_delta") == 2


def test_5min_view_retains_capture_policy_boundary():
    sql = MIGRATION.read_text()

    assert "resolve_site_capture_bucket" in sql
    assert "capture_interval_seconds" in sql
    assert "<= 300" in sql


def test_5min_view_preserves_grafana_grant():
    sql = MIGRATION.read_text()

    assert "REVOKE ALL" in sql
    assert "FROM PUBLIC" in sql
    assert "TO grafana_reader" in sql


def test_canonical_mirror_matches_migration():
    assert MIRROR.read_text() == MIGRATION.read_text()
