-- ============================================================================
-- Migration 268
-- Late/recovered Energy reconstruction -- FOUNDATIONS ONLY (ADR-020, PR1).
--
-- Approved product rule (ADR-020): every valid register delta from a valid
-- meter must ultimately be reflected in Energy history; a cumulative-meter
-- delta that spans a gap is distributed across the gap's native slots --
-- guided by in-gap ACTIVE_POWER_TOTAL where available, time-weighted
-- otherwise -- and the allocation sums EXACTLY to the measured delta.
-- The existing 1,000,000 Wh plausibility limit is unchanged.
--
-- This migration adds only inert building blocks. It changes NO existing
-- behavior:
--
--   1. Additive reconstruction columns on analytics.energy_consumption_1min
--      and analytics.energy_consumption_5min. Every existing row receives
--      the defaults (is_reconstructed = FALSE, every other new column NULL)
--      at ADD COLUMN time. No existing function, view, job, or API reads or
--      writes these columns; every existing INSERT into these tables names
--      its columns explicitly (proved by app/tests/test_energy_
--      reconstruction_foundations.py), so none is affected.
--
--   2. Two IMMUTABLE pure functions -- analytics.energy_gap_weights and
--      analytics.allocate_energy_delta -- that later slices will call. They
--      touch no table.
--
--   3. config.energy_reconstruction_scope + config.energy_reconstruction_
--      enabled(): the switch that later slices must consult. Seeded with a
--      single GLOBAL row, is_enabled = FALSE. Nothing consults it yet.
--
-- Explicitly NOT in this migration (later ADR-020 slices): any change to
-- refresh_energy_consumption_1min/5min, rollup/reporting views, persisted
-- 15m/hourly/daily tiers, reconciliation, APIs, routing, repair queue or
-- jobs; no reconstructed row is ever written; no historical repair; no job
-- registration or activation.
--
-- Per-direction columns: import and export registers are classified
-- independently today (import_/export_ column pairs), and a gap can exist
-- in one direction only; the allocation method can also differ per
-- direction (ADR-020: export is time-weighted until the exported-power sign
-- convention is verified). Reconstruction metadata is therefore stored per
-- direction, with one row-level is_reconstructed summary flag.
--
-- CHECK constraints are added NOT VALID. Every pre-existing row holds the
-- column defaults, which satisfy every constraint by construction, so a
-- validation scan (a full read of ~277 MB of mostly compressed data on
-- staging under the migration's ACCESS EXCLUSIVE lock, blocking the 1-min
-- Energy job) proves nothing. NOT VALID constraints are still enforced for
-- every row inserted or updated after this migration.
--
-- Rollback (not run here): DROP FUNCTION analytics.allocate_energy_delta,
-- analytics.energy_gap_weights, config.energy_reconstruction_enabled; DROP
-- TABLE config.energy_reconstruction_scope; ALTER TABLE ... DROP
-- CONSTRAINT / DROP COLUMN for the columns below on both tables.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Additive reconstruction columns (1-minute and 5-minute native tiers).
-- ----------------------------------------------------------------------------

