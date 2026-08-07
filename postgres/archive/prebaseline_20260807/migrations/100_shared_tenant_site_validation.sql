-- ============================================================================
-- 100_shared_tenant_site_validation.sql
-- Refuse contradictory legacy ownership, then install shared ownership triggers.
-- The migration runner supplies the outer transaction.
-- ============================================================================

DO $$
DECLARE
    v_conflicts BIGINT;
BEGIN
    SELECT count(*) INTO v_conflicts
    FROM metadata.buildings b
    JOIN metadata.sites s ON s.id = b.site_id
    WHERE b.organization_id <> s.organization_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % building/site conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.floors f
    JOIN metadata.buildings b ON b.id = f.building_id
    WHERE f.organization_id <> b.organization_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % floor/building conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.spaces sp
    JOIN metadata.floors f ON f.id = sp.floor_id
    WHERE sp.organization_id <> f.organization_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % space/floor conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.assets a
    JOIN metadata.sites s ON s.id = a.site_id
    WHERE a.organization_id <> s.organization_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % asset/site conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.assets a
    JOIN metadata.spaces sp ON sp.id = a.space_id
    JOIN metadata.floors f ON f.id = sp.floor_id
    JOIN metadata.buildings b ON b.id = f.building_id
    WHERE a.organization_id <> sp.organization_id
       OR a.site_id <> b.site_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % asset/location conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.assets a
    JOIN metadata.assets p ON p.id = a.parent_asset_id
    WHERE a.organization_id <> p.organization_id
       OR a.site_id <> p.site_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % asset hierarchy ownership conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.gateways g
    JOIN metadata.sites s ON s.id = g.site_id
    WHERE g.organization_id <> s.organization_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % gateway/site conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.gateways g
    JOIN metadata.spaces sp ON sp.id = g.space_id
    JOIN metadata.floors f ON f.id = sp.floor_id
    JOIN metadata.buildings b ON b.id = f.building_id
    WHERE g.organization_id <> sp.organization_id
       OR g.site_id <> b.site_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % gateway/location conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.devices d
    JOIN metadata.gateways g ON g.id = d.gateway_id
    WHERE d.organization_id <> g.organization_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % device/gateway conflicts found.', v_conflicts;
    END IF;

    SELECT count(*) INTO v_conflicts
    FROM metadata.asset_devices ad
    JOIN metadata.assets a ON a.id = ad.asset_id
    JOIN metadata.devices d ON d.id = ad.device_id
    LEFT JOIN metadata.gateways g ON g.id = d.gateway_id
    WHERE d.organization_id <> a.organization_id
       OR g.id IS NULL
       OR g.organization_id <> a.organization_id
       OR g.site_id <> a.site_id;
    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'Cannot install ownership validation: % asset-device ownership conflicts found.', v_conflicts;
    END IF;
END;
$$;


-- ============================================================================
-- 61_01_tenant_site_validation.sql
--
-- Shared organization and site ownership validation for EMS metadata.
--
-- Foreign keys prove that referenced rows exist. This shared trigger additionally
-- proves that duplicated ownership columns agree across the hierarchy and that
-- functional asset-device assignments cannot cross tenant or site boundaries.
-- ============================================================================

CREATE OR REPLACE FUNCTION metadata.validate_tenant_site_ownership()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_related_organization_id UUID;
    v_related_site_id UUID;
