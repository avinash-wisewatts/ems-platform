from pathlib import Path

SQL = Path("postgres/migrations/003_telemetry_pipeline_performance_state.sql").read_text()
CANONICAL = Path("postgres/ddl/122_telemetry_pipeline_performance_state.sql").read_text()


def test_forward_migration_matches_canonical_layer():
    assert SQL == CANONICAL


def test_normalized_payload_is_removed_and_lineage_added():
    assert "ADD COLUMN IF NOT EXISTS raw_message_id BIGINT" in SQL
    assert "DROP COLUMN IF EXISTS payload" in SQL
    assert "np.raw_message_id" in SQL
    assert "payload,\n    raw_message_id" in SQL
    durable_insert = SQL.split("INSERT INTO telemetry.normalized_points", 1)[1].split("GET DIAGNOSTICS", 1)[0]
    assert "payload" not in durable_insert


def test_failure_quarantine_is_preserved():
    assert "telemetry.raw_message_failures" in SQL
    assert "INTERVAL '30 days'" in SQL
    assert "np.raw_message_id = r.id" in SQL
    assert "jsonb_build_array(np.payload)" not in SQL


def test_admin_state_no_longer_scans_normalized_history():
    availability = SQL.split("CREATE OR REPLACE VIEW analytics.v_device_telemetry_availability", 1)[1]
    availability = availability.split("CREATE OR REPLACE VIEW analytics.v_gateway_connectivity", 1)[0]
    assert "telemetry.device_telemetry_state" in availability
    assert "telemetry.normalized_points" not in availability

    readiness = SQL.split("CREATE OR REPLACE VIEW analytics.v_commissioning_readiness", 1)[1]
    assert "telemetry.device_point_state" in readiness
    assert "LEFT JOIN telemetry.normalized_points" not in readiness


def test_routing_uses_receipt_watermark_with_bounded_replay():
    assert "p_overlap := LEAST(p_overlap, INTERVAL '1 minute')" in SQL
    assert "np.platform_received_at > v_window_start" in SQL
    assert "np.event_time >= v_now - p_overlap - INTERVAL '15 minutes'" not in SQL


def test_manifest_keeps_122_as_canonical_mirror():
    import csv
    manifest = Path("postgres/restructure_manifest.csv")
    with manifest.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    row = next(r for r in rows if r["source_file"] == "122_telemetry_pipeline_performance_state.sql")
    assert row["target_category"] == "canonical_mirror"


def test_payload_drop_removes_full_resolution_view_dependency_first():
    view_marker = "CREATE OR REPLACE VIEW telemetry.v_energy_measurements_full_resolution AS"
    drop_marker = "DROP COLUMN IF EXISTS payload"
    assert view_marker in SQL
    assert SQL.index(view_marker) < SQL.index(drop_marker)
    block = SQL.split(view_marker, 1)[1].split(drop_marker, 1)[0]
    assert "SELECT np.*" not in block
    assert "np.platform_received_at" in block
    assert "np.raw_message_id" in block


def test_payload_drop_has_catalog_dependency_guard():
    guard = "Refusing to drop telemetry.normalized_points.payload; remaining dependencies"
    assert guard in SQL
    assert "pg_catalog.pg_depend" in SQL
    assert SQL.index(guard) < SQL.index("DROP COLUMN IF EXISTS payload")