DO $cols$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['energy_consumption_1min', 'energy_consumption_5min']
    LOOP
        EXECUTE format($sql$
            ALTER TABLE analytics.%1$I
                ADD COLUMN IF NOT EXISTS is_reconstructed               BOOLEAN NOT NULL DEFAULT FALSE,
                ADD COLUMN IF NOT EXISTS import_reconstruction_role     TEXT,
                ADD COLUMN IF NOT EXISTS import_reconstruction_method   TEXT,
                ADD COLUMN IF NOT EXISTS import_gap_start               TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS import_gap_end                 TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS import_gap_delta_wh            NUMERIC,
                ADD COLUMN IF NOT EXISTS export_reconstruction_role     TEXT,
                ADD COLUMN IF NOT EXISTS export_reconstruction_method   TEXT,
                ADD COLUMN IF NOT EXISTS export_gap_start               TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS export_gap_end                 TIMESTAMPTZ,
                ADD COLUMN IF NOT EXISTS export_gap_delta_wh            NUMERIC
        $sql$, v_table);

        -- Per direction: either no reconstruction metadata at all, or a
        -- complete, internally consistent set. The row's bucket must lie in
        -- the gap's half-open-at-start slot range (gap_start, gap_end].
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = format('analytics.%I', v_table)::regclass
              AND conname = 'ck_' || v_table || '_import_reconstruction'
        ) THEN
            EXECUTE format($sql$
                ALTER TABLE analytics.%1$I
                ADD CONSTRAINT %2$I CHECK (
                    (
                        import_reconstruction_role IS NULL
                        AND import_reconstruction_method IS NULL
                        AND import_gap_start IS NULL
                        AND import_gap_end IS NULL
                        AND import_gap_delta_wh IS NULL
                    )
                    OR
                    (
                        import_reconstruction_role IN ('GAP_END', 'INTERIOR')
                        AND import_reconstruction_method IN ('TIME_WEIGHTED', 'ACTIVE_POWER', 'MIXED')
                        AND import_gap_start IS NOT NULL
                        AND import_gap_end IS NOT NULL
                        AND import_gap_start < import_gap_end
                        AND bucket_start > import_gap_start
                        AND bucket_start <= import_gap_end
                        AND (import_reconstruction_role = 'GAP_END') = (bucket_start = import_gap_end)
                        AND import_gap_delta_wh IS NOT NULL
                        AND import_gap_delta_wh >= 0
                    )
                ) NOT VALID
            $sql$, v_table, 'ck_' || v_table || '_import_reconstruction');
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = format('analytics.%I', v_table)::regclass
              AND conname = 'ck_' || v_table || '_export_reconstruction'
        ) THEN
            EXECUTE format($sql$
                ALTER TABLE analytics.%1$I
                ADD CONSTRAINT %2$I CHECK (
                    (
                        export_reconstruction_role IS NULL
                        AND export_reconstruction_method IS NULL
                        AND export_gap_start IS NULL
                        AND export_gap_end IS NULL
                        AND export_gap_delta_wh IS NULL
                    )
                    OR
                    (
                        export_reconstruction_role IN ('GAP_END', 'INTERIOR')
                        AND export_reconstruction_method IN ('TIME_WEIGHTED', 'ACTIVE_POWER', 'MIXED')
                        AND export_gap_start IS NOT NULL
                        AND export_gap_end IS NOT NULL
                        AND export_gap_start < export_gap_end
                        AND bucket_start > export_gap_start
                        AND bucket_start <= export_gap_end
                        AND (export_reconstruction_role = 'GAP_END') = (bucket_start = export_gap_end)
                        AND export_gap_delta_wh IS NOT NULL
                        AND export_gap_delta_wh >= 0
                    )
                ) NOT VALID
            $sql$, v_table, 'ck_' || v_table || '_export_reconstruction');
        END IF;

        -- Row-level summary flag must agree with the per-direction metadata.
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = format('analytics.%I', v_table)::regclass
              AND conname = 'ck_' || v_table || '_is_reconstructed'
        ) THEN
            EXECUTE format($sql$
                ALTER TABLE analytics.%1$I
                ADD CONSTRAINT %2$I CHECK (
                    is_reconstructed = (
                        import_reconstruction_role IS NOT NULL
                        OR export_reconstruction_role IS NOT NULL
                    )
                ) NOT VALID
            $sql$, v_table, 'ck_' || v_table || '_is_reconstructed');
        END IF;

        EXECUTE format($sql$
            COMMENT ON COLUMN analytics.%1$I.is_reconstructed IS
            'ADR-020 (migration 268): TRUE when this native row carries energy whose TIMING was reconstructed by distributing a measured cumulative-register gap delta (import and/or export). The energy total is measured by the meter; only its distribution across the gap slots is reconstructed. Not written by any code path yet (foundations only).'
        $sql$, v_table);
        EXECUTE format($sql$
            COMMENT ON COLUMN analytics.%1$I.import_reconstruction_role IS
            'ADR-020: GAP_END = the measured bucket that closes the gap (bucket_start = import_gap_end); INTERIOR = a slot strictly inside the gap. NULL = import energy not reconstructed.'
        $sql$, v_table);
        EXECUTE format($sql$
            COMMENT ON COLUMN analytics.%1$I.import_reconstruction_method IS
            'ADR-020: TIME_WEIGHTED | ACTIVE_POWER | MIXED -- the weighting analytics.energy_gap_weights chose for this gap.'
        $sql$, v_table);
        EXECUTE format($sql$
            COMMENT ON COLUMN analytics.%1$I.import_gap_delta_wh IS
            'ADR-020: the full measured import register delta of the gap this row belongs to (the value the gap''s slot allocations sum to exactly).'
        $sql$, v_table);
    END LOOP;
