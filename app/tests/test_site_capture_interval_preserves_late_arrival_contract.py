from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = (
    ROOT
    / "postgres"
    / "migrations"
    / "020_preserve_site_capture_late_arrival_tolerance.sql"
)


def test_capture_interval_update_preserves_existing_late_arrival_tolerance():
    sql = MIGRATION.read_text()

    assert "v_late_arrival_tolerance_seconds" in sql
    assert "p.late_arrival_tolerance_seconds" in sql
    assert "COALESCE(v_late_arrival_tolerance_seconds, 60)" in sql

    assert """
        p_capture_interval_seconds,
        clock_timestamp(),
        v_late_arrival_tolerance_seconds
    """ in sql

    assert """
        p_capture_interval_seconds,
        clock_timestamp(),
        900
    """ not in sql
