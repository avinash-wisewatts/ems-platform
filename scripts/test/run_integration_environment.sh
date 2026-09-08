#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================"
echo "WiseWatts EMS canonical integration test"
echo "============================================================"

echo
echo "[1/14] Resetting disposable test database..."
"${SCRIPT_DIR}/test_database.sh" reset

echo
echo "[2/14] Deploying canonical database..."
"${SCRIPT_DIR}/deploy_test_database.sh"

echo
echo "[3/14] Running canonical baseline assertions..."
"${SCRIPT_DIR}/assert_canonical_database.sh"

echo
echo "[4/14] Baselining historical migrations and applying forward migrations..."
"${SCRIPT_DIR}/apply_test_migrations.sh"

echo
echo "[5/14] Running energy-register semantic assertions..."
"${SCRIPT_DIR}/assert_energy_register_semantics.sh"

echo
echo "[6/14] Running interval-quality rule assertions..."
"${SCRIPT_DIR}/assert_interval_quality_rules.sh"

echo
echo "[7/14] Running site energy-balance assertions..."
"${SCRIPT_DIR}/assert_site_energy_balance.sh"

echo
echo "[8/14] Running asset hierarchy-rollup assertions..."
"${SCRIPT_DIR}/assert_asset_hierarchy_rollups.sh"

echo
echo "[9/14] Running asset meter-coverage assertions..."
"${SCRIPT_DIR}/assert_asset_meter_coverage.sh"

echo
echo "[10/14] Running controlled lifecycle-status assertions..."
"${SCRIPT_DIR}/assert_controlled_lifecycle_statuses.sh"

echo
echo "[11/14] Running shared tenant/site validation assertions..."
"${SCRIPT_DIR}/assert_shared_tenant_site_validation.sh"

echo
echo "[12/14] Running independent organization-creation assertions..."
"${SCRIPT_DIR}/assert_independent_organization_creation.sh"

echo
echo "[13/14] Running demand-capability resolution assertions..."
"${SCRIPT_DIR}/assert_demand_capability_resolution.sh"

echo
echo
echo "[asset-demand regression] Verifying automatic ASSET demand with SITE demand disabled..."
"${SCRIPT_DIR}/assert_asset_demand_automatic_decoupling.sh"

echo
echo "[connectivity-semantics] Running Phase 1A connectivity semantic contract assertions..."
"${SCRIPT_DIR}/assert_connectivity_semantic_contract.sh"

echo
echo "[energy-consumption-semantics] Running Phase 1B energy consumption semantic contract assertions..."
"${SCRIPT_DIR}/assert_energy_consumption_semantic_contract.sh"

echo
echo "[job-schedule-canonical] Running Phase 1C job-schedule canonical contract assertions..."
"${SCRIPT_DIR}/assert_job_schedule_canonical.sh"

echo
echo "[grafana-energy-routing] Running Phase 1D Grafana energy resolution-routing contract assertions..."
"${SCRIPT_DIR}/assert_grafana_energy_routing_daily_tier.sh"

echo
echo "[energy-consumption-per-flow-quality] Running Phase 1E-A per-flow quality persistence contract assertions..."
"${SCRIPT_DIR}/assert_energy_consumption_per_flow_quality_contract.sh"

echo
echo "[energy-consumption-backfill] Running Phase 1E-B historical backfill contract assertions..."
"${SCRIPT_DIR}/assert_energy_consumption_backfill_contract.sh"

echo
echo "[reference-data-completeness-guard] Running reference-data completeness guard assertions..."
"${SCRIPT_DIR}/assert_reference_data_completeness_guard.sh"

echo
echo "[commissioning-semantic-gate] Running commissioning profile-completeness gate assertions..."
"${SCRIPT_DIR}/assert_commissioning_semantic_gate.sh"

echo
echo "[normalized-points-uniqueness-verification] Running normalized_points uniqueness verification assertions..."
"${SCRIPT_DIR}/assert_normalized_points_uniqueness_verification.sh"

echo
echo "[canonical-energy-read-pre-policy-range] Running canonical energy read pre-policy-range assertions..."
"${SCRIPT_DIR}/assert_canonical_energy_read_pre_policy_range.sh"

echo
echo "[recovery-supersession-late-arrival-bound] Running recovery supersession late-arrival bound assertions..."
"${SCRIPT_DIR}/assert_recovery_supersession_late_arrival_bound.sh"

echo
echo "[recovery-supersession-dense-publisher] Running recovery supersession dense-publisher (migration 220) assertions..."
"${SCRIPT_DIR}/assert_recovery_supersession_dense_publisher.sh"

