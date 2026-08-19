BEGIN;

-- Reduce finalized demand processing grace from ten minutes to five minutes.
--
-- This is separate from each demand policy's late_arrival_tolerance_seconds.
-- The demand processor continues to run every minute and retains its
-- configured historical lookback, allowing late data to be reconsidered.
--
-- Do not reduce the policy late-arrival tolerance here.

CREATE OR REPLACE PROCEDURE analytics.refresh_demand_analytics(IN p_now timestamp with time zone DEFAULT clock_timestamp(), IN p_lookback interval DEFAULT '03:00:00'::interval)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'analytics', 'config', 'metadata'
AS $procedure$
DECLARE
    v_site RECORD;
    v_scope RECORD;
    v_interval RECORD;
    v_calc RECORD;
    v_policy RECORD;
    v_site_policy RECORD;
    v_asset_policy RECORD;
    v_current RECORD;
    v_n INTEGER;
    v_max_n INTEGER;
BEGIN
    IF p_lookback IS NULL OR p_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'p_lookback must be positive.';
    END IF;

    -- Every non-decommissioned site participates in automatic ASSET demand.
    -- SITE demand remains opt-in through the user-managed SITE policy.
    FOR v_site IN
        SELECT s.id AS site_id
        FROM metadata.sites AS s
        WHERE COALESCE(s.lifecycle_status, 'ACTIVE') <> 'DECOMMISSIONED'
    LOOP
        SELECT * INTO v_site_policy
        FROM config.resolve_site_demand_policy(v_site.site_id, p_now);

        SELECT * INTO v_asset_policy
        FROM config.resolve_asset_demand_policy(v_site.site_id, p_now);

        IF v_site_policy.policy_id IS NULL
           OR NOT COALESCE(v_site_policy.is_enabled, FALSE) THEN
            DELETE FROM analytics.demand_state
            WHERE site_id = v_site.site_id
              AND scope_type = 'SITE';
        END IF;

        -- Remove stale asset state when a PRIMARY_METER relationship has been removed.
        DELETE FROM analytics.demand_state AS ds
        WHERE ds.site_id = v_site.site_id
          AND ds.scope_type = 'ASSET'
          AND NOT EXISTS (
              SELECT 1
              FROM metadata.asset_devices AS ad
              JOIN metadata.assets AS a ON a.id = ad.asset_id
              WHERE a.site_id = v_site.site_id
                AND ad.asset_id = ds.asset_id
                AND ad.relationship_type = 'PRIMARY_METER'
          );

        FOR v_scope IN
            SELECT 'SITE'::TEXT AS scope_type,
                   NULL::UUID AS asset_id,
                   v_site_policy.policy_id AS policy_id,
                   v_site_policy.demand_interval_seconds AS demand_interval_seconds,
                   v_site_policy.effective_from AS effective_from,
                   v_site_policy.effective_to AS effective_to,
                   v_site_policy.late_arrival_tolerance_seconds AS late_arrival_tolerance_seconds
            WHERE v_site_policy.policy_id IS NOT NULL
              AND COALESCE(v_site_policy.is_enabled, FALSE)

            UNION ALL

            SELECT 'ASSET'::TEXT,
                   ad.asset_id,
                   v_asset_policy.policy_id,
                   v_asset_policy.demand_interval_seconds,
                   v_asset_policy.effective_from,
                   v_asset_policy.effective_to,
                   v_asset_policy.late_arrival_tolerance_seconds
            FROM metadata.asset_devices AS ad
            JOIN metadata.assets AS a ON a.id = ad.asset_id
            WHERE a.site_id = v_site.site_id
              AND ad.relationship_type = 'PRIMARY_METER'
              AND v_asset_policy.policy_id IS NOT NULL
        LOOP
            IF v_scope.scope_type = 'ASSET' THEN
                SELECT * INTO v_policy
                FROM config.resolve_asset_demand_policy(v_site.site_id, p_now);
            ELSE
                SELECT * INTO v_policy
                FROM config.resolve_site_demand_policy(v_site.site_id, p_now);
            END IF;

            v_max_n := ceil(
                extract(epoch FROM p_lookback) / v_policy.demand_interval_seconds
            )::INTEGER + 2;

            -- Current provisional state.
            SELECT * INTO v_current
            FROM analytics.resolve_demand_interval(
                v_site.site_id,
                v_policy.demand_interval_seconds,
                p_now
            );

            IF v_current.interval_start >= v_policy.effective_from
               AND (v_policy.effective_to IS NULL OR v_current.interval_start < v_policy.effective_to) THEN
                SELECT * INTO v_calc
                FROM analytics.calculate_demand_window(
                    v_site.site_id,
                    v_scope.scope_type,
                    v_scope.asset_id,
                    v_current.interval_start,
                    v_current.interval_end,
                    p_now,
                    FALSE
                );

                IF v_calc.demand_policy_id IS NOT NULL THEN
                    INSERT INTO analytics.demand_state(
                        site_id,scope_type,asset_id,demand_policy_id,source_device_id,
                        interval_start,interval_end,current_demand_kw,current_demand_kva,
                        expected_observations,observed_observations,coverage_percent,
                        quality_status,updated_at
                    ) VALUES (
                        v_site.site_id,v_scope.scope_type,v_scope.asset_id,
                        v_calc.demand_policy_id,v_calc.source_device_id,
                        v_current.interval_start,v_current.interval_end,
                        v_calc.demand_kw,v_calc.demand_kva,
                        v_calc.expected_observations,v_calc.observed_observations,
                        v_calc.coverage_percent,
                        CASE
                            WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION')
                                THEN v_calc.quality_status
                            ELSE 'PROVISIONAL'
                        END,
                        clock_timestamp()
                    )
                    ON CONFLICT DO NOTHING;

                    IF v_scope.scope_type='SITE' THEN
                        UPDATE analytics.demand_state SET
                            demand_policy_id=v_calc.demand_policy_id,
                            source_device_id=v_calc.source_device_id,
                            interval_start=v_current.interval_start,
                            interval_end=v_current.interval_end,
                            current_demand_kw=v_calc.demand_kw,
                            current_demand_kva=v_calc.demand_kva,
                            expected_observations=v_calc.expected_observations,
                            observed_observations=v_calc.observed_observations,
                            coverage_percent=v_calc.coverage_percent,
                            quality_status=CASE
                                WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION')
                                    THEN v_calc.quality_status
                                ELSE 'PROVISIONAL'
                            END,
                            updated_at=clock_timestamp()
                        WHERE site_id=v_site.site_id AND scope_type='SITE';
                    ELSE
                        UPDATE analytics.demand_state SET
                            site_id=v_site.site_id,
                            demand_policy_id=v_calc.demand_policy_id,
                            source_device_id=v_calc.source_device_id,
                            interval_start=v_current.interval_start,
                            interval_end=v_current.interval_end,
                            current_demand_kw=v_calc.demand_kw,
                            current_demand_kva=v_calc.demand_kva,
                            expected_observations=v_calc.expected_observations,
                            observed_observations=v_calc.observed_observations,
                            coverage_percent=v_calc.coverage_percent,
                            quality_status=CASE
                                WHEN v_calc.quality_status IN ('NO_DATA','INVALID_SOURCE','INSUFFICIENT_SOURCE_RESOLUTION')
                                    THEN v_calc.quality_status
                                ELSE 'PROVISIONAL'
                            END,
                            updated_at=clock_timestamp()
                        WHERE asset_id=v_scope.asset_id AND scope_type='ASSET';
                    END IF;
                END IF;
            END IF;

            -- Finalized historical intervals. Five-minute processing grace remains
            -- separate from the policy late-arrival allowance.
            FOR v_n IN 1..v_max_n LOOP
                SELECT * INTO v_interval
                FROM analytics.resolve_demand_interval(
                    v_site.site_id,
                    v_policy.demand_interval_seconds,
                    p_now - make_interval(secs => v_n*v_policy.demand_interval_seconds)
                );

                EXIT WHEN v_interval.interval_end < p_now-p_lookback;

                IF v_interval.interval_start < v_policy.effective_from THEN
                    CONTINUE;
                END IF;
                IF v_policy.effective_to IS NOT NULL
                   AND v_interval.interval_end > v_policy.effective_to THEN
                    CONTINUE;
                END IF;
                IF v_interval.interval_end
                   + make_interval(secs => COALESCE(v_policy.late_arrival_tolerance_seconds,0))
                   + INTERVAL '5 minutes' > p_now THEN
                    CONTINUE;
                END IF;

                SELECT * INTO v_calc
                FROM analytics.calculate_demand_window(
                    v_site.site_id,
                    v_scope.scope_type,
                    v_scope.asset_id,
                    v_interval.interval_start,
                    v_interval.interval_end,
                    v_interval.interval_end,
                    TRUE
                );

                IF v_calc.demand_policy_id IS NULL THEN CONTINUE; END IF;

                INSERT INTO analytics.demand_intervals(
                    interval_start,interval_end,organization_id,site_id,scope_type,
                    asset_id,demand_policy_id,source_device_id,demand_kw,demand_kva,
                    peak_power_kw,energy_kwh,source_method,expected_observations,
                    observed_observations,coverage_percent,quality_status,finalized_at
                ) VALUES (
                    v_interval.interval_start,v_interval.interval_end,
                    v_calc.organization_id,v_calc.site_id,v_calc.scope_type,
                    v_calc.asset_id,v_calc.demand_policy_id,v_calc.source_device_id,
                    v_calc.demand_kw,v_calc.demand_kva,v_calc.peak_power_kw,
                    v_calc.energy_kwh,v_calc.source_method,v_calc.expected_observations,
                    v_calc.observed_observations,v_calc.coverage_percent,
                    CASE WHEN v_calc.quality_status='PROVISIONAL' THEN 'INCOMPLETE' ELSE v_calc.quality_status END,
                    clock_timestamp()
                )
                ON CONFLICT DO NOTHING;
            END LOOP;
        END LOOP;
    END LOOP;
END;
$procedure$;

COMMIT;
