-- ============================================================================
-- Coimbatore (Radisson Blu) -- apply the PO-approved retrospective AHU
-- reporting baseline from 1 October 2026 (migration 330, A112).
--
-- STAGING ONLY. A staging WRITE: run only with explicit, per-operation
-- authorization (CLAUDE.md section 4). Never on production (A106).
--
-- Dry run by default: everything is checked and applied inside a transaction
-- that is ROLLED BACK. Commit only with -v confirm=yes:
--
--   docker exec -i ems-timescaledb psql -U ems_admin -d ems -X -v ON_ERROR_STOP=1 \
--       -v actor=1 -v confirm=yes < 330_coimbatore_retrospective_baseline_apply.sql
--
-- What it does: verifies that the 18 AHU setting versions currently in force
-- are exactly the approved baseline (24.0 degC setpoints for Lobby Area AHU-1,
-- Seasons Restaurant AHU-1/-2 and Banquet 2 AHU; Lobby AHUs 05:00-23:00, the
-- other five 06:00-22:00; the approved OFF/ON thresholds; no STANDBY
-- threshold anywhere, including Banquet 1), then copies them unchanged as
-- versions effective 2026-10-01 00:00 Asia/Kolkata, linked to one audited
-- baseline record.
--
-- What it does NOT do: it generates no report, creates no attempt and leaves
-- the weekly/monthly schedules and their resume times unchanged (A114, A115);
-- a postcondition proves it before anything is committed.
-- Historical reports are generated only on an explicit request on the Create
-- report page.
-- ============================================================================

\set ON_ERROR_STOP 1
\if :{?actor}
\else
    \echo 'Set -v actor=<WiseWatts Admin portal_user_id>'
    \quit
\endif

BEGIN;

CREATE TEMP TABLE expected_baseline (asset_name TEXT, setting_key TEXT, value JSONB) ON COMMIT DROP;
INSERT INTO expected_baseline VALUES
    ('Lobby Area AHU-1',         'TEMPERATURE_SETPOINT', '{"value_c": 24.0}'),
    ('Seasons Restaurant AHU-1', 'TEMPERATURE_SETPOINT', '{"value_c": 24.0}'),
    ('Seasons Restaurant AHU-2', 'TEMPERATURE_SETPOINT', '{"value_c": 24.0}'),
    ('Banquet 2 AHU',            'TEMPERATURE_SETPOINT', '{"value_c": 24.0}');
INSERT INTO expected_baseline
SELECT n, 'OPERATING_SCHEDULE', jsonb_build_object(
           'schedule', (SELECT jsonb_object_agg(d, jsonb_build_array(jsonb_build_array(h1, h2)))
                        FROM unnest(ARRAY['Mon','Tue','Wed','Thu','Fri','Sat','Sun']) AS d),
           'confirmed_by_hotel', false, 'calculate_out_of_hours', true)
FROM (VALUES ('Lobby Area AHU-1', '05:00', '23:00'), ('Lobby Area AHU-2', '05:00', '23:00'),
             ('Seasons Restaurant AHU-1', '06:00', '22:00'), ('Seasons Restaurant AHU-2', '06:00', '22:00'),
             ('Banquet 1 AHU', '06:00', '22:00'), ('Banquet 2 AHU', '06:00', '22:00'),
             ('Pre Function Area AHU', '06:00', '22:00')) AS s (n, h1, h2);
INSERT INTO expected_baseline
SELECT n, 'OPERATING_THRESHOLDS', jsonb_build_object('off_kw', off_kw, 'standby_kw', NULL, 'on_kw', on_kw,
                                                     'runtime_enabled', true, 'confidence', conf)
FROM (VALUES ('Lobby Area AHU-1', 0.05, 0.4, 'High'), ('Lobby Area AHU-2', 0.05, 0.4, 'High'),
             ('Seasons Restaurant AHU-1', 0.05, 0.45, 'High'), ('Seasons Restaurant AHU-2', 0.05, 0.45, 'High'),
             ('Banquet 1 AHU', 0.005, 0.6, 'High (ON/OFF)'), ('Banquet 2 AHU', 0.05, 0.85, 'High'),
             ('Pre Function Area AHU', 0.05, 0.8, 'High')) AS t (n, off_kw, on_kw, conf);

CREATE TEMP TABLE current_ahu ON COMMIT DROP AS
SELECT DISTINCT ON (v.asset_id, v.setting_key) v.id, a.name AS asset_name, v.setting_key, v.value
FROM analytics.asset_report_setting_versions AS v
JOIN analytics.site_report_assets AS r ON r.site_id = v.site_id AND r.asset_id = v.asset_id
JOIN metadata.assets AS a ON a.id = v.asset_id
JOIN metadata.sites AS s ON s.id = v.site_id
JOIN metadata.organizations AS o ON o.id = s.organization_id
WHERE s.name = 'Coimbatore' AND o.name = 'Radisson Blu' AND r.report_group = 'HVAC_AHU'
  AND v.state = 'ACTIVE' AND v.effective_from <= clock_timestamp()