echo
echo "[recovery-normalized-points-targeted-lookup] Running recovery normalized-points targeted-lookup assertions..."
"${SCRIPT_DIR}/assert_recovery_normalized_points_targeted_lookup.sh"

echo
echo "[recovery-per-candidate-commit] Running recovery per-candidate commit assertions..."
"${SCRIPT_DIR}/assert_recovery_per_candidate_commit.sh"

echo
echo "[normalization-bounded-catchup-window] Running normalization bounded catch-up window assertions..."
"${SCRIPT_DIR}/assert_normalization_bounded_catchup_window.sh"

echo
echo "[energy-environment-routing-bounded-catchup-window] Running energy/environment routing bounded catch-up window assertions..."
"${SCRIPT_DIR}/assert_energy_environment_routing_bounded_catchup_window.sh"

echo
echo "[analytics-job-hardening] Running analytical-tier job hardening assertions..."
"${SCRIPT_DIR}/assert_analytics_job_hardening.sh"

echo
echo "[analytics-job-self-overlap] Running analytical-tier job self-overlap (cross-session) assertions..."
"${SCRIPT_DIR}/assert_analytics_job_self_overlap.sh"

echo
echo "[energy-consumption-cascade-watermarks] Running energy-consumption cascade watermark assertions..."
"${SCRIPT_DIR}/assert_energy_consumption_cascade_watermarks.sh"

echo
echo "[recovery-retention-age-population] Running recovery retention-age population assertions..."
"${SCRIPT_DIR}/assert_recovery_retention_age_population.sh"

echo
echo "[recovery-onboarding-aware-deferral] Running recovery onboarding-aware deferral (migration 218) assertions..."
"${SCRIPT_DIR}/assert_recovery_onboarding_aware_deferral.sh"

echo
echo "[demand-watermark-refinalization] Running demand watermark + re-finalization assertions..."
"${SCRIPT_DIR}/assert_demand_watermark_refinalization.sh"

echo
echo "[environment-daily-watermark] Running environment_daily watermark assertions..."
"${SCRIPT_DIR}/assert_environment_daily_watermark.sh"

echo
echo "[analytical-reconciliation] Running analytical reconciliation layer (migration 213) assertions..."
"${SCRIPT_DIR}/assert_analytical_reconciliation.sh"

echo
echo "[pipeline-health-view] Running analytics.v_pipeline_health (migration 214) assertions..."
"${SCRIPT_DIR}/assert_pipeline_health_view.sh"

echo
echo "[energy-routing-identity-by-name] Running energy-routing metric-identity (migration 215) assertions..."
"${SCRIPT_DIR}/assert_energy_routing_identity_by_name.sh"

echo
echo "[calculated-at-value-aware] Running value-aware calculated_at (migration 216) assertions..."
"${SCRIPT_DIR}/assert_energy_consumption_calculated_at_value_aware.sh"

echo
echo "[hourly-forward-window-utc] Running hourly forward-window UTC-hour alignment (migration 217) assertions..."
"${SCRIPT_DIR}/assert_hourly_forward_window_utc_aligned.sh"

echo
echo "[airsense-environmental-sensor-compatibility] Running Air Sense / Environmental Sensor telemetry-profile compatibility (migration 219) assertions..."
"${SCRIPT_DIR}/assert_airsense_environmental_sensor_compatibility.sh"

echo
echo "[semantic-foundation-parameters] Running Phase 1 semantic foundation (migration 223) parameter/qualifier assertions..."
"${SCRIPT_DIR}/assert_semantic_foundation_parameters.sh"

echo
echo "[asset-space-point-temporal-binding] Running Phase 2 Slice 2A (migration 224) asset_points/space_points temporal binding assertions..."
"${SCRIPT_DIR}/assert_asset_space_point_temporal_binding.sh"

echo "[14/14] Verifying migration ledger..."
ledger="$(
    docker compose \
        -f "${PROJECT_ROOT}/compose.test.yaml" \
        exec -T timescaledb-test \
        psql \
        -X \
        -U ems_admin \
        -d ems_test \
        -tAc "
            SELECT to_regclass('admin.schema_migrations');
        "
)"

if [[ "${ledger}" != "admin.schema_migrations" ]]; then
    echo "ERROR: Migration ledger was not created." >&2
    exit 1
fi

echo "Migration ledger verified: ${ledger}"

echo
echo "============================================================"
echo "Canonical integration-test database is ready."
echo "============================================================"
