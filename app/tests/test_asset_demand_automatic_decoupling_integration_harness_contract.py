from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HARNESS = (ROOT / "scripts/test/run_integration_environment.sh").read_text()
ASSERTION = (ROOT / "scripts/test/assert_asset_demand_automatic_decoupling.sh").read_text()


def test_canonical_integration_harness_runs_asset_demand_decoupling_assertion():
    assert 'assert_asset_demand_automatic_decoupling.sh' in HARNESS


def test_asset_demand_decoupling_fixture_is_rollback_safe():
    assert 'BEGIN;' in ASSERTION
    assert 'ROLLBACK;' in ASSERTION


def test_asset_demand_decoupling_fixture_proves_required_behavior():
    assert "policy_scope = 'ASSET'" in ASSERTION
    assert "'SITE', FALSE, 900, 'ACTIVE_POWER_KW'" in ASSERTION
    assert "'PRIMARY_METER'" in ASSERTION
    assert "'TIME_WEIGHTED_POWER'" in ASSERTION
    assert "CALL analytics.refresh_demand_analytics" in ASSERTION
    assert "scope_type = 'ASSET'" in ASSERTION
    assert "scope_type = 'SITE'" in ASSERTION
    assert "abs(v_current_kw - 12.0)" in ASSERTION
    assert "quality_status = 'VALID'" in ASSERTION
