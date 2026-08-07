from pathlib import Path
import csv

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "postgres/migrations"
BASELINE = MIGRATIONS / "001_ems_platform_baseline_20260807.sql"
ARCHIVE = ROOT / "postgres/archive/prebaseline_20260807/migrations"
MANIFEST = ROOT / "postgres/restructure_manifest.csv"


def test_active_migration_stream_contains_baseline_and_cleanup():
    active = sorted(MIGRATIONS.glob("*.sql"))

    assert active == [
        BASELINE,
        MIGRATIONS / "002_remove_legacy_telegraf_ingest_objects.sql",
    ]



def test_historical_migrations_are_archived():
    archived = list(ARCHIVE.glob("*.sql"))
    assert len(archived) == 116
    assert (ARCHIVE / "179_simplify_device_lifecycle_statuses.sql").exists()
    assert (ARCHIVE / "178_fix_device_commissioning_guard_null_handling.sql").exists()


def test_manifest_selects_baseline_and_cleanup_migrations():
    with MANIFEST.open(newline="") as handle:
        rows = list(csv.DictReader(handle))

    migrations = [
        row
        for row in rows
        if row["target_category"] == "migration"
    ]

    historical = [
        row
        for row in rows
        if row["target_category"] == "historical_archive"
    ]

    assert [
        row["source_file"]
        for row in migrations
    ] == [
        "001_ems_platform_baseline_20260807.sql",
        "002_remove_legacy_telegraf_ingest_objects.sql",
    ]

    assert [
        row["target_path"]
        for row in migrations
    ] == [
        "postgres/migrations/001_ems_platform_baseline_20260807.sql",
        "postgres/migrations/002_remove_legacy_telegraf_ingest_objects.sql",
    ]

    assert len(historical) == 116



def test_baseline_replays_verified_post_foundation_history():
    sql = BASELINE.read_text()

    assert (
        "Historical migration: "
        "82_admin_hierarchy_lookup_views.sql"
    ) in sql
    assert (
        "Historical migration: "
        "84_onboarding_drafts.sql"
    ) in sql
    assert (
        "Historical migration: "
        "162_site_telemetry_capture_interval_ui_contract.sql"
    ) in sql
    assert (
        "Historical migration: "
        "169_universal_grafana_mvp.sql"
    ) in sql
    assert (
        "Historical migration: "
        "175_device_point_configuration_and_partial_normalization.sql"
    ) in sql
    assert (
        "Historical migration: "
        "178_fix_device_commissioning_guard_null_handling.sql"
    ) in sql
    assert (
        "Historical migration: "
        "179_simplify_device_lifecycle_statuses.sql"
    ) in sql

    assert (
        "Historical migration: "
        "97_mqtt_staging_timestamptz.sql"
    ) not in sql
    assert (
        "Historical migration: "
        "157_relationship_type_config_schema_permission.sql"
    ) not in sql

    assert (
        "DROP TABLE IF EXISTS public.mqtt_staging"
    ) not in sql
    assert (
        "DROP VIEW IF EXISTS public.mqtt_staging"
    ) in sql

    assert "config.device_point_configuration" in sql
    assert "ems.controlled_device_commissioning_id" in sql
    assert "COALESCE(" in sql


def test_historical_contract_tests_use_archive_paths():
    files = [
        "test_device_point_configuration.py",
        "test_device_commissioning_contract.py",
        "test_device_commissioning_experience.py",
        "test_device_lifecycle_cleanup_contract.py",
        "test_commissioning_readiness_contract.py",
    ]
    for filename in files:
        text = (ROOT / "app/tests" / filename).read_text()
        assert "postgres/archive/prebaseline_20260807/migrations/" in text


def test_test_runner_no_longer_simulates_historical_ledgers():
    script = (ROOT / "scripts/test/apply_test_migrations.sh").read_text()
    assert "--baseline" not in script
    assert "apply_migrations.sh" in script
