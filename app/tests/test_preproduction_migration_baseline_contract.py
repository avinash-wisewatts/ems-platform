from pathlib import Path
import csv

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "postgres/migrations"
BASELINE = MIGRATIONS / "001_ems_platform_baseline_20260807.sql"
MANIFEST = ROOT / "postgres/restructure_manifest.csv"


def test_active_migration_stream_contains_baseline_and_cleanup():
    active = sorted(MIGRATIONS.glob("*.sql"))
    names = [path.name for path in active]

    assert active
    assert active[0] == BASELINE

    numbers = [
        int(name.split("_", 1)[0])
        for name in names
    ]

    # The numeric prefix is a shared namespace with postgres/ddl/ (a
    # migration's canonical mirror, or a ddl-only object, can occupy a
    # number without a corresponding postgres/migrations/ file), so gaps
    # in this directory alone are expected and not a defect. What must
    # still hold: ascending order with no duplicate numeric prefixes.
    assert numbers == sorted(numbers)
    assert len(numbers) == len(set(numbers))

    # These are the post-baseline migrations required by the current
    # live-telemetry and Grafana implementation.
    required = {
        "020_preserve_site_capture_late_arrival_tolerance.sql",
        "021_asset_raw_connectivity_context.sql",
        "022_live_telemetry_state.sql",
        "023_live_telemetry_ingest_ambiguity_fix.sql",
        "024_live_telemetry_app_schema_access.sql",
        "025_live_telemetry_canonical_units.sql",
        "026_live_telemetry_analytics_schema_access.sql",
        "027_reduce_demand_finalization_grace.sql",
        "028_persisted_validated_energy_consumption_1min.sql",
        "029_asset_energy_persisted_read_path.sql",
        "030_fix_5min_total_register_semantics.sql",
        "031_persisted_validated_energy_consumption_5min.sql",
        "032_validated_energy_semantic_rollups.sql",
        "033_energy_semantic_reporting_contract.sql",
        "034_energy_semantic_daily_reporting.sql",
        "035_combined_energy_quality_counters.sql",
        "036_energy_daily_semantic_compatibility_cutover.sql",
        "037_site_timezone_relative_energy_views.sql",
    }

    assert required.issubset(set(names))



def test_historical_migrations_are_recorded_in_manifest():
    with MANIFEST.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    historical = [
        row for row in rows
        if row["target_category"] == "historical_archive"
    ]
    assert len(historical) == 116
    source_files = {row["source_file"] for row in historical}
    assert "179_simplify_device_lifecycle_statuses.sql" in source_files
    assert "178_fix_device_commissioning_guard_null_handling.sql" in source_files

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

    # The manifest is a living forward-migration ledger, not a one-time
    # snapshot: migrations 038+ (including the multi-asset Grafana
    # read-path work and the previously-orphaned 153/170-184 range) are
    # legitimate, expected growth. Assert the structural invariants that
    # must always hold, rather than freezing the exact row list.
    assert migrations
    assert migrations[0]["source_file"] == "001_ems_platform_baseline_20260807.sql"

    source_files = [row["source_file"] for row in migrations]
    assert len(source_files) == len(set(source_files))

    for row in migrations:
        assert row["target_path"] == f"postgres/migrations/{row['source_file']}"
        assert (ROOT / row["target_path"]).exists()

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


def test_contract_tests_do_not_depend_on_archived_files_at_runtime():
    archive_prefix = "/".join(("postgres", "archive", "prebaseline_20260807", "migrations")) + "/"
    offenders = []
    for test_file in (ROOT / "app/tests").glob("test_*.py"):
        if test_file.name == Path(__file__).name:
            continue
        if archive_prefix in test_file.read_text(encoding="utf-8"):
            offenders.append(test_file.name)
    assert offenders == []

def test_test_runner_no_longer_simulates_historical_ledgers():
    script = (ROOT / "scripts/test/apply_test_migrations.sh").read_text()
    assert "--baseline" not in script
    assert "apply_migrations.sh" in script
