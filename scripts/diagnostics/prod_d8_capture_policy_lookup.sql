-- ============================================================================
-- Decision D8 evidence: identify the site of production capture policy 5
-- (300 s capture + 30 s tolerance) and when / how the policy was set. READ-ONLY.
--
-- Small metadata reads only (sites, organizations, gateways, devices, capture
-- policies, admin.onboarding_audit filtered by the site); no telemetry hypertable is
-- read. One READ ONLY transaction, ROLLBACK at the end.
-- Production: run only with explicit authorization, via the read-only helper.
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '10s';
SET LOCAL lock_timeout = '1s';
SHOW transaction_read_only;

\echo === site and organization
SELECT s.id, s.name, s.code, s.timezone, o.name AS organization, o.code AS org_code
FROM metadata.sites s
JOIN metadata.organizations o ON o.id = s.organization_id
WHERE s.id = '49500fb9-0ea9-4496-8eeb-55131c89d0c2';

\echo === capture policies of the site (all, incl. history)
SELECT p.id, p.capture_interval_seconds, p.late_arrival_tolerance_seconds, p.alignment_mode,
       p.effective_from, p.effective_to, p.is_enabled, p.created_at, p.updated_at
FROM config.telemetry_capture_policies p
WHERE p.site_id = '49500fb9-0ea9-4496-8eeb-55131c89d0c2'
ORDER BY p.effective_from;

\echo === gateways and devices of the site
SELECT g.name AS gateway, g.external_id, count(d.id) AS devices,
       string_agg(DISTINCT dp.profile_code, ', ') AS profiles
FROM metadata.gateways g
LEFT JOIN metadata.devices d ON d.gateway_id = g.id
LEFT JOIN config.device_profiles dp ON dp.id = d.profile_id
WHERE g.site_id = '49500fb9-0ea9-4496-8eeb-55131c89d0c2'
GROUP BY g.name, g.external_id
ORDER BY g.name;

\echo === onboarding audit entries mentioning the site (if the table exists)
SELECT to_regclass('admin.onboarding_audit') IS NOT NULL AS has_onboarding_audit \gset
\if :has_onboarding_audit
SELECT a.created_at, a.requested_by,
       COALESCE(a.request_payload ->> 'operation', 'ONBOARD') AS operation,
       a.request_payload -> 'site' ->> 'mode' AS site_mode,
       a.request_payload -> 'site' ->> 'telemetry_capture_interval_seconds' AS requested_capture_s,
       a.result_payload ->> 'device_external_id' AS device,
       a.request_payload -> 'organization' ->> 'description' AS org_description
FROM admin.onboarding_audit a
WHERE a.request_payload::text LIKE '%49500fb9-0ea9-4496-8eeb-55131c89d0c2%'
   OR a.result_payload::text LIKE '%49500fb9-0ea9-4496-8eeb-55131c89d0c2%'
ORDER BY a.created_at
LIMIT 50;
\endif

ROLLBACK;
