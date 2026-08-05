-- RETIRED PROTOTYPE FILE — DO NOT EXECUTE.
-- This file is retained only for historical reference. Use
-- scripts/deploy_database.sh and docs/operations/TELEMETRY_PIPELINE.md.

-- ============================================================================
-- WiseWatts EMS
-- Phase 6
--
-- Canonical Energy Meter View
-- ============================================================================
CREATE OR REPLACE VIEW telemetry.v_energy_meter AS

SELECT

    received_at,

    to_timestamp((payload->>'ts')::double precision) AS event_time,

    payload->>'uid' AS device_uid,

    (payload->>'did')::int AS device_id,

    (payload->>'P')::double precision AS active_power_kw,

    (payload->>'Q')::double precision AS reactive_power_kvar,

    (payload->>'S')::double precision AS apparent_power_kva,

    (payload->>'PF')::double precision AS power_factor,

    (payload->>'E')::double precision AS import_energy_kwh,

    (payload->>'AE')::double precision AS export_energy_kwh,

    (payload->>'U1')::double precision AS voltage_l1,

    (payload->>'U2')::double precision AS voltage_l2,

    (payload->>'U3')::double precision AS voltage_l3,

    (payload->>'I1')::double precision AS current_l1,

    (payload->>'I2')::double precision AS current_l2,

    (payload->>'I3')::double precision AS current_l3,

    payload

FROM telemetry.v_rtdata

WHERE payload ? 'P';