BEGIN
    CASE TG_TABLE_NAME
        WHEN 'buildings' THEN
            SELECT s.organization_id
            INTO v_related_organization_id
            FROM metadata.sites s
            WHERE s.id = NEW.site_id;

            IF v_related_organization_id IS DISTINCT FROM NEW.organization_id THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    MESSAGE = format(
                        'Building organization %s does not match site %s organization %s.',
                        NEW.organization_id,
                        NEW.site_id,
                        v_related_organization_id
                    );
            END IF;

        WHEN 'floors' THEN
            SELECT b.organization_id
            INTO v_related_organization_id
            FROM metadata.buildings b
            WHERE b.id = NEW.building_id;

            IF v_related_organization_id IS DISTINCT FROM NEW.organization_id THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    MESSAGE = format(
                        'Floor organization %s does not match building %s organization %s.',
                        NEW.organization_id,
                        NEW.building_id,
                        v_related_organization_id
                    );
            END IF;

        WHEN 'spaces' THEN
            SELECT f.organization_id, b.site_id
            INTO v_related_organization_id, v_related_site_id
            FROM metadata.floors f
            JOIN metadata.buildings b
              ON b.id = f.building_id
            WHERE f.id = NEW.floor_id;

            IF v_related_organization_id IS DISTINCT FROM NEW.organization_id THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    MESSAGE = format(
                        'Space organization %s does not match floor %s organization %s.',
                        NEW.organization_id,
                        NEW.floor_id,
                        v_related_organization_id
                    );
            END IF;

        WHEN 'assets' THEN
            SELECT s.organization_id
            INTO v_related_organization_id
            FROM metadata.sites s
            WHERE s.id = NEW.site_id;

            IF v_related_organization_id IS DISTINCT FROM NEW.organization_id THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    MESSAGE = format(
                        'Asset organization %s does not match site %s organization %s.',
                        NEW.organization_id,
                        NEW.site_id,
                        v_related_organization_id
                    );
            END IF;

            IF NEW.space_id IS NOT NULL THEN
                SELECT sp.organization_id, b.site_id
                INTO v_related_organization_id, v_related_site_id
                FROM metadata.spaces sp
                JOIN metadata.floors f
                  ON f.id = sp.floor_id
                JOIN metadata.buildings b
                  ON b.id = f.building_id
                WHERE sp.id = NEW.space_id;

                IF v_related_organization_id IS DISTINCT FROM NEW.organization_id
                   OR v_related_site_id IS DISTINCT FROM NEW.site_id THEN
                    RAISE EXCEPTION USING
                        ERRCODE = '23514',
                        MESSAGE = format(
                            'Asset location %s does not belong to organization %s and site %s.',
                            NEW.space_id,
                            NEW.organization_id,
                            NEW.site_id
                        );
                END IF;
            END IF;

            IF NEW.parent_asset_id IS NOT NULL THEN
                SELECT a.organization_id, a.site_id
                INTO v_related_organization_id, v_related_site_id
                FROM metadata.assets a
                WHERE a.id = NEW.parent_asset_id;

                IF v_related_organization_id IS DISTINCT FROM NEW.organization_id
                   OR v_related_site_id IS DISTINCT FROM NEW.site_id THEN
                    RAISE EXCEPTION USING
                        ERRCODE = '23514',
                        MESSAGE = format(
                            'Parent asset %s does not belong to organization %s and site %s.',
                            NEW.parent_asset_id,
                            NEW.organization_id,
                            NEW.site_id
                        );
                END IF;
            END IF;

        WHEN 'gateways' THEN
            SELECT s.organization_id
            INTO v_related_organization_id
            FROM metadata.sites s
            WHERE s.id = NEW.site_id;

            IF v_related_organization_id IS DISTINCT FROM NEW.organization_id THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    MESSAGE = format(
                        'Gateway organization %s does not match site %s organization %s.',
                        NEW.organization_id,
                        NEW.site_id,
                        v_related_organization_id
                    );
            END IF;

            IF NEW.space_id IS NOT NULL THEN
                SELECT sp.organization_id, b.site_id
                INTO v_related_organization_id, v_related_site_id
                FROM metadata.spaces sp
                JOIN metadata.floors f
                  ON f.id = sp.floor_id
                JOIN metadata.buildings b
                  ON b.id = f.building_id
                WHERE sp.id = NEW.space_id;

                IF v_related_organization_id IS DISTINCT FROM NEW.organization_id
                   OR v_related_site_id IS DISTINCT FROM NEW.site_id THEN
                    RAISE EXCEPTION USING
                        ERRCODE = '23514',
                        MESSAGE = format(
                            'Gateway location %s does not belong to organization %s and site %s.',
                            NEW.space_id,
                            NEW.organization_id,
                            NEW.site_id
                        );
                END IF;
            END IF;

        WHEN 'devices' THEN
            IF NEW.gateway_id IS NOT NULL THEN
                SELECT g.organization_id, g.site_id
                INTO v_related_organization_id, v_related_site_id
                FROM metadata.gateways g
                WHERE g.id = NEW.gateway_id;

                IF v_related_organization_id IS DISTINCT FROM NEW.organization_id THEN
                    RAISE EXCEPTION USING
                        ERRCODE = '23514',
                        MESSAGE = format(
                            'Device organization %s does not match gateway %s organization %s.',
                            NEW.organization_id,
                            NEW.gateway_id,
                            v_related_organization_id
                        );
                END IF;
            END IF;

        WHEN 'asset_devices' THEN
            SELECT a.organization_id, a.site_id
            INTO v_related_organization_id, v_related_site_id
            FROM metadata.assets a
            WHERE a.id = NEW.asset_id;

            PERFORM 1
            FROM metadata.devices d
            JOIN metadata.gateways g
              ON g.id = d.gateway_id
            WHERE d.id = NEW.device_id
              AND d.organization_id = v_related_organization_id
              AND g.organization_id = v_related_organization_id
              AND g.site_id = v_related_site_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION USING
                    ERRCODE = '23514',
                    MESSAGE = format(
                        'Asset %s and device %s must belong to the same organization and site, and the device must have a gateway.',
                        NEW.asset_id,
                        NEW.device_id
                    );
            END IF;

        ELSE
            RAISE EXCEPTION 'Unsupported ownership-validation table: %', TG_TABLE_NAME;
    END CASE;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION metadata.validate_tenant_site_ownership() IS
