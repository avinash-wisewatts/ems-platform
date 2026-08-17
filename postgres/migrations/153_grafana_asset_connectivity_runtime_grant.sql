BEGIN;

GRANT EXECUTE ON FUNCTION
analytics.get_grafana_asset_connectivity_context(
    bigint,
    uuid,
    timestamp with time zone
)
TO ems_app;

COMMIT;
