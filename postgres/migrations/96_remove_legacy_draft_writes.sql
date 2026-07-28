BEGIN;

-- ============================================================================
-- Remove unsafe legacy draft write functions
--
-- The FastAPI application now supplies the authenticated portal user ID,
-- current role code, and verified username for every draft save and submission.
--
-- The legacy functions accepted only a draft UUID and actor text, which allowed
-- ownership checks to be bypassed if the UUID was known.
-- ============================================================================

REVOKE ALL
ON FUNCTION admin.save_onboarding_draft_step(
    uuid,
    text,
    jsonb,
    text,
    text
)
FROM ems_app;

REVOKE ALL
ON FUNCTION admin.save_onboarding_draft_step(
    uuid,
    text,
    jsonb,
    text,
    text
)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.submit_onboarding_draft(
    uuid,
    text
)
FROM ems_app;

REVOKE ALL
ON FUNCTION admin.submit_onboarding_draft(
    uuid,
    text
)
FROM PUBLIC;

DROP FUNCTION admin.save_onboarding_draft_step(
    uuid,
    text,
    jsonb,
    text,
    text
);

DROP FUNCTION admin.submit_onboarding_draft(
    uuid,
    text
);

COMMIT;
