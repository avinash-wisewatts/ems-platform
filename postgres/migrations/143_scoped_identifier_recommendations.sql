-- Migration 143
-- Allow duplicate Asset display names and provide scoped identifier
-- recommendations for onboarding.
--
-- Display names are descriptive labels and may repeat.
-- Codes and external IDs remain the stable machine identities.


DROP INDEX IF EXISTS metadata.uq_assets_root_name;
DROP INDEX IF EXISTS metadata.uq_assets_child_name;

CREATE OR REPLACE FUNCTION admin.recommend_available_identifier(
    p_entity_type TEXT,
    p_base_value TEXT,
    p_organization_id UUID DEFAULT NULL,
    p_site_id UUID DEFAULT NULL,
    p_building_id UUID DEFAULT NULL,
    p_floor_id UUID DEFAULT NULL,
    p_exclude_id UUID DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_entity_type TEXT;
    v_base        TEXT;
    v_candidate   TEXT;
    v_suffix      INTEGER := 1;
    v_exists      BOOLEAN;
BEGIN
    v_entity_type := upper(btrim(coalesce(p_entity_type, '')));

    v_base := upper(
        trim(
            both '_' FROM
            regexp_replace(
                coalesce(nullif(btrim(p_base_value), ''), 'ITEM'),
                '[^A-Za-z0-9]+',
                '_',
                'g'
            )
        )
    );

    IF v_base = '' THEN
        v_base := 'ITEM';
    END IF;

    v_base := left(v_base, 100);
    v_candidate := v_base;

    IF v_entity_type NOT IN
    (
        'BUILDING',
        'FLOOR',
        'SPACE',
        'GATEWAY',
        'DEVICE',
        'ASSET'
    )
    THEN
        RAISE EXCEPTION
            'Unsupported identifier entity type: %',
            p_entity_type
            USING ERRCODE = '22023';
    END IF;

    LOOP
        v_exists :=
            CASE v_entity_type
                WHEN 'BUILDING' THEN EXISTS
                (
                    SELECT 1
                    FROM metadata.buildings b
                    WHERE b.site_id = p_site_id
                      AND upper(btrim(b.code))
                          = upper(btrim(v_candidate))
                      AND b.id IS DISTINCT FROM p_exclude_id
                )

                WHEN 'FLOOR' THEN EXISTS
                (
                    SELECT 1
                    FROM metadata.floors f
                    WHERE f.building_id = p_building_id
                      AND upper(btrim(f.code))
                          = upper(btrim(v_candidate))
                      AND f.id IS DISTINCT FROM p_exclude_id
                )

                WHEN 'SPACE' THEN EXISTS
                (
                    SELECT 1
                    FROM metadata.spaces s
                    WHERE s.floor_id = p_floor_id
                      AND upper(btrim(s.code))
                          = upper(btrim(v_candidate))
                      AND s.id IS DISTINCT FROM p_exclude_id
                )

                WHEN 'GATEWAY' THEN EXISTS
                (
                    SELECT 1
                    FROM metadata.gateways g
                    WHERE g.organization_id = p_organization_id
                      AND upper(btrim(g.external_id))
                          = upper(btrim(v_candidate))
                      AND g.id IS DISTINCT FROM p_exclude_id
                )

                WHEN 'DEVICE' THEN EXISTS
                (
                    SELECT 1
                    FROM metadata.devices d
                    WHERE d.organization_id = p_organization_id
                      AND upper(btrim(d.external_id))
                          = upper(btrim(v_candidate))
                      AND d.id IS DISTINCT FROM p_exclude_id
                )

                WHEN 'ASSET' THEN EXISTS
                (
                    SELECT 1
                    FROM metadata.assets a
                    WHERE a.organization_id = p_organization_id
                      AND a.site_id = p_site_id
                      AND upper(btrim(a.external_id))
                          = upper(btrim(v_candidate))
                      AND a.id IS DISTINCT FROM p_exclude_id
                )

                ELSE FALSE
            END;

        EXIT WHEN NOT v_exists;

        v_suffix := v_suffix + 1;

        v_candidate :=
            left(
                v_base,
                100 - length(v_suffix::text) - 1
            )
            || '_'
            || v_suffix::text;
    END LOOP;

    RETURN v_candidate;
END;
$function$;

ALTER FUNCTION admin.recommend_available_identifier(
    TEXT,
    TEXT,
    UUID,
    UUID,
    UUID,
    UUID,
    UUID
)
OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.recommend_available_identifier(
    TEXT,
    TEXT,
    UUID,
    UUID,
    UUID,
    UUID,
    UUID
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.recommend_available_identifier(
    TEXT,
    TEXT,
    UUID,
    UUID,
    UUID,
    UUID,
    UUID
)
TO ems_app;

COMMENT ON FUNCTION admin.recommend_available_identifier(
    TEXT,
    TEXT,
    UUID,
    UUID,
    UUID,
    UUID,
    UUID
) IS
    'Returns an available scoped code or external ID by appending numeric suffixes without rejecting duplicate display names.';
