-- ============================================================================
-- Energy parity capture (release-plan precheck P5 / G2, and B1 before/after).
-- READ-ONLY.
--
-- Calls analytics.get_canonical_energy_read (the Grafana Energy read) for
-- every asset with a PRIMARY_METER device, at each requested resolution,
-- over one fixed range, and prints one fingerprint line per (asset,
-- resolution). Run it before and after a release with the same variables and
-- compare the two outputs with energy_parity_compare.py.
--
-- Nothing is written: no temporary table (a read-only transaction forbids
-- CREATE). The loop is one DO block; each call runs in its own
-- subtransaction, so one failing asset is reported (PARITY_ERROR) and the
-- capture continues.
--
-- Choose a range the forward jobs can no longer rewrite, or a forward
-- re-derivation between the two captures shows up as a false mismatch: the
-- range must end before now() minus the longest forward reconcile_window
-- (production 2026-10-19: run_energy_consumption_daily_job 21 days). Keep the
-- reconcilers (1114-1120 on production) in the same state for both captures.
--
-- Variables (all required):
--   label        free text written to every line, e.g. b1_pre
--   from_ts      range start (timestamptz literal)
--   to_ts        range end, exclusive
--   resolutions  comma-separated subset of native,5m,15m,1h,1d
--   max_assets   cap on assets (use 1 for a first timing probe)
--   timeout      statement_timeout for the whole capture, e.g. 300s
--
-- Run (production only with explicit authorization), through the read-only
-- session settings (default_transaction_read_only=on):
--   psql -X -v ON_ERROR_STOP=1 -v label=b1_pre \
--     -v from_ts='2026-09-23 18:30+00' -v to_ts='2026-09-27 18:30+00' \
--     -v resolutions=1d -v max_assets=56 -v timeout=300s \
--     -f scripts/diagnostics/energy_parity_capture.sql > b1_pre.txt 2>&1
--
-- Output lines ('|'-separated; NOTICE prefix stripped by the comparator):
--   CAPTURE|label|from|to|resolutions|started_utc|read_fn_md5|assets
--   PARITY|label|asset_id|grafana_org_id|res|rows|import_kwh|export_kwh|values_md5|full_md5|ms
--   PARITY_ERROR|label|asset_id|res|sqlstate|message
--   CAPTURE_END|label|calls|errors|total_ms
-- values_md5 covers interval bounds, consumption and quality status per row;
-- full_md5 covers every returned column.
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on
SET application_name = 'ems_energy_parity_capture';
SET lock_timeout = '2s';
SET statement_timeout = :'timeout';
SET client_min_messages = notice;
SET parity.label       = :'label';
SET parity.from_ts     = :'from_ts';
SET parity.to_ts       = :'to_ts';
SET parity.resolutions = :'resolutions';
SET parity.max_assets  = :'max_assets';
SHOW default_transaction_read_only;

BEGIN READ ONLY;

DO $capture$
DECLARE
    v_label   TEXT        := current_setting('parity.label');
    v_from    TIMESTAMPTZ := current_setting('parity.from_ts')::TIMESTAMPTZ;
    v_to      TIMESTAMPTZ := current_setting('parity.to_ts')::TIMESTAMPTZ;
    v_res     TEXT[]      := string_to_array(replace(current_setting('parity.resolutions'), ' ', ''), ',');
    v_max     INTEGER     := current_setting('parity.max_assets')::INTEGER;
    v_fn_md5  TEXT;
    v_assets  INTEGER;
    v_start   TIMESTAMPTZ := clock_timestamp();
    v_t0      TIMESTAMPTZ;
    v_calls   INTEGER := 0;
    v_errs    INTEGER := 0;
    r         RECORD;
    res       TEXT;
    a         RECORD;
BEGIN
    IF v_to <= v_from THEN
        RAISE EXCEPTION 'to_ts (%) must be after from_ts (%)', v_to, v_from;
    END IF;
    IF NOT v_res <@ ARRAY['native', '5m', '15m', '1h', '1d'] THEN
        RAISE EXCEPTION 'resolutions must be a subset of native,5m,15m,1h,1d, got %', v_res;
    END IF;

    -- Fingerprint of the read function itself, so the two captures show
    -- whether the release replaced it.
    SELECT md5(string_agg(p.prosrc, '' ORDER BY p.oid)) INTO v_fn_md5
    FROM pg_proc p
    WHERE p.oid = 'analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)'::regprocedure;

    SELECT count(*) INTO v_assets
    FROM (
        SELECT DISTINCT ad.asset_id
        FROM metadata.asset_devices AS ad
        JOIN metadata.assets AS a2 ON a2.id = ad.asset_id
        JOIN metadata.grafana_organization_map AS g
          ON g.organization_id = a2.organization_id AND g.is_active
        WHERE ad.relationship_type = 'PRIMARY_METER'
        LIMIT v_max
    ) AS x;

    RAISE NOTICE 'CAPTURE|%|%|%|%|%|%|%', v_label,
        to_char(v_from AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        to_char(v_to   AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        array_to_string(v_res, ','),
        to_char(v_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        v_fn_md5, v_assets;

    -- Same asset set and order on every run: PRIMARY_METER assets of an
    -- active Grafana organization, by asset id; lowest active Grafana org id.
    FOR a IN
        SELECT ad.asset_id, min(g.grafana_org_id) AS grafana_org_id
        FROM metadata.asset_devices AS ad
        JOIN metadata.assets AS a2 ON a2.id = ad.asset_id
        JOIN metadata.grafana_organization_map AS g
          ON g.organization_id = a2.organization_id AND g.is_active
        WHERE ad.relationship_type = 'PRIMARY_METER'
        GROUP BY ad.asset_id
        ORDER BY ad.asset_id
        LIMIT v_max
    LOOP
        FOREACH res IN ARRAY v_res LOOP
            v_calls := v_calls + 1;
            v_t0 := clock_timestamp();
            BEGIN
                SELECT count(*) AS n,
                       sum(e.import_consumption_kwh) AS imp,
                       sum(e.export_consumption_kwh) AS exp,
                       md5(coalesce(string_agg(
                           concat_ws('|', e.interval_start, e.interval_end, e.resolution,
                                     e.import_consumption_kwh, e.export_consumption_kwh,
                                     e.import_quality_status, e.export_quality_status),
                           ',' ORDER BY e.interval_start, e.resolution), '')) AS values_md5,
                       md5(coalesce(string_agg(e::TEXT, ',' ORDER BY e.interval_start, e.resolution), '')) AS full_md5
                INTO r
                FROM analytics.get_canonical_energy_read(a.grafana_org_id, a.asset_id, v_from, v_to, res, 'native') AS e;

                RAISE NOTICE 'PARITY|%|%|%|%|%|%|%|%|%|%', v_label, a.asset_id, a.grafana_org_id, res,
                    r.n, coalesce(r.imp::TEXT, ''), coalesce(r.exp::TEXT, ''), r.values_md5, r.full_md5,
                    round(extract(epoch FROM clock_timestamp() - v_t0) * 1000);
            EXCEPTION WHEN query_canceled THEN
                RAISE;  -- statement_timeout: stop the whole capture
            WHEN OTHERS THEN
                v_errs := v_errs + 1;
                RAISE NOTICE 'PARITY_ERROR|%|%|%|%|%', v_label, a.asset_id, res, SQLSTATE,
                    replace(left(SQLERRM, 200), '|', '/');
            END;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'CAPTURE_END|%|%|%|%', v_label, v_calls, v_errs,
        round(extract(epoch FROM clock_timestamp() - v_start) * 1000);
END
$capture$;

ROLLBACK;
