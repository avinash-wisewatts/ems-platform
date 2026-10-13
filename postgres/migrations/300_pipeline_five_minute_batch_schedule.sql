-- ============================================================================
-- Migration 300
-- Coordinated 5-minute batch schedule for the ingest pipeline (staging
-- optimization plan, run 18, decision D-018). Schedule only.
--
-- Six jobs move from "every minute" to "every 5 minutes, fixed schedule",
-- phased (seconds after each UTC 5-minute boundary) so each stage runs after
-- the stage it reads from has committed:
--
--   stage                               job (staging)  reads                   phase
--   telemetry.run_normalization_job          1000      raw_messages            +2:40
--   telemetry.run_energy_routing_job         1001      normalized_points       +4:10
--   telemetry.run_environment_routing_job    1012      normalized_points       +4:15
--   refresh telemetry.ca_energy_1min         1060      energy_measurements     +4:40
--   refresh ca_energy_phase_power_1min       1085      energy_measurements     +4:45
--   analytics.run_energy_consumption_1min_job 1079     ca_energy_1min          +5:00 (= +0:00)
--
-- WHY THESE PHASES
--   * Normalization finalizes a capture bucket only after its deadline
--     (bucket_start + capture_interval + late_arrival_tolerance; 60 + 60 s on
--     every active staging site) and selects the newest sample received by
--     that deadline; the first selection is final (capture_bucket_samples
--     ON CONFLICT DO NOTHING). A run at +2:40 therefore finalizes exactly the
--     five 1-minute buckets that started at -4:00 .. +0:00, with 40 s of
--     margin after the last deadline (+2:00) -- the same margin as today's
--     :41.6 phase.
--   * The demand job (1078, migration 298: :07/:22/:37/:52 UTC, UNCHANGED)
--     finalizes interval [E-15, E) only when the source frontier
--     LEAST(max energy_measurements.bucket_start, max normalized_points.
--     event_time) has reached E, i.e. once the bucket starting AT E is
--     normalized AND routed. That bucket's deadline is E+2:00, so
--     normalization must run between E+2:00 and the routing slot, and
--     routing must commit before E+7:00. +2:40 / +4:10 meets both, and a
--     failed normalization run is retried after its 1-minute retry_period
--     (~E+3:40) before routing runs. Any earlier normalization phase (< ~2:10)
--     would push every demand interval 15 minutes later.
--   * Routing 90 s after normalization (5-minute batch measured ~1-3 s) also
--     removes today's race in which 1001 starts 0.5 s after 1000 and routes
--     the previous minute's batch (energy lag 2 m 46 s vs environment 1 m
--     47 s, measured 2026-10-13).
--   * ca_energy_1min's watermark is data-driven; refreshing after routing and
--     then running 1079 makes the 1-minute tier take the whole batch at once.
--     The 15-minute job (1099, :x2:28 / :x7:28, UNCHANGED) gates on
--     LEAST(cp_1min, cp_5min): cp_1min reaches E at E+5:00, before its E+7:28
--     run; cp_5min (1080 / 1063, UNCHANGED) already makes E+7:28 the
--     earliest 15-minute finalization today, so the 15-minute, hourly, daily
--     and alert-materiality tiers keep their current latency.
--
-- CORRECTNESS (unchanged by cadence; see the PR and
-- scripts/test/assert_pipeline_five_minute_batch.sh)
--   * Normalization output is cadence-independent: deadline-gated selection
--     from raw rows received by the deadline; every run rescans
--     checkpoint - max(capture_interval + tolerance, overlap) (16 min today),
--     so a bucket whose deadline falls between runs is still in the next
--     window. One 5-minute run == five 1-minute runs.
--   * Routing windows on platform_received_at > checkpoint - 1 minute
--     (unchanged); rows are committed per normalization batch in deadline
--     order, so the replay margin is the same at any cadence. Upserts are
--     per key (ON CONFLICT), idempotent.
--   * Checkpoints, advisory locks, max_window (2 h per run), max_runtime,
--     max_retries 3 / retry_period 1 min (5 min for 1079) and every job
--     config are unchanged. Catch-up: 2 h of backlog per 5-minute run
--     (24x real time; 48 h raw retention drains in <= 2 h).
--
-- FRESHNESS (estimates; measure after deploy)
--   normalized: bucket end + 1:40 .. 5:40 (today ~1:41)
--   energy / environment measurements: + 3:10 .. 7:10 (today ~2:42 / ~1:47)
--   1-minute consumption tier: + 4:00 .. 8:00 (today ~3:00)
--   15-min / hourly / daily / alert materiality / demand: unchanged
--   normalized-data freshness state: needs migration 299 (600 s threshold)
--
-- NOT CHANGED: procedure bodies, job configs, every other job -- notably
-- 1076 (raw receipt state, 1 minute), 1127 (alerts, 1 minute; its 3-minute
-- gap tolerance requires it), 1078 (demand), 1080 / 1063 (5-minute tier, its
-- checkpoint gates the 15-minute tier), 1099, 1068, reconcilers.
--
-- Rollback (no data component; values printed by the NOTICEs below):
--   1000 / 1001 / 1012 / 1079: alter_job(id, schedule_interval => '1 minute',
--     fixed_schedule => true, initial_start => <previous initial_start>,
--     next_start => <next minute + previous second offset>)
--   1060 / 1085: alter_job(id, schedule_interval => '1 minute',
--     fixed_schedule => false)
--   Checkpoints make the order irrelevant: the next runs catch up.
-- ============================================================================