END;
$cols$;


-- ----------------------------------------------------------------------------
-- 2. analytics.energy_gap_weights -- per-slot weights for one gap.
--
-- Input: one element per native slot of the gap, in slot order (slot 1 is
-- the first slot after the gap-start bucket, slot n is the gap-end
-- bucket), holding that slot's average ACTIVE_POWER_TOTAL in W, or NULL
-- when no usable power reading exists in that slot. Power from outside the
-- gap is never an input -- the caller must not pass it, and this function
-- has no way to infer it.
--
-- Rules:
--   * NULL, NaN and +/-Infinity are "no reading" (uncovered slot).
--   * Negative power is clamped to 0 (an import allocation never takes
--     energy away from a slot).
--   * No covered slot, or covered power sums to 0 -> TIME_WEIGHTED, all
--     weights 1.
--   * Every slot covered -> ACTIVE_POWER, weight = clamped power.
--   * Some slots covered -> MIXED: covered slots keep their clamped power;
--     each uncovered slot gets the mean clamped power of the covered slots.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.energy_gap_weights(
    p_slot_active_power_w NUMERIC[]
)
RETURNS TABLE (method TEXT, weights NUMERIC[])
LANGUAGE plpgsql
IMMUTABLE STRICT PARALLEL SAFE
SET search_path TO pg_catalog
AS $function$
DECLARE
    v_n            INTEGER := cardinality(p_slot_active_power_w);
    v_clamped      NUMERIC[] := ARRAY[]::NUMERIC[];
    v_value        NUMERIC;
    v_covered      INTEGER := 0;
    v_covered_sum  NUMERIC := 0;
    v_mean         NUMERIC;
    i              INTEGER;
BEGIN
    IF v_n = 0 OR array_ndims(p_slot_active_power_w) <> 1 THEN
        RAISE EXCEPTION 'analytics.energy_gap_weights: expected a non-empty one-dimensional array'
            USING ERRCODE = '22023';
    END IF;

    FOR i IN 1 .. v_n LOOP
        v_value := p_slot_active_power_w[array_lower(p_slot_active_power_w, 1) + i - 1];
        IF v_value IS NULL
           OR v_value = 'NaN'::NUMERIC
           OR v_value IN ('Infinity'::NUMERIC, '-Infinity'::NUMERIC)
        THEN
            v_clamped := v_clamped || NULL::NUMERIC;
        ELSE
            v_value := GREATEST(v_value, 0);
            v_clamped := v_clamped || v_value;
            v_covered := v_covered + 1;
            v_covered_sum := v_covered_sum + v_value;
        END IF;
    END LOOP;

    IF v_covered = 0 OR v_covered_sum = 0 THEN
        RETURN QUERY SELECT 'TIME_WEIGHTED'::TEXT, array_fill(1::NUMERIC, ARRAY[v_n]);
        RETURN;
    END IF;

    IF v_covered = v_n THEN
        RETURN QUERY SELECT 'ACTIVE_POWER'::TEXT, v_clamped;
        RETURN;
    END IF;

    v_mean := v_covered_sum / v_covered;
    RETURN QUERY
    SELECT 'MIXED'::TEXT,
           array_agg(COALESCE(w, v_mean) ORDER BY ord)
    FROM unnest(v_clamped) WITH ORDINALITY AS u(w, ord);
END;
$function$;

COMMENT ON FUNCTION analytics.energy_gap_weights(NUMERIC[]) IS
'ADR-020 (migration 268): pure per-slot weights for distributing one gap''s measured register delta. Input = in-gap average ACTIVE_POWER_TOTAL (W) per native slot, NULL/NaN/Infinity = no reading. Returns TIME_WEIGHTED (all 1) when no usable power, ACTIVE_POWER (clamped power) when every slot is covered, MIXED (covered slots keep power, uncovered slots get the covered mean) otherwise. Negative power is clamped to 0. Never uses power from outside the gap. Not called by any code path yet.';


