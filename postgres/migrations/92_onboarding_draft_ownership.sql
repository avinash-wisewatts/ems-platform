BEGIN;

-- ============================================================================
-- Stable onboarding draft ownership
--
-- requested_by currently stores a username string and has historically been
-- updated when a draft is saved. It is useful as an audit-friendly actor
-- snapshot, but it is not a stable ownership key because usernames can change.
--
-- owner_portal_user_id identifies the human portal account that created and
-- owns the draft. Existing historical and test drafts may remain NULL when no
-- matching portal account exists.
-- ============================================================================

ALTER TABLE admin.onboarding_drafts
ADD COLUMN IF NOT EXISTS owner_portal_user_id bigint;

COMMENT ON COLUMN admin.onboarding_drafts.owner_portal_user_id IS
    'Stable portal-user identity that owns the onboarding draft. '
    'NULL is permitted for historical drafts created before authenticated '
    'ownership enforcement or when the original portal account was deleted.';

-- Backfill drafts where the recorded username still matches an existing portal
-- account. Historical actors such as portal-v0.3, manual-test, and deleted test
-- users intentionally remain NULL.
UPDATE admin.onboarding_drafts AS draft
SET owner_portal_user_id = portal_user.portal_user_id
FROM admin.portal_users AS portal_user
WHERE draft.owner_portal_user_id IS NULL
  AND lower(btrim(draft.requested_by)) = portal_user.username;

-- Add the foreign key only when it does not already exist. ON DELETE SET NULL
-- preserves draft and audit history if a portal account is later removed.
DO $block$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname =
            'onboarding_drafts_owner_portal_user_id_fkey'
          AND conrelid =
            'admin.onboarding_drafts'::regclass
    ) THEN
        ALTER TABLE admin.onboarding_drafts
        ADD CONSTRAINT onboarding_drafts_owner_portal_user_id_fkey
        FOREIGN KEY (owner_portal_user_id)
        REFERENCES admin.portal_users(portal_user_id)
        ON DELETE SET NULL;
    END IF;
END;
$block$;

-- Supports ownership-filtered draft lookup and future draft listing.
CREATE INDEX IF NOT EXISTS ix_onboarding_drafts_owner_status_updated
ON admin.onboarding_drafts
(
    owner_portal_user_id,
    status,
    updated_at DESC
);

COMMIT;