CREATE TEMP TABLE m300_targets (
    label     text PRIMARY KEY,
    phase_s   integer NOT NULL,
    job_id    integer
) ON COMMIT DROP;

INSERT INTO m300_targets (label, phase_s) VALUES
    ('normalization',        160),
    ('energy_routing',       250),
    ('environment_routing',  255),
    ('ca_energy_1min',       280),
    ('ca_energy_phase_1min', 285),
    ('consumption_1min',       0);

DO $pre$
DECLARE
    t         RECORD;
    v_n       integer;
    v_job     integer;
    v_bad     text;
BEGIN
    FOR t IN SELECT label FROM m300_targets LOOP
        SELECT count(*), min(j.job_id) INTO v_n, v_job
        FROM timescaledb_information.jobs AS j
        WHERE CASE t.label
            WHEN 'normalization'        THEN j.proc_schema = 'telemetry' AND j.proc_name = 'run_normalization_job'
            WHEN 'energy_routing'       THEN j.proc_schema = 'telemetry' AND j.proc_name = 'run_energy_routing_job'
            WHEN 'environment_routing'  THEN j.proc_schema = 'telemetry' AND j.proc_name = 'run_environment_routing_job'
            WHEN 'ca_energy_1min'       THEN j.proc_name = 'policy_refresh_continuous_aggregate'
                                         AND j.hypertable_schema = 'telemetry' AND j.hypertable_name = 'ca_energy_1min'
            WHEN 'ca_energy_phase_1min' THEN j.proc_name = 'policy_refresh_continuous_aggregate'
                                         AND j.hypertable_schema = 'telemetry' AND j.hypertable_name = 'ca_energy_phase_power_1min'
            WHEN 'consumption_1min'     THEN j.proc_schema = 'analytics' AND j.proc_name = 'run_energy_consumption_1min_job'
        END;
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'Migration 300: expected exactly one % job, found %', t.label, v_n;
        END IF;
        UPDATE m300_targets SET job_id = v_job WHERE label = t.label;
    END LOOP;

    -- The reviewed starting point: every target runs every minute.
    SELECT string_agg(format('%s (job %s) every %s', m.label, m.job_id, j.schedule_interval), ', ') INTO v_bad
    FROM m300_targets m JOIN timescaledb_information.jobs j ON j.job_id = m.job_id
    WHERE j.schedule_interval <> INTERVAL '1 minute';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 300: expected 1-minute schedules, found: %', v_bad;
    END IF;

    -- The demand job's quarter-hour + 7 min slot (migration 298) is what the
    -- normalization / routing phases are fitted to.
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs j
        WHERE j.proc_schema = 'analytics' AND j.proc_name = 'run_demand_calculation_job'
          AND j.schedule_interval = INTERVAL '15 minutes' AND j.fixed_schedule
          AND extract(epoch FROM j.initial_start)::bigint % 900 = 420
    ) THEN
        RAISE EXCEPTION 'Migration 300: the demand job is not on the 15-minute :07/:22/:37/:52 schedule (migration 298); phases would not fit';
    END IF;

    -- The normalized-data freshness threshold must cover the batch cadence.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'config' AND table_name = 'telemetry_availability_policy'
          AND column_name = 'normalized_receiving_threshold_seconds'
    ) OR EXISTS (
        SELECT 1 FROM config.telemetry_availability_policy
        WHERE policy_key = 'DEFAULT' AND normalized_receiving_threshold_seconds < 480
    ) THEN
        RAISE EXCEPTION 'Migration 300: normalized-data freshness threshold missing or below 480 s (migration 299); portal freshness would flap STALE';
    END IF;

    -- Site capture policies slower than 60 + 60 s finalize their boundary
    -- bucket after the +2:40 slot: data still flows, one cycle later.
    SELECT string_agg(format('policy %s: %s + %s s', p.id, p.capture_interval_seconds, p.late_arrival_tolerance_seconds), ', ')
      INTO v_bad
    FROM config.telemetry_capture_policies p
    WHERE p.is_enabled AND p.site_id IS NOT NULL AND p.effective_to IS NULL
      AND p.capture_interval_seconds + p.late_arrival_tolerance_seconds > 120;
    IF v_bad IS NOT NULL THEN
        RAISE WARNING 'Migration 300: site capture policies with interval + tolerance > 120 s finalize their 5-minute-boundary bucket one batch later (+5 min): %', v_bad;
    END IF;
