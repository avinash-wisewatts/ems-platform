-- Migration 289 assertions: power parameter units match their logical points.
-- Read-only.

DO $assert$
DECLARE
    v_bad TEXT;
BEGIN
    -- 1. The three corrected parameters.
    SELECT string_agg(e.code || ' expected ' || e.unit || ' got ' || COALESCE(eu.symbol, '<none>'), '; ') INTO v_bad
    FROM (VALUES ('ACTIVE_POWER', 'kW'), ('APPARENT_POWER', 'kVA'), ('REACTIVE_POWER', 'kvar'),
                 ('ENERGY_IMPORT', 'kWh'), ('ENERGY_EXPORT', 'kWh')) AS e(code, unit)
    LEFT JOIN config.parameters AS p ON p.code = e.code
    LEFT JOIN config.engineering_units AS eu ON eu.id = p.unit_id
    WHERE eu.symbol IS DISTINCT FROM e.unit;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'assert_power_parameter_units: %', v_bad;
    END IF;

    -- 2. Power Factor stays unitless.
    IF EXISTS (SELECT 1 FROM config.parameters WHERE code = 'POWER_FACTOR' AND unit_id IS NOT NULL) THEN
        RAISE EXCEPTION 'assert_power_parameter_units: POWER_FACTOR must stay unitless';
    END IF;

    -- 3. Every logical point of the power and energy parameters has its
    --    parameter's unit (the catalogue unit agrees with live telemetry).
    SELECT string_agg(DISTINCT p.code || ': parameter ' || COALESCE(pu.symbol, '<none>') || ' vs logical point ' || COALESCE(lu.symbol, '<none>'), '; ')
    INTO v_bad
    FROM metadata.logical_points AS lp
    JOIN config.parameters AS p ON p.id = lp.parameter_id
    LEFT JOIN config.engineering_units AS pu ON pu.id = p.unit_id
    LEFT JOIN config.engineering_units AS lu ON lu.id = lp.unit_id
    WHERE p.code IN ('ACTIVE_POWER', 'APPARENT_POWER', 'REACTIVE_POWER', 'ENERGY_IMPORT', 'ENERGY_EXPORT')
      AND pu.symbol IS DISTINCT FROM lu.symbol;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'assert_power_parameter_units: %', v_bad;
    END IF;

    -- 4. The base units are kept (nothing deleted from the unit catalogue).
    IF (SELECT count(*) FROM config.engineering_units WHERE symbol IN ('W', 'VA', 'VAR')) <> 3 THEN
        RAISE EXCEPTION 'assert_power_parameter_units: W / VA / VAR engineering units must be kept';
    END IF;

    -- 5. Recorded once in the ledger.
    IF (SELECT count(*) FROM admin.schema_migrations WHERE migration_id = '289_power_parameter_units') <> 1 THEN
        RAISE EXCEPTION 'assert_power_parameter_units: migration 289 is not recorded exactly once';
    END IF;

    RAISE NOTICE 'assert_power_parameter_units: all assertions passed';
END;
$assert$;
