-- ============================================================================
-- Migration 289
-- Power parameter units: ACTIVE_POWER W -> kW, APPARENT_POWER VA -> kVA,
-- REACTIVE_POWER VAR -> kvar.
--
-- Why (read-only unit-normalization investigation, approved decisions):
--   * config.parameters.unit_id is the unit the Analytics catalogue reports
--     (analytics.get_portal_analytics_catalog, migration 288:
--     COALESCE(parameter unit, logical point unit)). For these three
--     parameters it disagreed with every logical point of the parameter
--     (kW / kVA / kvar), with live telemetry (migration 025 scales the
--     Eniscope W / VA / var source values to the logical-point unit) and
--     with the customer-facing power surfaces (Demand, Asset Power Trend,
--     Grafana: kW). Migrations 223 / 254 had chosen the base units.
--   * The customer-facing unit of each is now its logical-point unit.
--
-- Scope (metadata only):
--   * Writes ONLY config.parameters.unit_id (and updated_at) of the three
--     rows. Logical-point units, every other parameter (Energy Import /
--     Export stay kWh; Power Factor stays unitless), config.engineering_units
--     (W / VA / VAR rows are kept) and the table's owner / grants are
--     asserted unchanged below.
--   * No telemetry is touched. telemetry.normalized_points and the point
--     tiers keep the raw source values (W / VA / var for Eniscope);
--     converting them to the reported unit is the Analytics read layer's
--     job (B3), from the profile / device field-mapping scale, exactly as
--     live telemetry does. No historical data is rewritten.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Preconditions and before-snapshots (transaction-local).
-- ----------------------------------------------------------------------------

CREATE TEMP TABLE m289_targets ON COMMIT DROP AS
SELECT *
FROM (VALUES
    ('ACTIVE_POWER',   'W',   'kW'),
    ('APPARENT_POWER', 'VA',  'kVA'),
    ('REACTIVE_POWER', 'VAR', 'kvar')
) AS t(code, from_unit, to_unit);

CREATE TEMP TABLE m289_parameters_before ON COMMIT DROP AS
SELECT p.*
FROM config.parameters AS p;

CREATE TEMP TABLE m289_logical_point_units_before ON COMMIT DROP AS
SELECT lp.id, lp.unit_id
FROM metadata.logical_points AS lp;

CREATE TEMP TABLE m289_units_before ON COMMIT DROP AS
SELECT eu.*
FROM config.engineering_units AS eu;

CREATE TEMP TABLE m289_acl_before ON COMMIT DROP AS
SELECT c.relowner, c.relacl::TEXT AS relacl
FROM pg_class AS c
WHERE c.oid = 'config.parameters'::regclass;

DO $pre$
DECLARE
    r RECORD;
    v_unit TEXT;
    v_lp_units TEXT[];
BEGIN
    FOR r IN SELECT * FROM m289_targets LOOP
        SELECT eu.symbol INTO v_unit
        FROM config.parameters AS p
        LEFT JOIN config.engineering_units AS eu ON eu.id = p.unit_id
        WHERE p.code = r.code;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Migration 289 precondition failed: parameter % does not exist.', r.code;
        END IF;
        IF v_unit IS DISTINCT FROM r.from_unit THEN
            RAISE EXCEPTION 'Migration 289 precondition failed: parameter % unit is %, expected %.', r.code, v_unit, r.from_unit;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM config.engineering_units WHERE symbol = r.to_unit) THEN
            RAISE EXCEPTION 'Migration 289 precondition failed: engineering unit % does not exist.', r.to_unit;
        END IF;

        -- The new unit must be exactly the unit of every logical point of the
        -- parameter (the catalogue then agrees with live telemetry).
        SELECT array_agg(DISTINCT COALESCE(eu.symbol, '<none>') ORDER BY COALESCE(eu.symbol, '<none>'))
        INTO v_lp_units
        FROM metadata.logical_points AS lp
        JOIN config.parameters AS p ON p.id = lp.parameter_id
        LEFT JOIN config.engineering_units AS eu ON eu.id = lp.unit_id
        WHERE p.code = r.code;
        IF v_lp_units IS DISTINCT FROM ARRAY[r.to_unit] THEN
            RAISE EXCEPTION 'Migration 289 precondition failed: logical points of % have units %, expected only %.', r.code, v_lp_units, r.to_unit;
        END IF;
    END LOOP;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 2. The three unit corrections.