END
$pre$;

-- Snapshot of every job's schedule-relevant settings, to prove only the six
-- targets changed (and only their schedule).
CREATE TEMP TABLE m300_before ON COMMIT DROP AS
SELECT j.job_id, j.schedule_interval, j.fixed_schedule, j.initial_start, j.scheduled,
       j.max_runtime, j.max_retries, j.retry_period, j.config,
       j.check_schema, j.check_name, j.proc_schema, j.proc_name
FROM timescaledb_information.jobs AS j;

DO $sched$
DECLARE
    v_origin CONSTANT timestamptz := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_every  CONSTANT interval    := INTERVAL '5 minutes';
    v_grid   timestamptz := date_bin(INTERVAL '5 minutes', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_start  timestamptz;
    t        RECORD;
BEGIN
    FOR t IN
        SELECT m.label, m.job_id, m.phase_s, b.fixed_schedule, b.initial_start, s.next_start
        FROM m300_targets m
        JOIN m300_before b ON b.job_id = m.job_id
        LEFT JOIN timescaledb_information.job_stats s ON s.job_id = m.job_id
        ORDER BY m.phase_s
    LOOP
        -- Next slot on this job's phase that is not before now(); the grid
        -- origin keeps every slot at <boundary> + phase in UTC.
        v_start := v_grid + make_interval(secs => t.phase_s);
        IF v_start < now() THEN
            v_start := v_start + v_every;
        END IF;

        PERFORM alter_job(
            t.job_id,
            schedule_interval => v_every,
            fixed_schedule    => TRUE,
            initial_start     => v_start,
            next_start        => v_start
        );

        RAISE NOTICE 'Migration 300: job % (%) every 5 minutes at +%s, first run %; previous: every 1 minute, fixed_schedule %, initial_start %, next_start %',
            t.job_id, t.label, t.phase_s, v_start, t.fixed_schedule, t.initial_start, t.next_start;
    END LOOP;
END
$sched$;

DO $post$
DECLARE
    v_bad text;
BEGIN
    -- Targets: 5 minutes, fixed, on their phase; nothing else changed.
    SELECT string_agg(format('%s (job %s)', m.label, m.job_id), ', ') INTO v_bad
    FROM m300_targets m
    JOIN timescaledb_information.jobs j ON j.job_id = m.job_id
    JOIN m300_before b ON b.job_id = m.job_id
    WHERE j.schedule_interval <> INTERVAL '5 minutes'
       OR NOT j.fixed_schedule
       OR extract(epoch FROM j.initial_start)::bigint % 300 <> m.phase_s
       OR (j.scheduled, j.max_runtime, j.max_retries, j.retry_period, j.config, j.check_schema, j.check_name)
          IS DISTINCT FROM
          (b.scheduled, b.max_runtime, b.max_retries, b.retry_period, b.config, b.check_schema, b.check_name);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 300: target job settings wrong after alter_job: %', v_bad;
    END IF;

    -- Every other job (including demand 1078, receipt state 1076, alerts
    -- 1127, the 5-minute tier 1080) is untouched.
    SELECT string_agg(format('job %s (%s.%s)', b.job_id, b.proc_schema, b.proc_name), ', ') INTO v_bad
    FROM m300_before b
    JOIN timescaledb_information.jobs j ON j.job_id = b.job_id
    WHERE b.job_id NOT IN (SELECT job_id FROM m300_targets)
      AND (j.schedule_interval, j.fixed_schedule, j.initial_start, j.scheduled, j.max_runtime,
           j.max_retries, j.retry_period, j.config, j.check_schema, j.check_name)
          IS DISTINCT FROM
          (b.schedule_interval, b.fixed_schedule, b.initial_start, b.scheduled, b.max_runtime,
           b.max_retries, b.retry_period, b.config, b.check_schema, b.check_name);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 300: non-target jobs changed: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs) <> (SELECT count(*) FROM m300_before) THEN
        RAISE EXCEPTION 'Migration 300: the number of jobs changed';
    END IF;
END
$post$;
