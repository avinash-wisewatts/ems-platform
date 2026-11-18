-- ============================================================================
-- Migration 322
-- Audit (ADR-024 §16): classify every audit event's actor as a customer user
-- or WiseWatts staff.
--
-- admin.audit_events gains actor_type: 'CUSTOMER' (ORGANIZATION /
-- SELECTED_SITES scope) or 'WISEWATTS_STAFF' (GLOBAL scope -- WiseWatts
-- staff, ADR-023 decision 4). It is derived by a BEFORE INSERT trigger from
-- the actor's admin.portal_users.access_scope_mode at the time of the event,
-- for EVERY insert path (admin.write_audit_event and any other), and any
-- caller-supplied value is overwritten -- the classification can never be
-- chosen by the caller.
--
-- Backward compatible: admin.write_audit_event's signature and body are
-- unchanged; the column is nullable and existing rows stay NULL (their
-- classification at the time is not reconstructed); the column is appended,
-- so functions returning SETOF admin.audit_events gain one trailing field.
--
-- Rollback: DROP TRIGGER audit_events_actor_type_trg; DROP FUNCTION
-- admin.audit_events_set_actor_type(); ALTER TABLE admin.audit_events DROP
-- COLUMN actor_type.
-- ============================================================================

ALTER TABLE admin.audit_events
    ADD COLUMN IF NOT EXISTS actor_type TEXT;

ALTER TABLE admin.audit_events
    DROP CONSTRAINT IF EXISTS audit_events_actor_type_check;
ALTER TABLE admin.audit_events
    ADD CONSTRAINT audit_events_actor_type_check
        CHECK (actor_type IS NULL OR actor_type IN ('CUSTOMER', 'WISEWATTS_STAFF'));

COMMENT ON COLUMN admin.audit_events.actor_type IS
'Migration 322 (ADR-024 §16): CUSTOMER or WISEWATTS_STAFF, derived from the actor''s access_scope_mode (GLOBAL = WiseWatts staff) when the event is written; never supplied by the caller. NULL for events written before migration 322 and for events without an actor.';

CREATE OR REPLACE FUNCTION admin.audit_events_set_actor_type()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
BEGIN
    NEW.actor_type := (
        SELECT CASE WHEN pu.access_scope_mode = 'GLOBAL' THEN 'WISEWATTS_STAFF' ELSE 'CUSTOMER' END
        FROM admin.portal_users AS pu
        WHERE pu.portal_user_id = NEW.actor_portal_user_id
    );
    RETURN NEW;
END;
$function$;

ALTER FUNCTION admin.audit_events_set_actor_type() OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.audit_events_set_actor_type() FROM PUBLIC;

DROP TRIGGER IF EXISTS audit_events_actor_type_trg ON admin.audit_events;
CREATE TRIGGER audit_events_actor_type_trg
    BEFORE INSERT ON admin.audit_events
    FOR EACH ROW
    EXECUTE FUNCTION admin.audit_events_set_actor_type();

COMMENT ON FUNCTION admin.audit_events_set_actor_type() IS
'Migration 322: BEFORE INSERT trigger on admin.audit_events -- sets actor_type from the actor''s access scope (GLOBAL -> WISEWATTS_STAFF, otherwise CUSTOMER; NULL without an actor), overriding any supplied value.';
