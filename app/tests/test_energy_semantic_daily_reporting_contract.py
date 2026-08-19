from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "034_energy_semantic_daily_reporting.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "146_energy_semantic_daily_reporting.sql"
)


def test_semantic_daily_view_exists():
    sql = MIGRATION.read_text()

    assert (
        "CREATE OR REPLACE VIEW analytics.v_energy_reporting_daily"
        in sql
    )


def test_daily_view_is_security_barrier():
    sql = MIGRATION.read_text()

    assert "WITH (security_barrier = true)" in sql


def test_daily_reads_only_semantic_15min_reporting():
    sql = MIGRATION.read_text()

    assert "analytics.v_energy_reporting_15min" in sql

    forbidden = (
        "analytics.classify_energy_register_delta",
        "resolve_interval_quality_rule",
        "energy_register_semantics",
        "telemetry.ca_energy_",
        "analytics.v_energy_consumption_15min",
    )

    for token in forbidden:
        assert token not in sql


def test_daily_uses_site_timezone():
    sql = MIGRATION.read_text()

    assert "metadata.sites s" in sql
    assert "s.timezone AS site_timezone" in sql
    assert "AT TIME ZONE s.timezone" in sql

    assert "Asia/Kolkata" not in sql


def test_daily_preserves_energy_and_quality_counts():
    sql = MIGRATION.read_text()

    required = (
        "valid_import_intervals",
        "invalid_import_intervals",
        "valid_export_intervals",
        "invalid_export_intervals",
        "import_gap_intervals",
        "export_gap_intervals",
        "import_reset_intervals",
        "export_reset_intervals",
        "import_rollover_intervals",
        "export_rollover_intervals",
        "import_consumption_kwh",
        "export_consumption_kwh",
    )

    for token in required:
        assert token in sql


def test_daily_exposes_quality_status():
    sql = MIGRATION.read_text()

    for value in (
        "INVALID_INTERVALS",
        "RESET_DETECTED",
        "GAPS_DETECTED",
        "ROLLOVER_DETECTED",
        "GOOD",
    ):
        assert value in sql


def test_existing_daily_view_is_not_replaced():
    sql = MIGRATION.read_text()

    assert (
        "CREATE OR REPLACE VIEW analytics.v_energy_consumption_daily"
        not in sql
    )


def test_site_balance_is_not_modified():
    sql = MIGRATION.read_text()

    assert "v_site_energy_balance_daily" not in sql


def test_shadow_view_not_exposed_to_consumers():
    sql = MIGRATION.read_text()

    assert "TO grafana_reader" not in sql
    assert "TO ems_app" not in sql
    assert "TO ems_readonly" not in sql


def test_canonical_mirror_matches():
    assert MIRROR.read_text() == MIGRATION.read_text()