-- ----------------------------------------------------------------------------
-- 3. analytics.allocate_energy_delta -- exact, non-negative, deterministic.
--
-- Cumulative-difference rounding: with W_k = sum of the first k weights,
--     C_k = LEAST(round(delta * W_k / W_n, scale), delta)   for k < n
--     C_n = delta
--     share_k = C_k - C_{k-1}                               (C_0 = 0)
-- The shares telescope to exactly delta (C_n - C_0). W_k is non-decreasing
-- (weights >= 0), round() and LEAST(., delta) are monotone, so every C_k is
-- non-decreasing and bounded by delta: every share is >= 0. Only the final
-- share can carry more decimal places than p_scale (when delta itself does).
-- n = 1 returns ARRAY[delta] unchanged.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.allocate_energy_delta(
    p_delta   NUMERIC,
    p_weights NUMERIC[],
    p_scale   INTEGER DEFAULT 3
)
RETURNS NUMERIC[]
LANGUAGE plpgsql
IMMUTABLE STRICT PARALLEL SAFE
SET search_path TO pg_catalog
AS $function$
DECLARE
    v_n        INTEGER := cardinality(p_weights);
    v_lower    INTEGER;
    v_total    NUMERIC := 0;
    v_running  NUMERIC := 0;
    v_prev     NUMERIC := 0;
    v_cum      NUMERIC;
    v_weight   NUMERIC;
    v_result   NUMERIC[] := ARRAY[]::NUMERIC[];
    i          INTEGER;
BEGIN
    IF p_delta = 'NaN'::NUMERIC OR p_delta IN ('Infinity'::NUMERIC, '-Infinity'::NUMERIC) THEN
        RAISE EXCEPTION 'analytics.allocate_energy_delta: delta must be finite, got %', p_delta
            USING ERRCODE = '22023';
    END IF;
    IF p_delta < 0 THEN
        RAISE EXCEPTION 'analytics.allocate_energy_delta: delta must be >= 0, got %', p_delta
            USING ERRCODE = '22023';
    END IF;
    IF p_scale < 0 OR p_scale > 12 THEN
        RAISE EXCEPTION 'analytics.allocate_energy_delta: scale must be between 0 and 12, got %', p_scale
            USING ERRCODE = '22023';
    END IF;
    IF v_n = 0 OR array_ndims(p_weights) <> 1 THEN
        RAISE EXCEPTION 'analytics.allocate_energy_delta: expected a non-empty one-dimensional weights array'
            USING ERRCODE = '22023';
    END IF;

    v_lower := array_lower(p_weights, 1);
    FOR i IN 1 .. v_n LOOP
        v_weight := p_weights[v_lower + i - 1];
        IF v_weight IS NULL
           OR v_weight = 'NaN'::NUMERIC
           OR v_weight IN ('Infinity'::NUMERIC, '-Infinity'::NUMERIC)
           OR v_weight < 0
        THEN
            RAISE EXCEPTION 'analytics.allocate_energy_delta: weight % must be a finite number >= 0, got %', i, v_weight
                USING ERRCODE = '22023';
        END IF;
        v_total := v_total + v_weight;
    END LOOP;

    IF v_total = 0 THEN
        RAISE EXCEPTION 'analytics.allocate_energy_delta: weights must not all be 0'
            USING ERRCODE = '22023';
    END IF;

    FOR i IN 1 .. v_n LOOP
        v_running := v_running + p_weights[v_lower + i - 1];
        IF i = v_n THEN
            v_cum := p_delta;
        ELSE
            v_cum := LEAST(round((p_delta * v_running) / v_total, p_scale), p_delta);
        END IF;
        v_result := v_result || (v_cum - v_prev);
        v_prev := v_cum;
    END LOOP;

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION analytics.allocate_energy_delta(NUMERIC, NUMERIC[], INTEGER) IS
'ADR-020 (migration 268): distributes a measured register delta (>= 0) across gap slots in proportion to the given non-negative weights using cumulative-difference rounding at p_scale decimals (default 3 = 0.001 Wh). Guarantees: shares sum EXACTLY to p_delta, no share is negative, output is deterministic, n = 1 returns ARRAY[p_delta]. Raises (22023) on negative/non-finite delta, NULL/negative/non-finite weights, all-zero weights, or an empty array. Not called by any code path yet.';

