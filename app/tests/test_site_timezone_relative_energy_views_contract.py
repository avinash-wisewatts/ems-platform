from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "037_site_timezone_relative_energy_views.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "149_site_timezone_relative_energy_views.sql"
)


def test_relative_views_are_replaced():
    sql = MIGRATION.read_text()

    for view in (
        "v_energy_consumption_today",
        "v_energy_consumption_yesterday",
        "v_energy_consumption_mtd",
    ):
        assert f"CREATE OR REPLACE VIEW analytics.{view}" in sql


def test_views_use_daily_semantic_compatibility_source():
    sql = MIGRATION.read_text()

    assert "analytics.v_energy_consumption_daily c" in sql


def test_site_timezone_is_used():
    sql = MIGRATION.read_text()

    assert "JOIN metadata.sites s" in sql
    assert "AT TIME ZONE s.timezone" in sql
    assert "Asia/Kolkata" not in sql


def test_today_uses_site_local_date():
    sql = MIGRATION.read_text()

    assert (
        "(now() AT TIME ZONE s.timezone)::date"
        in sql
    )


def test_yesterday_uses_site_local_date_minus_one():
    sql = MIGRATION.read_text()

    assert (
        "(now() AT TIME ZONE s.timezone)::date - 1"
        in sql
    )


def test_mtd_uses_site_local_month_boundary():
    sql = MIGRATION.read_text()

    assert "date_trunc(" in sql
    assert "'month'" in sql
    assert "now() AT TIME ZONE s.timezone" in sql


def test_existing_column_contract_is_preserved():
    sql = MIGRATION.read_text()

    required = (
        "grafana_org_id",
        "organization_id",
        "site_id",
        "device_id",
        "external_id",
        "device_name",
        "import_consumption_kwh",
        "export_consumption_kwh",
        "valid_import_intervals",
        "valid_export_intervals",
        "reset_interval_count",
        "gap_interval_count",
        "first_bucket_start",
        "last_bucket_start",
    )

    for token in required:
        assert token in sql


def test_security_contract_is_preserved():
    sql = MIGRATION.read_text()

    assert sql.count("WITH (security_barrier = true)") == 3
    assert "TO grafana_reader;" in sql


def test_energy_is_not_reclassified():
    sql = MIGRATION.read_text()

    forbidden = (
        "classify_energy_register_delta",
        "resolve_interval_quality_rule",
        "energy_register_semantics",
        "telemetry.ca_energy_",
        "v_energy_consumption_15min",
    )

    for token in forbidden:
        assert token not in sql


def test_site_kpis_are_not_replaced():
    sql = MIGRATION.read_text()

    assert (
        "CREATE OR REPLACE VIEW "
        "analytics.v_energy_consumption_site_kpis"
        not in sql
    )


def test_canonical_mirror_matches():
    assert MIRROR.read_text() == MIGRATION.read_text()
