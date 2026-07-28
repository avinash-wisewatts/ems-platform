-- ============================================================================
-- 38_normalized_points_hypertable.sql
--
-- Canonical telemetry store
--
-- One row = one logical point value
--
-- ============================================================================
CREATE TABLE IF NOT EXISTS telemetry.normalized_points
(
    event_time              TIMESTAMPTZ NOT NULL,

    organization_id         UUID NOT NULL,
    site_id                 UUID,
    gateway_id              UUID,
    device_id               UUID NOT NULL,

    logical_point_id        UUID NOT NULL,

    device_uid              TEXT,
    logical_point           TEXT,

    raw_field_name          TEXT,

    raw_value               TEXT,

    numeric_value           NUMERIC,

    quality_code            TEXT,

    mapping_source          TEXT,

    payload                 JSONB,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

SELECT create_hypertable(
    'telemetry.normalized_points',
    'event_time',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_norm_device_time
ON telemetry.normalized_points
(
    device_id,
    event_time DESC
);

CREATE INDEX IF NOT EXISTS idx_norm_lp_time
ON telemetry.normalized_points
(
    logical_point_id,
    event_time DESC
);

CREATE INDEX IF NOT EXISTS idx_norm_org_time
ON telemetry.normalized_points
(
    organization_id,
    event_time DESC
);

ALTER TABLE telemetry.normalized_points
SET (
    timescaledb.compress,
    timescaledb.compress_segmentby =
        'organization_id,device_id,logical_point_id'
);