REVOKE ALL ON FUNCTION analytics.energy_gap_weights(NUMERIC[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.allocate_energy_delta(NUMERIC, NUMERIC[], INTEGER) FROM PUBLIC;


-- ----------------------------------------------------------------------------
-- 4. The reconstruction switch -- default OFF.
--
-- Resolution (config.energy_reconstruction_enabled): the most specific row
-- wins -- DEVICE, then SITE, then GLOBAL -- and absence of any row means
-- FALSE. A DEVICE row may therefore enable a single canary device while
-- GLOBAL stays FALSE, or disable one device inside an enabled site.
-- Written only by an administrator / a future authorized migration; no
-- application role can write it.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.energy_reconstruction_scope (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_type  TEXT NOT NULL,
    site_id     UUID REFERENCES metadata.sites(id),
    device_id   UUID REFERENCES metadata.devices(id),
    is_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
    reason      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by  TEXT NOT NULL DEFAULT current_user,

    CONSTRAINT ck_energy_reconstruction_scope_type
        CHECK (scope_type IN ('GLOBAL', 'SITE', 'DEVICE')),

    CONSTRAINT ck_energy_reconstruction_scope_target
        CHECK (
            (scope_type = 'GLOBAL' AND site_id IS NULL     AND device_id IS NULL)
         OR (scope_type = 'SITE'   AND site_id IS NOT NULL AND device_id IS NULL)
         OR (scope_type = 'DEVICE' AND site_id IS NULL     AND device_id IS NOT NULL)
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_energy_reconstruction_scope_global
    ON config.energy_reconstruction_scope (scope_type)
    WHERE scope_type = 'GLOBAL';

CREATE UNIQUE INDEX IF NOT EXISTS uq_energy_reconstruction_scope_site
    ON config.energy_reconstruction_scope (site_id)
    WHERE scope_type = 'SITE';

CREATE UNIQUE INDEX IF NOT EXISTS uq_energy_reconstruction_scope_device
    ON config.energy_reconstruction_scope (device_id)
    WHERE scope_type = 'DEVICE';

COMMENT ON TABLE config.energy_reconstruction_scope IS
'ADR-020 (migration 268): switch for late/recovered Energy gap reconstruction. Most specific row wins (DEVICE > SITE > GLOBAL); no row = disabled. Seeded with GLOBAL is_enabled = FALSE. Nothing consults it until a later, separately authorized ADR-020 slice.';

INSERT INTO config.energy_reconstruction_scope (scope_type, is_enabled, reason)
VALUES ('GLOBAL', FALSE, 'Migration 268 seed: reconstruction foundations deployed disabled (ADR-020).')
ON CONFLICT (scope_type) WHERE scope_type = 'GLOBAL' DO NOTHING;

REVOKE ALL ON TABLE config.energy_reconstruction_scope FROM PUBLIC;

CREATE OR REPLACE FUNCTION config.energy_reconstruction_enabled(
    p_site_id   UUID,
    p_device_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE PARALLEL SAFE
SET search_path TO pg_catalog, config
AS $function$
    SELECT COALESCE(
        (SELECT s.is_enabled FROM config.energy_reconstruction_scope s
         WHERE s.scope_type = 'DEVICE' AND s.device_id = p_device_id),
        (SELECT s.is_enabled FROM config.energy_reconstruction_scope s
         WHERE s.scope_type = 'SITE' AND s.site_id = p_site_id),
        (SELECT s.is_enabled FROM config.energy_reconstruction_scope s
         WHERE s.scope_type = 'GLOBAL'),
        FALSE
    );
$function$;

COMMENT ON FUNCTION config.energy_reconstruction_enabled(UUID, UUID) IS
'ADR-020 (migration 268): TRUE only when the most specific config.energy_reconstruction_scope row (DEVICE, then SITE, then GLOBAL) is enabled; FALSE when no row applies. Not called by any code path yet.';

REVOKE ALL ON FUNCTION config.energy_reconstruction_enabled(UUID, UUID) FROM PUBLIC;


-- ----------------------------------------------------------------------------
-- 5. Postconditions (catalog-only -- no scan of hypertable data).
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_table   TEXT;
    v_missing TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['energy_consumption_1min', 'energy_consumption_5min']
    LOOP
        SELECT string_agg(c, ', ') INTO v_missing
        FROM unnest(ARRAY[
            'is_reconstructed',
            'import_reconstruction_role', 'import_reconstruction_method',
            'import_gap_start', 'import_gap_end', 'import_gap_delta_wh',
            'export_reconstruction_role', 'export_reconstruction_method',
            'export_gap_start', 'export_gap_end', 'export_gap_delta_wh'
        ]) AS c
        WHERE NOT EXISTS (
            SELECT 1 FROM information_schema.columns ic
            WHERE ic.table_schema = 'analytics'
              AND ic.table_name = v_table
              AND ic.column_name = c
        );
        IF v_missing IS NOT NULL THEN
            RAISE EXCEPTION 'Migration 268 postcondition failed: analytics.% is missing columns %', v_table, v_missing;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns ic
            WHERE ic.table_schema = 'analytics'
              AND ic.table_name = v_table
              AND ic.column_name = 'is_reconstructed'
              AND ic.is_nullable = 'NO'
              AND ic.column_default = 'false'
        ) THEN
            RAISE EXCEPTION 'Migration 268 postcondition failed: analytics.%.is_reconstructed must be NOT NULL DEFAULT false', v_table;
        END IF;

        IF (
            SELECT count(*) FROM pg_constraint
            WHERE conrelid = format('analytics.%I', v_table)::regclass
              AND conname IN (
                  'ck_' || v_table || '_import_reconstruction',
                  'ck_' || v_table || '_export_reconstruction',
                  'ck_' || v_table || '_is_reconstructed'
              )
        ) <> 3 THEN
            RAISE EXCEPTION 'Migration 268 postcondition failed: analytics.% is missing reconstruction CHECK constraints', v_table;
        END IF;
    END LOOP;

    IF (
        SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.oid IN (
            'analytics.energy_gap_weights(numeric[])'::regprocedure,
            'analytics.allocate_energy_delta(numeric,numeric[],integer)'::regprocedure
        )
          AND p.provolatile = 'i'
    ) <> 2 THEN
        RAISE EXCEPTION 'Migration 268 postcondition failed: allocation functions must exist and be IMMUTABLE';
    END IF;

    IF has_function_privilege('public', 'analytics.allocate_energy_delta(numeric,numeric[],integer)', 'EXECUTE')
       OR has_function_privilege('public', 'analytics.energy_gap_weights(numeric[])', 'EXECUTE')
       OR has_function_privilege('public', 'config.energy_reconstruction_enabled(uuid,uuid)', 'EXECUTE')
    THEN
        RAISE EXCEPTION 'Migration 268 postcondition failed: a new function is executable by PUBLIC';
    END IF;

    IF (SELECT count(*) FROM config.energy_reconstruction_scope) <> 1
       OR NOT EXISTS (
           SELECT 1 FROM config.energy_reconstruction_scope
           WHERE scope_type = 'GLOBAL' AND is_enabled = FALSE
       )
    THEN
        RAISE EXCEPTION 'Migration 268 postcondition failed: the scope table must hold exactly one GLOBAL row with is_enabled = FALSE';
    END IF;

    IF config.energy_reconstruction_enabled(NULL, NULL) IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'Migration 268 postcondition failed: reconstruction must resolve to disabled';
    END IF;

    IF analytics.allocate_energy_delta(238645.2, array_fill(1::NUMERIC, ARRAY[188]))
           IS NULL
       OR (SELECT sum(x) FROM unnest(analytics.allocate_energy_delta(238645.2, array_fill(1::NUMERIC, ARRAY[188]))) x)
           <> 238645.2
    THEN
        RAISE EXCEPTION 'Migration 268 postcondition failed: allocate_energy_delta does not sum exactly';
    END IF;

    RAISE NOTICE 'Migration 268: all postconditions passed (reconstruction columns, pure allocation functions and a disabled switch deployed; no existing behavior changed).';
END;
$post$;
