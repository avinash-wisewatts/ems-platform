from pathlib import Path

SQL = Path(
    "postgres/migrations/"
    "002_remove_legacy_telegraf_ingest_objects.sql"
).read_text()


def test_legacy_telegraf_objects_are_removed():
    assert (
        "DROP FUNCTION IF EXISTS "
        "telemetry.get_logical_point(TEXT, TEXT)"
    ) in SQL

    assert (
        "DROP TABLE IF EXISTS "
        "telemetry.telegraf_ingest"
    ) in SQL

    assert (
        "telemetry.telegraf_ingest_id_seq "
        "still exists after cleanup"
    ) in SQL


def test_cleanup_refuses_to_drop_nonempty_table():
    assert (
        "SELECT count(*) FROM "
        "telemetry.telegraf_ingest"
    ) in SQL

    assert (
        "Refusing to remove telemetry.telegraf_ingest"
    ) in SQL
