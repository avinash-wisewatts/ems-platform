-- =============================================================================
-- WiseWatts EMS
-- Telegraf landing-to-staging bridge
--
-- Data flow:
--
--   Telegraf
--      |
--      v
--   telemetry.telegraf_ingest
--      |
--      | AFTER INSERT trigger
--      v
--   telemetry.mqtt_staging
--
-- Durability behavior:
--   * Valid JSON is stored as native JSONB.
--   * Invalid JSON never blocks Telegraf ingestion.
--   * Invalid payload text is preserved inside an error envelope for later
--     inspection, replay, or firmware-parser remediation.
--
-- Security behavior:
--   * Telegraf has INSERT only on telemetry.telegraf_ingest.
--   * The trigger function executes with its owner's privileges.
--   * search_path is fixed to prevent object-shadowing attacks.
-- =============================================================================

CREATE OR REPLACE FUNCTION telemetry.forward_telegraf_ingest_to_mqtt_staging()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, telemetry
AS $$
DECLARE
    parsed_payload jsonb;
BEGIN
    -- Attempt to preserve the MQTT message as structured JSON.
    BEGIN
        parsed_payload := NEW.value::jsonb;
    EXCEPTION
        WHEN invalid_text_representation THEN
            -- Preserve malformed messages losslessly instead of rejecting the
            -- Telegraf transaction and causing repeated retry/backpressure.
            parsed_payload := jsonb_build_object(
                '_ingest_status', 'INVALID_JSON',
                '_raw_value', NEW.value
            );
    END;

    INSERT INTO telemetry.mqtt_staging (
        received_at,
        topic,
        qos,
        payload
    )
    VALUES (
        NEW.received_at,
        NEW.topic,
        NULL,
        parsed_payload
    );

    RETURN NEW;
END;
$$;

REVOKE ALL
ON FUNCTION telemetry.forward_telegraf_ingest_to_mqtt_staging()
FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_forward_telegraf_ingest
ON telemetry.telegraf_ingest;

CREATE TRIGGER trg_forward_telegraf_ingest
AFTER INSERT
ON telemetry.telegraf_ingest
FOR EACH ROW
EXECUTE FUNCTION telemetry.forward_telegraf_ingest_to_mqtt_staging();

COMMENT ON FUNCTION telemetry.forward_telegraf_ingest_to_mqtt_staging() IS
'Transfers Telegraf MQTT landing rows into telemetry.mqtt_staging while preserving malformed JSON losslessly.';

COMMENT ON TRIGGER trg_forward_telegraf_ingest
ON telemetry.telegraf_ingest IS
'Declarative handoff from Telegraf landing rows to canonical MQTT staging.';
