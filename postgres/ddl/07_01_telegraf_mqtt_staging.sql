-- ============================================================================
-- File: 07_01_telegraf_mqtt_staging.sql
-- Purpose: Insert-only Telegraf compatibility adapter.
--
-- Canonical persisted ingestion path:
--
--   HiveMQ
--      |
--      v
--   Telegraf mqtt_consumer
--      |
--      v
--   public.mqtt_staging              -- compatibility VIEW; stores no rows
--      |
--      v
--   telemetry.capture_telegraf_mqtt_insert()
--      |
--      v
--   telemetry.raw_messages           -- canonical persisted raw hypertable
--
-- Telegraf retains its three-column PostgreSQL output contract:
--   received_at, tags, fields
--
-- The adapter converts that contract into telemetry.raw_messages. It must
-- never be replaced with a persistent staging table.
-- ============================================================================

CREATE OR REPLACE VIEW public.mqtt_staging AS
SELECT
    NULL::TIMESTAMPTZ AS received_at,
    NULL::JSONB       AS tags,
    NULL::JSONB       AS fields
WHERE FALSE;


CREATE OR REPLACE FUNCTION telemetry.capture_telegraf_mqtt_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, telemetry
AS
$$
DECLARE
    v_payload           JSONB;
    v_raw_value         TEXT;
    v_source_identifier TEXT;
    v_source_timestamp  TIMESTAMPTZ;
BEGIN
    v_raw_value := NEW.fields ->> 'value';

    IF v_raw_value IS NOT NULL
       AND pg_input_is_valid(v_raw_value, 'jsonb') THEN
        v_payload := v_raw_value::JSONB;
    ELSE
        v_payload := jsonb_build_object(
            '_capture_status', 'INVALID_JSON',
            '_raw_value', v_raw_value,
            '_fields', COALESCE(NEW.fields, '{}'::JSONB)
        );
    END IF;

    IF jsonb_typeof(v_payload -> 'rtdata') = 'array'
       AND jsonb_array_length(v_payload -> 'rtdata') > 0 THEN

        v_source_identifier :=
            (v_payload -> 'rtdata' -> 0) ->> 'uid';

        IF pg_input_is_valid(
            (v_payload -> 'rtdata' -> 0) ->> 'ts',
            'double precision'
        ) THEN
            v_source_timestamp := to_timestamp(
                ((v_payload -> 'rtdata' -> 0) ->> 'ts')::DOUBLE PRECISION
            );
        END IF;
    END IF;

    INSERT INTO telemetry.raw_messages
    (
        received_at,
        source_timestamp,
        source_protocol,
        source_topic,
        source_identifier,
        source_message_id,
        qos,
        payload
    )
    VALUES
    (
        COALESCE(NEW.received_at, clock_timestamp()),
        v_source_timestamp,
        'MQTT',
        NEW.tags ->> 'topic',
        v_source_identifier,
        NULL,
        NULL,
        v_payload
    );

    RETURN NULL;
END;
$$;


REVOKE ALL
ON FUNCTION telemetry.capture_telegraf_mqtt_insert()
FROM PUBLIC;


DROP TRIGGER IF EXISTS trg_capture_telegraf_mqtt_insert
ON public.mqtt_staging;


CREATE TRIGGER trg_capture_telegraf_mqtt_insert
INSTEAD OF INSERT ON public.mqtt_staging
FOR EACH ROW
EXECUTE FUNCTION telemetry.capture_telegraf_mqtt_insert();


COMMENT ON VIEW public.mqtt_staging IS
'Insert-only Telegraf compatibility adapter. The view stores no rows; its INSTEAD OF INSERT trigger persists messages in telemetry.raw_messages.';

COMMENT ON COLUMN public.mqtt_staging.received_at IS
'Platform receipt timestamp supplied by Telegraf, or replaced with clock_timestamp() when absent.';

COMMENT ON COLUMN public.mqtt_staging.tags IS
'Telegraf tags encoded as JSONB, including the MQTT topic.';

COMMENT ON COLUMN public.mqtt_staging.fields IS
'Telegraf fields encoded as JSONB, including the raw MQTT payload value.';
