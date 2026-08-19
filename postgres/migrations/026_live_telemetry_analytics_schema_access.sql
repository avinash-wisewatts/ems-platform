BEGIN;

GRANT USAGE ON SCHEMA analytics TO ems_app;

GRANT EXECUTE ON FUNCTION
    analytics.get_grafana_asset_live_state(
        bigint,
        uuid,
        timestamptz
    )
TO ems_app;

COMMIT;
