from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "036_energy_daily_semantic_compatibility_cutover.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "148_energy_daily_semantic_compatibility_cutover.sql"
)


def test_daily_compatibility_view_is_replaced():
    sql = MIGRATION.read_text()

    assert (
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily"
        in sql
    )


def test_daily_compatibility_uses_semantic_15min_source():
    sql = MIGRATION.read_text()

    assert "analytics.v_energy_reporting_15min" in sql

    forbidden = (
        "analytics.v_energy_consumption_15min",
        "classify_energy_register_delta",
        "resolve_interval_quality_rule",
        "energy_register_semantics",
        "telemetry.ca_energy_",
    )

    for token in forbidden:
        assert token not in sql


def test_valid_interval_counts_are_fully_valid_reporting_buckets():
    sql = MIGRATION.read_text()

    assert "r.valid_import_intervals > 0" in sql
    assert "r.invalid_import_intervals = 0" in sql

    assert "r.valid_export_intervals > 0" in sql
    assert "r.invalid_export_intervals = 0" in sql


def test_gap_and_reset_counts_are_reporting_bucket_counts():
    sql = MIGRATION.read_text()

    assert (
        "WHERE r.reset_interval_count > 0"
        in sql
    )

    assert (
        "WHERE r.gap_interval_count > 0"
        in sql
    )


def test_first_and_last_bucket_preserve_15min_bucket_semantics():
    sql = MIGRATION.read_text()

    assert "min(r.bucket_start)" in sql
    assert "max(r.bucket_start)" in sql

    assert "first_native_bucket_start" not in sql
    assert "last_native_bucket_start" not in sql


def test_daily_uses_site_timezone():
    sql = MIGRATION.read_text()

    assert "metadata.sites s" in sql
    assert "AT TIME ZONE s.timezone" in sql
    assert "Asia/Kolkata" not in sql


def test_exact_consumer_grant_is_preserved():
    sql = MIGRATION.read_text()

    assert (
        "GRANT SELECT\n"
        "ON analytics.v_energy_consumption_daily\n"
        "TO grafana_reader;"
    ) in sql

    assert "TO ems_app" not in sql
    assert "TO ems_readonly" not in sql


def test_security_barrier_is_preserved():
    sql = MIGRATION.read_text()

    assert "WITH (security_barrier = true)" in sql


def test_downstream_views_are_not_replaced_here():
    sql = MIGRATION.read_text()

    forbidden = (
        "CREATE OR REPLACE VIEW analytics.v_asset_consumption_daily",
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_monthly",
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_mtd",
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_today",
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_yesterday",
        "CREATE OR REPLACE VIEW analytics.v_site_energy_balance_daily",
    )

    for token in forbidden:
        assert token not in sql


def test_canonical_mirror_matches():
    assert MIRROR.read_text() == MIGRATION.read_text()
