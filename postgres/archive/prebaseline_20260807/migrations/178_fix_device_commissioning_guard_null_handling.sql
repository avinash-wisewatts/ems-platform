-- Fix NULL handling in the controlled device activation guard.
-- A missing transaction-local commissioning token must fail closed.

CREATE OR REPLACE FUNCTION metadata.reject_uncommissioned_active_device()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.lifecycle_status = 'ACTIVE'
       AND (
           TG_OP = 'INSERT'
           OR OLD.lifecycle_status IS DISTINCT FROM 'ACTIVE'
       )
       AND NOT (
           current_user = 'ems_admin'
           AND COALESCE(
               current_setting(
                   'ems.controlled_device_commissioning_id',
                   TRUE
               ),
               ''
           ) = NEW.id::text
       )
    THEN
        RAISE EXCEPTION
            'Use the controlled commissioning action to activate a device.'
            USING ERRCODE = '22023';
    END IF;

    RETURN NEW;
END;
$function$;

ALTER FUNCTION metadata.reject_uncommissioned_active_device()
    OWNER TO ems_admin;
