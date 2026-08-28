-- ============================================================================
-- File:
--   scripts/maintenance/refresh_energy_caggs_215.sql
--
-- Purpose:
--   After scripts/maintenance/backfill_energy_measurements_electrical_215.sql
--   has filled the previously-NULL electrical columns of
--   telemetry.energy_measurements, re-materialise the continuous aggregates
--   that read those columns so their power/reactive/apparent aggregates catch
--   up for the recovery window.
--
--   TimescaleDB 2.29.2: refresh_continuous_aggregate() CANNOT run inside a
--   transaction block. Run each statement below AT TOP LEVEL, one at a time,
--   and check the CAGG after each. This file is a runbook, not an atomic
--   script -- do NOT wrap it in BEGIN/COMMIT and do NOT pipe it blindly.
--
--   Only the power/reactive/apparent columns of these CAGGs were affected;
--   their import/export energy (Wh) columns were always correct. Re-refreshing
--   the bounded window is safe and idempotent.
--
--   Recovery window: [ '2026-08-28 01:00:00+05:30' , <a recent closed bucket> )
--   Round the lower bound DOWN to the coarsest affected bucket (1 hour) so the
--   hourly/daily CAGGs fully recompute the boundary bucket.
--
--   DO NOT trigger any TimescaleDB job, alter_job, or run_job. These are
--   direct top-level refresh calls only. Not for production without separate
--   authorization.
-- ============================================================================

\set ON_ERROR_STOP on
\pset pager off

\set win_from '2026-08-28 01:00:00+05:30'
-- Override at invocation:  -v win_to="2026-08-28 12:00:00+05:30"
\if :{?win_to}
\else
  \echo 'ERROR: pass -v win_to="<recent closed bucket timestamptz>"'
  \quit 1
\endif

-- Finest first, then up the rollup chain. Run these ONE AT A TIME.

CALL public.refresh_continuous_aggregate('telemetry.ca_energy_1min',              :'win_from'::timestamptz, :'win_to'::timestamptz);
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_5min',              :'win_from'::timestamptz, :'win_to'::timestamptz);
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_15min',             :'win_from'::timestamptz, :'win_to'::timestamptz);
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_hourly',            :'win_from'::timestamptz, :'win_to'::timestamptz);
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_daily',             :'win_from'::timestamptz, :'win_to'::timestamptz);

CALL public.refresh_continuous_aggregate('telemetry.ca_energy_phase_power_1min',  :'win_from'::timestamptz, :'win_to'::timestamptz);
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_phase_power_5min',  :'win_from'::timestamptz, :'win_to'::timestamptz);
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_phase_power_15min', :'win_from'::timestamptz, :'win_to'::timestamptz);
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_phase_power_hourly',:'win_from'::timestamptz, :'win_to'::timestamptz);
CALL public.refresh_continuous_aggregate('telemetry.ca_energy_phase_power_daily', :'win_from'::timestamptz, :'win_to'::timestamptz);

-- After each CALL, sanity check, e.g.:
--   SELECT max(bucket_start),
--          count(*) FILTER (WHERE active_power_l1_w_avg IS NOT NULL) AS have_ap_l1
--   FROM telemetry.ca_energy_phase_power_1min
--   WHERE bucket_start >= :'win_from'::timestamptz AND bucket_start < :'win_to'::timestamptz;