ORDER BY v.asset_id, v.setting_key, v.effective_from DESC, v.id DESC;

DO $check$
DECLARE
    v_problems INTEGER;
BEGIN
    SELECT count(*) INTO v_problems FROM (
        (SELECT asset_name, setting_key, value FROM expected_baseline
         EXCEPT SELECT asset_name, setting_key, value FROM current_ahu)
        UNION ALL
        (SELECT asset_name, setting_key, value FROM current_ahu
         EXCEPT SELECT asset_name, setting_key, value FROM expected_baseline)) AS diff;
    IF v_problems > 0 OR (SELECT count(*) FROM current_ahu) <> 18 THEN
        RAISE EXCEPTION 'Refused: the AHU settings in force are not exactly the approved baseline (% differences, % versions).',
            v_problems, (SELECT count(*) FROM current_ahu);
    END IF;
    IF EXISTS (SELECT 1 FROM current_ahu WHERE setting_key = 'OPERATING_THRESHOLDS' AND value -> 'standby_kw' <> 'null'::jsonb) THEN
        RAISE EXCEPTION 'Refused: a STANDBY threshold is configured.';
    END IF;
    RAISE NOTICE 'Check PASS: 18 AHU versions in force equal the approved baseline.';
END;
$check$;

CREATE TEMP TABLE before_state ON COMMIT DROP AS
SELECT (SELECT count(*) FROM analytics.site_reports AS r WHERE r.site_id = s.id) AS reports,
       (SELECT count(*) FROM analytics.site_report_attempts AS a JOIN analytics.site_reports AS r ON r.id = a.report_id
        WHERE r.site_id = s.id) AS attempts,
       (SELECT to_jsonb(p) - 'automation_portal_user_id' FROM analytics.site_report_profiles AS p WHERE p.site_id = s.id) AS profile
FROM metadata.sites AS s JOIN metadata.organizations AS o ON o.id = s.organization_id
WHERE s.name = 'Coimbatore' AND o.name = 'Radisson Blu';

SELECT r.* FROM analytics.apply_site_report_retrospective_baseline(
    :actor,
    (SELECT s.id FROM metadata.sites AS s JOIN metadata.organizations AS o ON o.id = s.organization_id
     WHERE s.name = 'Coimbatore' AND o.name = 'Radisson Blu'),
    DATE '2026-10-01',
    (SELECT array_agg(id ORDER BY id) FROM current_ahu),
    'PO approval 2026-11-21: Create report historical configuration rules change (retrospective AHU baseline)',
    'WiseWatts Product Owner',
    'WiseWatts-approved retrospective reporting baseline: the approved AHU setpoints, operating schedules and '
    'OFF/ON thresholds are treated as in force from 1 October 2026 for reporting. Not independently verified '
    'historical hotel operating practice.'
) AS r;

-- Nothing was generated or scheduled (A114): Coimbatore's reports, attempts
-- and schedule state are exactly as before.
DO $post$
DECLARE
    v_site UUID := (SELECT s.id FROM metadata.sites AS s JOIN metadata.organizations AS o ON o.id = s.organization_id
                    WHERE s.name = 'Coimbatore' AND o.name = 'Radisson Blu');
BEGIN
    IF (SELECT count(*) FROM analytics.site_reports WHERE site_id = v_site) <> (SELECT reports FROM before_state)
       OR (SELECT count(*) FROM analytics.site_report_attempts AS a JOIN analytics.site_reports AS r ON r.id = a.report_id
           WHERE r.site_id = v_site) <> (SELECT attempts FROM before_state)
       OR (SELECT to_jsonb(p) - 'automation_portal_user_id' FROM analytics.site_report_profiles AS p WHERE p.site_id = v_site)
          IS DISTINCT FROM (SELECT profile FROM before_state)
       OR (SELECT count(*) FROM analytics.asset_report_setting_versions
           WHERE site_id = v_site AND retrospective_baseline_id IS NOT NULL) <> 18 THEN
        RAISE EXCEPTION 'Refused: postcondition failed (reports, attempts or schedule changed, or not 18 baseline versions).';
    END IF;
    RAISE NOTICE 'Postcondition PASS: 18 baseline versions; reports, attempts and schedule state unchanged.';
END;
$post$;

\if :{?confirm}
    \if :confirm
        COMMIT;
        \echo 'COMMITTED.'
    \else
        ROLLBACK;
        \echo 'DRY RUN: rolled back.'
    \endif
\else
    ROLLBACK;
    \echo 'DRY RUN: rolled back (pass -v confirm=yes to commit).'
\endif
