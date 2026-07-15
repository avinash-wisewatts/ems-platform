-- ============================================================================
-- File: 07_telemetey_archive.sql
-- Schema: telemetry
-- Table : raw_messages
--
-- Purpose:
-- Immutable archive of every telemetry message exactly as received from the
-- ingestion layer.
--
-- This table is intentionally minimal.
-- ============================================================================
CREATE TABLE IF NOT EXISTS telemetry.raw_messages (

    --------------------------------------------------------------------------
    -- Identity
    --------------------------------------------------------------------------

    id BIGINT GENERATED ALWAYS AS IDENTITY,

    received_at TIMESTAMPTZ NOT NULL
        DEFAULT now(),

    --------------------------------------------------------------------------
    -- Original Message Information
    --------------------------------------------------------------------------

    source_timestamp TIMESTAMPTZ,

    source_protocol TEXT NOT NULL,

    source_topic TEXT,

    source_identifier TEXT,

    source_message_id TEXT,

    qos SMALLINT,

    --------------------------------------------------------------------------
    -- Original Payload
    --------------------------------------------------------------------------

    payload JSONB NOT NULL,

    --------------------------------------------------------------------------
    -- Constraints
    --------------------------------------------------------------------------

    PRIMARY KEY (received_at, id)

);

COMMENT ON TABLE telemetry.raw_messages IS
'Immutable archive of every telemetry message received by the platform.';

SELECT create_hypertable(
    'telemetry.raw_messages',
    by_range('received_at'),
    if_not_exists => TRUE
);
