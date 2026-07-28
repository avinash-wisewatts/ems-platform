BEGIN;

-- ============================================================================
-- Remove unsafe token-only draft readers
--
-- The FastAPI application now passes the authenticated portal user ID and
-- current role code to the ownership-aware functions.
--
-- The legacy one-argument functions authorized access using only a draft UUID
-- and must no longer remain available to the application role.
-- ============================================================================

REVOKE ALL
ON FUNCTION admin.get_onboarding_draft(uuid)
FROM ems_app;

REVOKE ALL
ON FUNCTION admin.get_onboarding_draft(uuid)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.get_submitted_onboarding_result(uuid)
FROM ems_app;

REVOKE ALL
ON FUNCTION admin.get_submitted_onboarding_result(uuid)
FROM PUBLIC;

DROP FUNCTION admin.get_onboarding_draft(uuid);

DROP FUNCTION admin.get_submitted_onboarding_result(uuid);

COMMIT;
