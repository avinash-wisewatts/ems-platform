-- Remove production drift from the retired Telegraf bridge ingestion path.
--
-- The active MQTT ingestion path writes to telemetry.raw_messages.
-- public.mqtt_staging is a compatibility view, not a persistent landing table.

DO
$block$
DECLARE
    v_row_count BIGINT;
BEGIN
    IF to_regclass('telemetry.telegraf_ingest') IS NOT NULL THEN
        EXECUTE
            'SELECT count(*) FROM telemetry.telegraf_ingest'
        INTO v_row_count;

        IF v_row_count <> 0 THEN
            RAISE EXCEPTION
                'Refusing to remove telemetry.telegraf_ingest because it contains % rows',
                v_row_count;
        END IF;
    END IF;
END
$block$;

DROP FUNCTION IF EXISTS telemetry.get_logical_point(TEXT, TEXT);

DROP TABLE IF EXISTS telemetry.telegraf_ingest;

DO
$block$
BEGIN
    IF to_regclass('telemetry.telegraf_ingest') IS NOT NULL THEN
        RAISE EXCEPTION
            'telemetry.telegraf_ingest still exists after cleanup';
    END IF;

    IF to_regprocedure(
        'telemetry.get_logical_point(text,text)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'telemetry.get_logical_point(text,text) still exists after cleanup';
    END IF;

    IF to_regclass(
        'telemetry.telegraf_ingest_id_seq'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'telemetry.telegraf_ingest_id_seq still exists after cleanup';
    END IF;
END
$block$;
