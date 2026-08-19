BEGIN;

GRANT USAGE ON SCHEMA telemetry TO ems_app;

GRANT EXECUTE
ON FUNCTION telemetry.ingest_live_rtdata(
    TEXT,
    JSONB,
    TIMESTAMPTZ
)
TO ems_app;

COMMIT;
