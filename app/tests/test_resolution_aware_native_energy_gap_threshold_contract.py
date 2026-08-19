from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres"
    / "migrations"
    / "039_resolution_aware_native_energy_gap_threshold.sql"
)

DDL = (
    ROOT
    / "postgres"
    / "ddl"
    / "151_resolution_aware_native_energy_gap_threshold.sql"
)


def test_native_energy_gap_threshold_is_resolution_aware():
    sql = MIGRATION.read_text()

    assert (
        "LEAST(interval_rule.gap_threshold_minutes, 1.500::numeric)"
        in sql
    )

    assert (
        "LEAST(interval_rule.gap_threshold_minutes, 7.500::numeric)"
        in sql
    )

    assert sql.count(
        "LEAST(interval_rule.gap_threshold_minutes, 1.500::numeric)"
    ) == 3

    assert sql.count(
        "LEAST(interval_rule.gap_threshold_minutes, 7.500::numeric)"
    ) == 3


def test_declarative_mirror_matches_migration():
    assert DDL.read_text() == MIGRATION.read_text()


def test_generic_classifier_is_not_redefined():
    sql = MIGRATION.read_text()

    assert (
        "CREATE OR REPLACE FUNCTION "
        "analytics.classify_energy_register_delta"
        not in sql
    )
