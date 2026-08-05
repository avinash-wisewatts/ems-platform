\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE v_missing text;
BEGIN
  SELECT string_agg(name,', ') INTO v_missing FROM (VALUES
   ('analytics.v_grafana_sites'),('analytics.v_grafana_assets'),('analytics.v_grafana_devices'),
   ('analytics.v_grafana_asset_devices'),('analytics.v_grafana_energy_samples'),
   ('analytics.v_grafana_point_catalog'),('analytics.v_grafana_normalized_points'),
   ('analytics.v_grafana_active_alarms')) x(name)
  WHERE to_regclass(name) IS NULL;
  IF v_missing IS NOT NULL THEN RAISE EXCEPTION 'Missing Grafana MVP views: %',v_missing; END IF;
END $$;
SELECT 'PASS: universal Grafana MVP analytics views exist' AS result;
ROLLBACK;
