-- ============================================================================
-- File: 23_views.sql
-- Purpose: Canonical telemetry parsing views.
--
-- Architectural role:
--   telemetry.raw_messages
--          |
--          v
--   telemetry.v_rtdata
--          |
--          v
--   telemetry.v_normalized_points
--
-- Design requirements:
--   - Raw MQTT landing data remains unchanged.
--   - One rtdata array element becomes one relational row.
--   - Missing or malformed JSON payloads must not break downstream queries.
--   - This file contains canonical view definitions, not migration history.
-- ============================================================================


-- ============================================================================
-- VIEW: telemetry.v_rtdata
-- ============================================================================
--
-- Expected canonical raw-message structure:
--
--   telemetry.raw_messages.payload = {
--       "rtdata": [...]
--   }
--
-- Output:
--   One row per element in the rtdata JSON array.
--
-- Invalid input handling:
--   - Invalid Telegraf JSON is preserved by the adapter as a diagnostic object.
--   - Payloads without an rtdata array are excluded.
--   - A malformed device timestamp becomes NULL rather than failing the view.
-- ============================================================================

CREATE OR REPLACE VIEW telemetry.v_rtdata AS

WITH messages_with_rtdata AS
(
    SELECT
        received_at,
        source_topic,
        payload

    FROM telemetry.raw_messages

    WHERE jsonb_typeof(payload -> 'rtdata') = 'array'
)

SELECT
    m.received_at,

    m.source_topic AS mqtt_topic,

    r.value ->> 'uid' AS device_uid,

    r.value ->> 'did' AS device_identifier,

    CASE
        WHEN r.value ->> 'ts' IS NULL
            THEN NULL::TIMESTAMPTZ

        WHEN pg_input_is_valid(
            r.value ->> 'ts',
            'double precision'
        )
            THEN to_timestamp(
                (r.value ->> 'ts')::DOUBLE PRECISION
            )

        ELSE NULL::TIMESTAMPTZ
    END AS source_timestamp,

    r.value AS payload

FROM messages_with_rtdata m

CROSS JOIN LATERAL jsonb_array_elements(
    m.payload -> 'rtdata'
) AS r(value);

-- ============================================================================
-- VIEW: telemetry.v_energy_meter
-- ============================================================================
--
-- Compatibility contract:
--   This legacy parsing view is retained for existing engineering queries.
--   New production routing must use telemetry.v_normalized_points and the
--   domain-specific telemetry.energy_measurements table.
-- ============================================================================

CREATE OR REPLACE VIEW telemetry.v_energy_meter AS

SELECT
    received_at,

    to_timestamp(
        (payload ->> 'ts')::DOUBLE PRECISION
    ) AS event_time,

    payload ->> 'uid' AS device_uid,

    (payload ->> 'did')::INTEGER AS device_id,

    (payload ->> 'P')::DOUBLE PRECISION AS active_power_kw,
    (payload ->> 'Q')::DOUBLE PRECISION AS reactive_power_kvar,
    (payload ->> 'S')::DOUBLE PRECISION AS apparent_power_kva,
    (payload ->> 'PF')::DOUBLE PRECISION AS power_factor,
    (payload ->> 'E')::DOUBLE PRECISION AS import_energy_kwh,
    (payload ->> 'AE')::DOUBLE PRECISION AS export_energy_kwh,

    (payload ->> 'U1')::DOUBLE PRECISION AS voltage_l1,
    (payload ->> 'U2')::DOUBLE PRECISION AS voltage_l2,
    (payload ->> 'U3')::DOUBLE PRECISION AS voltage_l3,

    (payload ->> 'I1')::DOUBLE PRECISION AS current_l1,
    (payload ->> 'I2')::DOUBLE PRECISION AS current_l2,
    (payload ->> 'I3')::DOUBLE PRECISION AS current_l3,

    payload

FROM telemetry.v_rtdata

WHERE payload ? 'P';


COMMENT ON VIEW telemetry.v_energy_meter IS
'Legacy Eniscope energy parsing compatibility view. New integrations should use the normalized telemetry contract.';