-- ----------------------------------------------------------------------------

UPDATE config.parameters AS p
SET unit_id = eu.id,
    updated_at = now()
FROM m289_targets AS t
JOIN config.engineering_units AS eu ON eu.symbol = t.to_unit
WHERE p.code = t.code;


-- ----------------------------------------------------------------------------
-- 3. Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_bad TEXT;
    v_count INTEGER;
BEGIN
    SELECT string_agg(t.code || '=' || COALESCE(eu.symbol, '<none>'), ', ') INTO v_bad
    FROM m289_targets AS t
    JOIN config.parameters AS p ON p.code = t.code
    LEFT JOIN config.engineering_units AS eu ON eu.id = p.unit_id
    WHERE eu.symbol IS DISTINCT FROM t.to_unit;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 289 postcondition failed: wrong unit(s): %', v_bad;
    END IF;

    -- Only unit_id / updated_at of the three rows changed; every other
    -- column of those rows and every other parameter row is identical.
    SELECT count(*) INTO v_count
    FROM m289_parameters_before AS b
    LEFT JOIN config.parameters AS a ON a.id = b.id
    WHERE b.code NOT IN (SELECT code FROM m289_targets)
      AND to_jsonb(b) IS DISTINCT FROM to_jsonb(a);
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Migration 289 postcondition failed: % other parameter row(s) changed.', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM m289_parameters_before AS b
    JOIN config.parameters AS a ON a.id = b.id
    WHERE b.code IN (SELECT code FROM m289_targets)
      AND (to_jsonb(b) - 'unit_id' - 'updated_at') IS DISTINCT FROM (to_jsonb(a) - 'unit_id' - 'updated_at');
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Migration 289 postcondition failed: % target parameter row(s) changed beyond unit_id.', v_count;
    END IF;

    SELECT count(*) INTO v_count FROM config.parameters;
    IF v_count <> (SELECT count(*) FROM m289_parameters_before) THEN
        RAISE EXCEPTION 'Migration 289 postcondition failed: config.parameters row count changed.';
    END IF;

    -- Energy stays kWh; Power Factor stays unitless.
    SELECT string_agg(p.code || '=' || COALESCE(eu.symbol, '<none>'), ', ') INTO v_bad
    FROM config.parameters AS p
    LEFT JOIN config.engineering_units AS eu ON eu.id = p.unit_id
    WHERE (p.code IN ('ENERGY_IMPORT', 'ENERGY_EXPORT') AND eu.symbol IS DISTINCT FROM 'kWh')
       OR (p.code = 'POWER_FACTOR' AND p.unit_id IS NOT NULL);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 289 postcondition failed: unexpected unit(s): %', v_bad;
    END IF;

    -- Logical-point units untouched.
    SELECT count(*) INTO v_count
    FROM m289_logical_point_units_before AS b
    FULL JOIN metadata.logical_points AS lp ON lp.id = b.id
    WHERE b.id IS NULL OR lp.id IS NULL OR lp.unit_id IS DISTINCT FROM b.unit_id;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Migration 289 postcondition failed: % logical point unit(s) changed.', v_count;
    END IF;

    -- Engineering units untouched (W / VA / VAR are kept).
    SELECT count(*) INTO v_count
    FROM m289_units_before AS b
    FULL JOIN config.engineering_units AS eu ON eu.id = b.id
    WHERE b.id IS NULL OR eu.id IS NULL OR to_jsonb(b) IS DISTINCT FROM to_jsonb(eu);
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Migration 289 postcondition failed: config.engineering_units changed.';
    END IF;

    -- Owner and grants of config.parameters unchanged.
    IF NOT EXISTS (
        SELECT 1
        FROM pg_class AS c, m289_acl_before AS b
        WHERE c.oid = 'config.parameters'::regclass
          AND c.relowner = b.relowner
          AND c.relacl::TEXT IS NOT DISTINCT FROM b.relacl
    ) THEN
        RAISE EXCEPTION 'Migration 289 postcondition failed: owner or grants of config.parameters changed.';
    END IF;

    RAISE NOTICE 'Migration 289: all postconditions passed (ACTIVE_POWER kW, APPARENT_POWER kVA, REACTIVE_POWER kvar; logical-point units, other parameters, engineering units, owner and grants unchanged).';
END;
$post$;