'Shared server-side validation preventing contradictory organization, site, location, hierarchy, gateway, device, and asset-device ownership.';

DROP TRIGGER IF EXISTS trg_validate_building_ownership ON metadata.buildings;
CREATE TRIGGER trg_validate_building_ownership
BEFORE INSERT OR UPDATE OF organization_id, site_id
ON metadata.buildings
FOR EACH ROW EXECUTE FUNCTION metadata.validate_tenant_site_ownership();

DROP TRIGGER IF EXISTS trg_validate_floor_ownership ON metadata.floors;
CREATE TRIGGER trg_validate_floor_ownership
BEFORE INSERT OR UPDATE OF organization_id, building_id
ON metadata.floors
FOR EACH ROW EXECUTE FUNCTION metadata.validate_tenant_site_ownership();

DROP TRIGGER IF EXISTS trg_validate_space_ownership ON metadata.spaces;
CREATE TRIGGER trg_validate_space_ownership
BEFORE INSERT OR UPDATE OF organization_id, floor_id
ON metadata.spaces
FOR EACH ROW EXECUTE FUNCTION metadata.validate_tenant_site_ownership();

DROP TRIGGER IF EXISTS trg_validate_asset_ownership ON metadata.assets;
CREATE TRIGGER trg_validate_asset_ownership
BEFORE INSERT OR UPDATE OF organization_id, site_id, space_id, parent_asset_id
ON metadata.assets
FOR EACH ROW EXECUTE FUNCTION metadata.validate_tenant_site_ownership();

DROP TRIGGER IF EXISTS trg_validate_gateway_ownership ON metadata.gateways;
CREATE TRIGGER trg_validate_gateway_ownership
BEFORE INSERT OR UPDATE OF organization_id, site_id, space_id
ON metadata.gateways
FOR EACH ROW EXECUTE FUNCTION metadata.validate_tenant_site_ownership();

DROP TRIGGER IF EXISTS trg_validate_device_ownership ON metadata.devices;
CREATE TRIGGER trg_validate_device_ownership
BEFORE INSERT OR UPDATE OF organization_id, gateway_id
ON metadata.devices
FOR EACH ROW EXECUTE FUNCTION metadata.validate_tenant_site_ownership();

DROP TRIGGER IF EXISTS trg_validate_asset_device_ownership ON metadata.asset_devices;
CREATE TRIGGER trg_validate_asset_device_ownership
BEFORE INSERT OR UPDATE OF asset_id, device_id
ON metadata.asset_devices
FOR EACH ROW EXECUTE FUNCTION metadata.validate_tenant_site_ownership();
