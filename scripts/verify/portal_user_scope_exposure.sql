-- Read-only. Migration 315 cross-tenant exposure + forensic check (docs/10-operations/portal-user-provisioning.md).
-- Run: docker exec -i ems-timescaledb sh -c 'psql -X -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < scripts/verify/portal_user_scope_exposure.sql
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '5s';
SET LOCAL lock_timeout = '1s';

\echo '== 1. Who could exploit it: active ADMINs with a non-GLOBAL scope (count > 0 = exploitable)'
SELECT role_code, access_scope_mode, is_active, count(*) AS users
FROM admin.portal_users
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

\echo '== 2. Has it happened: scope changes that moved a user out of GLOBAL or across organizations'
\echo '   (actor_scope_now = GLOBAL rows are legitimate staff changes; anything else needs review)'
SELECT a.created_at,
       a.actor_portal_user_id,
       act.access_scope_mode AS actor_scope_now,
       a.target_portal_user_id,
       a.event_payload->>'previous_access_scope_mode' AS prev_scope,
       a.event_payload->>'new_access_scope_mode'      AS new_scope,
       a.event_payload->>'previous_organization_id'   AS prev_org,
       a.event_payload->>'new_organization_id'        AS new_org
FROM admin.portal_user_audit a
JOIN admin.portal_users act ON act.portal_user_id = a.actor_portal_user_id
WHERE a.event_type = 'USER_SCOPE_CHANGED'
  AND (a.event_payload->>'previous_access_scope_mode' = 'GLOBAL'
       OR (a.event_payload->>'previous_organization_id')
          IS DISTINCT FROM (a.event_payload->>'new_organization_id'))
ORDER BY a.created_at DESC
LIMIT 200;

ROLLBACK;
