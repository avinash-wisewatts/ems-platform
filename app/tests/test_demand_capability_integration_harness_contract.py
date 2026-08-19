from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HARNESS = (ROOT / "scripts/test/run_integration_environment.sh").read_text()
ASSERTION = (ROOT / "scripts/test/assert_demand_capability_resolution.sh").read_text()


def test_canonical_integration_harness_runs_demand_capability_assertions():
    assert 'assert_demand_capability_resolution.sh' in HARNESS


def test_demand_capability_matrix_covers_vendor_neutral_resolution_cases():
    for expected in (
        "ENERGY_COUNTER_DELTA",
        "TIME_WEIGHTED_POWER",
        "METER_NATIVE",
        "BASIS_NOT_SUPPORTED",
        "SOURCE_POINT_NOT_ENABLED",
        "INVALID_DEMAND_BASIS",
        "INVALID_DEMAND_INTERVAL",
    ):
        assert expected in ASSERTION


def test_demand_capability_matrix_is_rollback_safe():
    assert "BEGIN;" in ASSERTION
    assert "ROLLBACK;" in ASSERTION
    assert "COMMIT;" not in ASSERTION
