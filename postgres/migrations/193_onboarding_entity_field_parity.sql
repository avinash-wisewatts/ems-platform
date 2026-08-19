-- ============================================================================
-- Migration 193
-- Onboarding wizard / admin CRUD field-parity fixes.
--
-- An entity audit found that several database columns collected by the
-- admin CRUD create/edit screens are silently dropped -- or forced to a
-- different default -- when the same entity is created through the
-- onboarding wizard instead, because admin.onboard_energy_asset_legacy_upsert
-- never extracted these fields from the onboarding request payload:
--
--   * organization: timezone, lifecycle_status, legal_name, locale,
--     primary_contact, address, notes were never written (organizations
--     onboarded through the wizard were silently stuck on the column
--     defaults Asia/Kolkata / ACTIVE / en-US / empty contact & address).
--   * gateway: building_id/floor_id were resolved from the shared Location
--     step (v_building_id/v_floor_id) but only space_id was ever included
--     in the INSERT, so onboarded gateways lost the building/floor half of
--     their own already-resolved location.
--   * device: serial_number was hardcoded NULL and operational_policy was
--     never set (silently defaulting to the table's DEFAULT 'STANDALONE',
--     while the admin create form defaults to 'ASSET_ASSIGNED' -- i.e. the
--     entry point silently changed whether a device needs an asset
--     assignment before it can be commissioned).
--   * asset: lifecycle_status was never set (silently defaulting to the
--     table's DEFAULT 'ACTIVE', while the admin create form forces an
--     explicit choice, defaulting to DRAFT) and parent_asset_id was
--     hardcoded NULL (onboarding could never create a child asset /
--     sub-meter under a parent).
--
-- This migration re-declares admin.onboard_energy_asset_legacy_upsert with
-- the same signature (a CREATE OR REPLACE of the exact function body from
-- the pre-production baseline, 001_ems_platform_baseline_20260807.sql lines
-- 23961-26046) plus the additive extraction/INSERT changes described above.
-- Every change is additive: existing onboarding requests that omit these
-- new JSON keys behave exactly as before (same COALESCE defaults the table
-- itself already applies).
--
-- Follow-up (same migration, edited in place -- see repo history/PR
-- discussion; not yet applied to any deployed database at the time of this
-- edit): strict Model-Catalog Governance for gateway and device onboarding.
-- gateway.vendor/gateway.model/gateway.protocol and device.model_vendor/
-- device.model are no longer accepted or auto-created into the
-- metadata.gateway_models / metadata.device_models catalogs. CREATE_NEW
-- gateway and device onboarding now require gateway.gateway_model_id and
-- device.device_model_id, each a strict foreign key that must already
-- exist in the controlled catalog -- exactly the same contract the Admin
-- CRUD create/edit screens already enforce via <select> dropdowns bound to
-- gateway_model_id/device_model_id. This is a breaking change to the
-- onboarding request contract's gateway/device shape (not merely
-- additive), coordinated with the application-layer change replacing the
-- wizard's free-text <input list=...>/<datalist> vendor+model fields with
-- <select> dropdowns over the same catalogs.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.onboard_energy_asset_legacy_upsert(p_request jsonb, p_requested_by text DEFAULT CURRENT_USER)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata', 'config'
AS $function$
DECLARE
    v_organization_mode        TEXT;
    v_existing_organization_id UUID;
    v_organization_name        TEXT;
    v_organization_code        TEXT;
    v_organization_description TEXT;
    v_organization_timezone    TEXT;
    v_organization_lifecycle_status TEXT;
    v_organization_legal_name  TEXT;
    v_organization_locale      TEXT;
    v_organization_primary_contact JSONB;
    v_organization_address     JSONB;
    v_organization_notes       TEXT;

    v_site_mode                TEXT;
    v_existing_site_id         UUID;
    v_site_name                TEXT;
    v_site_code                TEXT;
    v_site_timezone            TEXT;
    v_site_address             JSONB;

    v_location_mode            TEXT;
    v_existing_space_id        UUID;

    v_building_name            TEXT;
    v_building_code            TEXT;
    v_building_id              UUID;

    v_floor_name               TEXT;
    v_floor_code               TEXT;
    v_floor_id                 UUID;

    v_space_name               TEXT;
    v_space_code               TEXT;
    v_space_id                 UUID;

    v_gateway_mode             TEXT;
    v_existing_gateway_id      UUID;
    v_gateway_name             TEXT;
    v_gateway_external_id      TEXT;

    v_device_mode              TEXT;
    v_existing_device_id       UUID;
    v_device_name              TEXT;
    v_device_external_id       TEXT;

    -- device_type is retained temporarily for backward compatibility.
    v_device_type              TEXT;
    v_device_category_id       UUID;
    v_device_category_name     TEXT;
    v_existing_model_category_id UUID;

    v_device_firmware_version  TEXT;
    v_device_protocol          TEXT;
    v_profile_code             TEXT;
    v_device_serial_number     TEXT;
    v_device_operational_policy TEXT;

    v_identifier_type          TEXT;
    v_identifier_value         TEXT;

    v_asset_mode               TEXT;
    v_existing_asset_id        UUID;
    v_asset_name               TEXT;
    v_asset_external_id        TEXT;
    v_asset_type_id            UUID;
    v_metering_requirement     TEXT;
    v_relationship_type        TEXT;
    v_asset_metadata           JSONB;
    v_asset_lifecycle_status   TEXT;
    v_parent_asset_id          UUID;

    v_grafana_org_id           BIGINT;

    v_organization_id          UUID;
    v_site_id                  UUID;
    v_gateway_model_id         UUID;
    v_gateway_id               UUID;
    v_device_model_id          UUID;
    v_profile_id               UUID;
    v_device_id                UUID;
    v_asset_id                 UUID;

    v_existing_identifier_device_id UUID;
    v_existing_primary_asset_id     UUID;
    v_existing_grafana_org_id       BIGINT;
    v_existing_grafana_org_owner    UUID;

    v_result                    JSONB;
BEGIN
    --------------------------------------------------------------------------
    -- Validate request container.
    --------------------------------------------------------------------------

    IF p_request IS NULL
       OR jsonb_typeof(p_request) <> 'object'
    THEN
        RAISE EXCEPTION
            'Onboarding request must be a JSON object';
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize organization fields.
    --------------------------------------------------------------------------

    v_organization_mode :=
        upper
        (
            COALESCE
            (
                NULLIF(
                    btrim(
                        p_request #>> '{organization,mode}'
                    ),
                    ''
                ),
                'CREATE_NEW'
            )
        );

    IF v_organization_mode NOT IN
    (
        'CREATE_NEW',
        'USE_EXISTING'
    )
    THEN
        RAISE EXCEPTION
            'organization.mode must be CREATE_NEW or USE_EXISTING';
    END IF;

    BEGIN
        v_existing_organization_id :=
            NULLIF
            (
                btrim(
                    p_request #>>
                    '{organization,existing_organization_id}'
                ),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'organization.existing_organization_id must be a valid UUID';
    END;

    v_organization_name :=
        NULLIF(
            btrim(
                p_request #>> '{organization,name}'
            ),
            ''
        );

    v_organization_code :=
        upper
        (
            NULLIF
            (
                btrim(
                    p_request #>> '{organization,code}'
                ),
                ''
            )
        );

    v_organization_description :=
        NULLIF
        (
            btrim(
                p_request #>> '{organization,description}'
            ),
            ''
        );

    v_organization_timezone :=
        COALESCE
        (
            NULLIF(
                btrim(
                    p_request #>> '{organization,timezone}'
                ),
                ''
            ),
            'Asia/Kolkata'
        );

    v_organization_lifecycle_status :=
        upper
        (
            COALESCE
            (
                NULLIF(
                    btrim(
                        p_request #>> '{organization,lifecycle_status}'
                    ),
                    ''
                ),
                'ACTIVE'
            )
        );

    v_organization_legal_name :=
        NULLIF(
            btrim(
                p_request #>> '{organization,legal_name}'
            ),
            ''
        );

    v_organization_locale :=
        COALESCE
        (
            NULLIF(
                btrim(
                    p_request #>> '{organization,locale}'
                ),
                ''
            ),
            'en-US'
        );

    v_organization_primary_contact :=
        COALESCE(
            p_request #> '{organization,primary_contact}',
            '{}'::JSONB
        );

    v_organization_address :=
        COALESCE(
            p_request #> '{organization,address}',
            '{}'::JSONB
        );

    v_organization_notes :=
        NULLIF(
            btrim(
                p_request #>> '{organization,notes}'
            ),
            ''
        );

    IF v_organization_mode = 'CREATE_NEW' THEN
        IF v_organization_name IS NULL THEN
            RAISE EXCEPTION
                'organization.name is required for CREATE_NEW';
        END IF;

        IF v_organization_code IS NULL THEN
            RAISE EXCEPTION
                'organization.code is required for CREATE_NEW';
        END IF;

        IF v_organization_code !~ '^[A-Z0-9_]+$' THEN
            RAISE EXCEPTION
                'organization.code must contain only A-Z, 0-9, and underscore';
        END IF;

        IF v_organization_lifecycle_status NOT IN
        (
            'DRAFT',
            'ACTIVE',
            'SUSPENDED',
            'DECOMMISSIONED'
        )
        THEN
            RAISE EXCEPTION
                'organization.lifecycle_status must be '
                'DRAFT, ACTIVE, SUSPENDED, or DECOMMISSIONED';
        END IF;

        IF jsonb_typeof(v_organization_primary_contact) <> 'object' THEN
            RAISE EXCEPTION
                'organization.primary_contact must be a JSON object';
        END IF;

        IF jsonb_typeof(v_organization_address) <> 'object' THEN
            RAISE EXCEPTION
                'organization.address must be a JSON object';
        END IF;

    ELSE
        IF v_existing_organization_id IS NULL THEN
            RAISE EXCEPTION
                'organization.existing_organization_id is required for USE_EXISTING';
        END IF;
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize site fields.
    --------------------------------------------------------------------------

    v_site_mode :=
        upper
        (
            COALESCE
            (
                NULLIF(
                    btrim(
                        p_request #>> '{site,mode}'
                    ),
                    ''
                ),
                'CREATE_NEW'
            )
        );

    IF v_site_mode NOT IN
    (
        'CREATE_NEW',
        'USE_EXISTING'
    )
    THEN
        RAISE EXCEPTION
            'site.mode must be CREATE_NEW or USE_EXISTING';
    END IF;

    BEGIN
        v_existing_site_id :=
            NULLIF
            (
                btrim(
                    p_request #>>
                    '{site,existing_site_id}'
                ),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'site.existing_site_id must be a valid UUID';
    END;

    v_site_name :=
        NULLIF(
            btrim(
                p_request #>> '{site,name}'
            ),
            ''
        );

    v_site_code :=
        upper
        (
            NULLIF
            (
                btrim(
                    p_request #>> '{site,code}'
                ),
                ''
            )
        );

    v_site_timezone :=
        COALESCE
        (
            NULLIF(
                btrim(
                    p_request #>> '{site,timezone}'
                ),
                ''
            ),
            'Asia/Kolkata'
        );

    v_site_address :=
        COALESCE(
            p_request #> '{site,address}',
            '{}'::JSONB
        );

    IF v_site_mode = 'CREATE_NEW' THEN
        IF v_site_name IS NULL THEN
            RAISE EXCEPTION
                'site.name is required for CREATE_NEW';
        END IF;

        IF v_site_code IS NULL THEN
            RAISE EXCEPTION
                'site.code is required for CREATE_NEW';
        END IF;

        IF v_site_code !~ '^[A-Z0-9_]+$' THEN
            RAISE EXCEPTION
                'site.code must contain only A-Z, 0-9, and underscore';
        END IF;

        IF jsonb_typeof(v_site_address) <> 'object' THEN
            RAISE EXCEPTION
                'site.address must be a JSON object';
        END IF;

        IF NOT EXISTS
        (
            SELECT 1
            FROM pg_timezone_names
            WHERE name = v_site_timezone
        )
        THEN
            RAISE EXCEPTION
                'Unknown IANA timezone: %',
                v_site_timezone;
        END IF;

    ELSE
        IF v_existing_site_id IS NULL THEN
            RAISE EXCEPTION
                'site.existing_site_id is required for USE_EXISTING';
        END IF;
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize optional physical-location fields.
    --------------------------------------------------------------------------

    v_location_mode :=
        upper
        (
            COALESCE
            (
                NULLIF(btrim(p_request #>> '{location,mode}'), ''),
                'SITE_ONLY'
            )
        );

    IF v_location_mode NOT IN
    (
        'SITE_ONLY',
        'CREATE_LOCATION',
        'USE_EXISTING_SPACE'
    )
    THEN
        RAISE EXCEPTION
            'location.mode must be SITE_ONLY, CREATE_LOCATION, or USE_EXISTING_SPACE';
    END IF;

    BEGIN
        v_existing_space_id :=
            NULLIF(
                btrim(p_request #>> '{location,existing_space_id}'),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'location.existing_space_id must be a valid UUID';
    END;

    v_building_name :=
        NULLIF(btrim(p_request #>> '{location,building_name}'), '');

    v_building_code :=
        upper(NULLIF(btrim(p_request #>> '{location,building_code}'), ''));

    v_floor_name :=
        NULLIF(btrim(p_request #>> '{location,floor_name}'), '');

    v_floor_code :=
        upper(NULLIF(btrim(p_request #>> '{location,floor_code}'), ''));

    v_space_name :=
        NULLIF(btrim(p_request #>> '{location,space_name}'), '');

    v_space_code :=
        upper(NULLIF(btrim(p_request #>> '{location,space_code}'), ''));

    IF v_location_mode = 'CREATE_LOCATION' THEN
        IF v_building_name IS NULL OR v_building_code IS NULL THEN
            RAISE EXCEPTION
                'location building name and code are required for CREATE_LOCATION';
        END IF;

        IF v_floor_name IS NULL OR v_floor_code IS NULL THEN
            RAISE EXCEPTION
                'location floor name and code are required for CREATE_LOCATION';
        END IF;

        IF v_space_name IS NULL OR v_space_code IS NULL THEN
            RAISE EXCEPTION
                'location space name and code are required for CREATE_LOCATION';
        END IF;

        IF v_building_code !~ '^[A-Z][A-Z0-9_]*$' THEN
            RAISE EXCEPTION
                'location.building_code must contain only A-Z, 0-9, and underscore';
        END IF;

        IF v_floor_code !~ '^[A-Z][A-Z0-9_]*$' THEN
            RAISE EXCEPTION
                'location.floor_code must contain only A-Z, 0-9, and underscore';
        END IF;

        IF v_space_code !~ '^[A-Z][A-Z0-9_]*$' THEN
            RAISE EXCEPTION
                'location.space_code must contain only A-Z, 0-9, and underscore';
        END IF;

    ELSIF v_location_mode = 'USE_EXISTING_SPACE' THEN
        IF v_existing_space_id IS NULL THEN
            RAISE EXCEPTION
                'location.existing_space_id is required for USE_EXISTING_SPACE';
        END IF;
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize gateway fields.
    --------------------------------------------------------------------------

    v_gateway_mode :=
        upper
        (
            COALESCE
            (
                NULLIF(
                    btrim(
                        p_request #>> '{gateway,mode}'
                    ),
                    ''
                ),
                'CREATE_NEW'
            )
        );

    IF v_gateway_mode NOT IN
    (
        'CREATE_NEW',
        'USE_EXISTING'
    )
    THEN
        RAISE EXCEPTION
            'gateway.mode must be CREATE_NEW or USE_EXISTING';
    END IF;

    BEGIN
        v_existing_gateway_id :=
            NULLIF
            (
                btrim(
                    p_request #>>
                    '{gateway,existing_gateway_id}'
                ),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'gateway.existing_gateway_id must be a valid UUID';
    END;

    v_gateway_name :=
        NULLIF(
            btrim(
                p_request #>> '{gateway,name}'
            ),
            ''
        );

    v_gateway_external_id :=
        upper
        (
            NULLIF
            (
                btrim(
                    p_request #>> '{gateway,external_id}'
                ),
                ''
            )
        );

    BEGIN
        v_gateway_model_id :=
            NULLIF(
                btrim(
                    p_request #>> '{gateway,gateway_model_id}'
                ),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'gateway.gateway_model_id must be a valid UUID';
    END;

    IF v_gateway_mode = 'CREATE_NEW' THEN
        IF v_gateway_name IS NULL THEN
            RAISE EXCEPTION
                'gateway.name is required for CREATE_NEW';
        END IF;

        IF v_gateway_model_id IS NULL THEN
            RAISE EXCEPTION
                'gateway.gateway_model_id is required for CREATE_NEW';
        END IF;

        IF NOT EXISTS
        (
            SELECT 1
            FROM metadata.gateway_models gm
            WHERE gm.id = v_gateway_model_id
        )
        THEN
            RAISE EXCEPTION
                'Unknown gateway model UUID: %',
                v_gateway_model_id;
        END IF;

    ELSE
        IF v_existing_gateway_id IS NULL THEN
            RAISE EXCEPTION
                'gateway.existing_gateway_id is required for USE_EXISTING';
        END IF;
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize device fields.
    --------------------------------------------------------------------------

    v_device_mode :=
        upper
        (
            COALESCE
            (
                NULLIF(
                    btrim(
                        p_request #>> '{device,mode}'
                    ),
                    ''
                ),
                'CREATE_NEW'
            )
        );

    IF v_device_mode NOT IN
    (
        'CREATE_NEW',
        'USE_EXISTING'
    )
    THEN
        RAISE EXCEPTION
            'device.mode must be CREATE_NEW or USE_EXISTING';
    END IF;

    BEGIN
        v_existing_device_id :=
            NULLIF
            (
                btrim(
                    p_request #>>
                    '{device,existing_device_id}'
                ),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'device.existing_device_id must be a valid UUID';
    END;

    v_device_name :=
        NULLIF(
            btrim(
                p_request #>> '{device,name}'
            ),
            ''
        );

    v_device_external_id :=
        upper
        (
            NULLIF
            (
                btrim(
                    p_request #>> '{device,external_id}'
                ),
                ''
            )
        );

    BEGIN
        v_device_model_id :=
            NULLIF(
                btrim(
                    p_request #>> '{device,device_model_id}'
                ),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'device.device_model_id must be a valid UUID';
    END;

    v_device_type :=
        NULLIF(
            btrim(
                p_request #>> '{device,device_type}'
            ),
            ''
        );

    BEGIN
        v_device_category_id :=
            NULLIF
            (
                btrim(
                    p_request #>>
                    '{device,device_category_id}'
                ),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'device.device_category_id must be a valid UUID';
    END;

    v_device_firmware_version :=
        NULLIF(
            btrim(
                p_request #>> '{device,firmware_version}'
            ),
            ''
        );

    v_device_protocol :=
        upper
        (
            NULLIF
            (
                btrim(
                    p_request #>> '{device,protocol}'
                ),
                ''
            )
        );

    v_profile_code :=
        upper
        (
            NULLIF
            (
                btrim(
                    p_request #>> '{device,profile_code}'
                ),
                ''
            )
        );

    v_device_serial_number :=
        NULLIF(
            btrim(
                p_request #>> '{device,serial_number}'
            ),
            ''
        );

    v_device_operational_policy :=
        upper
        (
            COALESCE
            (
                NULLIF(
                    btrim(
                        p_request #>> '{device,operational_policy}'
                    ),
                    ''
                ),
                'ASSET_ASSIGNED'
            )
        );

    IF v_device_mode = 'CREATE_NEW' THEN
        IF v_device_name IS NULL THEN
            RAISE EXCEPTION
                'device.name is required for CREATE_NEW';
        END IF;

        IF v_device_model_id IS NULL THEN
            RAISE EXCEPTION
                'device.device_model_id is required for CREATE_NEW';
        END IF;

        IF NOT EXISTS
        (
            SELECT 1
            FROM metadata.device_models dm
            WHERE dm.id = v_device_model_id
        )
        THEN
            RAISE EXCEPTION
                'Unknown device model UUID: %',
                v_device_model_id;
        END IF;

        IF v_device_category_id IS NULL
           AND v_device_type IS NULL
        THEN
            RAISE EXCEPTION
                'device.device_category_id is required for CREATE_NEW';
        END IF;

        IF v_device_protocol IS NULL THEN
            RAISE EXCEPTION
                'device.protocol is required for CREATE_NEW';
        END IF;

        IF v_profile_code IS NULL THEN
            RAISE EXCEPTION
                'device.profile_code is required for CREATE_NEW';
        END IF;

    ELSE
        IF v_existing_device_id IS NULL THEN
            RAISE EXCEPTION
                'device.existing_device_id is required for USE_EXISTING';
        END IF;
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize external identifier fields.
    --
    -- CREATE_NEW device:
    --   Identifier type and value are mandatory.
    --
    -- USE_EXISTING device:
    --   Identifier fields are optional. When supplied, they are used only
    --   to verify an existing identifier already belongs to the selected
    --   device. They are never created, changed, or transferred.
    --------------------------------------------------------------------------

    v_identifier_type :=
        upper
        (
            NULLIF
            (
                btrim(
                    p_request #>> '{identifier,type}'
                ),
                ''
            )
        );

    v_identifier_value :=
        NULLIF
        (
            btrim(
                p_request #>> '{identifier,value}'
            ),
            ''
        );

    IF
    (
        v_identifier_type IS NULL
        AND v_identifier_value IS NOT NULL
    )
    OR
    (
        v_identifier_type IS NOT NULL
        AND v_identifier_value IS NULL
    )
    THEN
        RAISE EXCEPTION
            'identifier.type and identifier.value must be supplied together';
    END IF;

    IF v_device_mode = 'CREATE_NEW' THEN
        IF v_identifier_type IS NULL THEN
            RAISE EXCEPTION
                'identifier.type is required for a new device';
        END IF;

        IF v_identifier_value IS NULL THEN
            RAISE EXCEPTION
                'identifier.value is required for a new device';
        END IF;
    END IF;

    IF v_identifier_type = 'MQTT_UID' THEN
        v_identifier_value := lower(v_identifier_value);
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize asset fields.
    --------------------------------------------------------------------------

    v_asset_mode :=
        upper
        (
            COALESCE
            (
                NULLIF(btrim(p_request #>> '{asset,mode}'), ''),
                'CREATE_NEW'
            )
        );

    IF v_asset_mode NOT IN ('CREATE_NEW', 'USE_EXISTING') THEN
        RAISE EXCEPTION
            'asset.mode must be CREATE_NEW or USE_EXISTING';
    END IF;

    BEGIN
        v_existing_asset_id :=
            NULLIF(
                btrim(p_request #>> '{asset,existing_asset_id}'),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'asset.existing_asset_id must be a valid UUID';
    END;

    v_asset_name :=
        NULLIF(btrim(p_request #>> '{asset,name}'), '');

    v_asset_external_id :=
        upper(
            NULLIF(
                btrim(
                    p_request #>> '{asset,external_id}'
                ),
                ''
            )
        );

    BEGIN
        v_asset_type_id :=
            NULLIF(
                btrim(p_request #>> '{asset,asset_type_id}'),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'asset.asset_type_id must be a valid UUID';
    END;

    v_metering_requirement :=
        upper
        (
            NULLIF
            (
                btrim
                (
                    p_request #>>
                    '{asset,metering_requirement}'
                ),
                ''
            )
        );

    v_relationship_type :=
        upper
        (
            COALESCE
            (
                NULLIF
                (
                    btrim
                    (
                        p_request #>> '{asset,relationship_type}'
                    ),
                    ''
                ),
                'PRIMARY_METER'
            )
        );

    v_asset_metadata :=
        COALESCE(p_request #> '{asset,metadata}', '{}'::JSONB);

    v_asset_lifecycle_status :=
        upper
        (
            COALESCE
            (
                NULLIF(
                    btrim(
                        p_request #>> '{asset,lifecycle_status}'
                    ),
                    ''
                ),
                'ACTIVE'
            )
        );

    BEGIN
        v_parent_asset_id :=
            NULLIF(
                btrim(p_request #>> '{asset,parent_asset_id}'),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'asset.parent_asset_id must be a valid UUID';
    END;

    IF v_asset_mode = 'CREATE_NEW' THEN
        IF v_asset_name IS NULL THEN
            RAISE EXCEPTION
                'asset.name is required for CREATE_NEW';
        END IF;

        IF v_asset_type_id IS NULL THEN
            RAISE EXCEPTION
                'asset.asset_type_id is required for CREATE_NEW';
        END IF;

        IF v_metering_requirement IS NULL THEN
            RAISE EXCEPTION
                'asset.metering_requirement is required for CREATE_NEW';
        END IF;

        IF v_metering_requirement NOT IN
        (
            'DIRECT_METER_REQUIRED',
            'DESCENDANT_COVERAGE_ALLOWED',
            'NOT_REQUIRED'
        )
        THEN
            RAISE EXCEPTION
                'asset.metering_requirement must be '
                'DIRECT_METER_REQUIRED, '
                'DESCENDANT_COVERAGE_ALLOWED, or '
                'NOT_REQUIRED';
        END IF;

        IF NOT EXISTS
        (
            SELECT 1
            FROM metadata.asset_types at
            WHERE at.id = v_asset_type_id
        )
        THEN
            RAISE EXCEPTION
                'Unknown asset type UUID: %',
                v_asset_type_id;
        END IF;

        IF v_asset_lifecycle_status NOT IN
        (
            'DRAFT',
            'COMMISSIONING',
            'ACTIVE',
            'INACTIVE',
            'DECOMMISSIONED'
        )
        THEN
            RAISE EXCEPTION
                'asset.lifecycle_status must be '
                'DRAFT, COMMISSIONING, ACTIVE, INACTIVE, or DECOMMISSIONED';
        END IF;
    ELSE
        IF v_existing_asset_id IS NULL THEN
            RAISE EXCEPTION
                'asset.existing_asset_id is required for USE_EXISTING';
        END IF;
    END IF;

    IF jsonb_typeof(v_asset_metadata) <> 'object' THEN
        RAISE EXCEPTION 'asset.metadata must be a JSON object';
    END IF;


    --------------------------------------------------------------------------
    -- Optional Grafana organization ID.
    --------------------------------------------------------------------------

    BEGIN
        v_grafana_org_id :=
            NULLIF(p_request ->> 'grafana_org_id', '')::BIGINT;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'grafana_org_id must be a positive integer';
    END;

    IF v_grafana_org_id IS NOT NULL
       AND v_grafana_org_id <= 0
    THEN
        RAISE EXCEPTION 'grafana_org_id must be greater than zero';
    END IF;


    --------------------------------------------------------------------------
    -- Organization selection or creation.
    --
    -- CREATE_NEW:
    --   Inserts a genuinely new organization and rejects an existing code.
    --
    -- USE_EXISTING:
    --   Loads the selected active organization without modifying it.
    --------------------------------------------------------------------------

    IF v_organization_mode = 'USE_EXISTING' THEN

        -- Serialize concurrent operations against the same organization UUID.
        PERFORM pg_advisory_xact_lock
        (
            hashtext(v_existing_organization_id::TEXT)
        );

        SELECT
            o.id,
            o.name,
            o.code,
            o.description
        INTO
            v_organization_id,
            v_organization_name,
            v_organization_code,
            v_organization_description
        FROM metadata.organizations o
        WHERE o.id = v_existing_organization_id
          AND o.is_active = TRUE;

        IF v_organization_id IS NULL THEN
            RAISE EXCEPTION
                'Existing active organization % was not found',
                v_existing_organization_id;
        END IF;

    ELSE

        -- Serialize concurrent creation attempts using the organization code.
        PERFORM pg_advisory_xact_lock
        (
            hashtext(v_organization_code)
        );

        BEGIN
            INSERT INTO metadata.organizations
            (
                name,
                code,
                description,
                timezone,
                legal_name,
                locale,
                lifecycle_status,
                primary_contact,
                address,
                notes,
                is_active
            )
            VALUES
            (
                v_organization_name,
                v_organization_code,
                v_organization_description,
                v_organization_timezone,
                v_organization_legal_name,
                v_organization_locale,
                v_organization_lifecycle_status,
                v_organization_primary_contact,
                v_organization_address,
                v_organization_notes,
                (v_organization_lifecycle_status = 'ACTIVE')
            )
            RETURNING id
            INTO v_organization_id;

        EXCEPTION
            WHEN unique_violation THEN
                RAISE EXCEPTION
                    'Organization code % already exists; use USE_EXISTING instead',
                    v_organization_code;
        END;
    END IF;


    --------------------------------------------------------------------------
    -- Site selection or creation.
    --
    -- CREATE_NEW:
    --   Inserts a new site under the resolved organization.
    --
    -- USE_EXISTING:
    --   Validates that the selected active site belongs to the resolved
    --   organization and preserves all stored site attributes.
    --------------------------------------------------------------------------

    IF v_site_mode = 'USE_EXISTING' THEN

        SELECT
            s.id,
            s.name,
            s.code,
            s.timezone,
            s.address
        INTO
            v_site_id,
            v_site_name,
            v_site_code,
            v_site_timezone,
            v_site_address
        FROM metadata.sites s
        WHERE s.id = v_existing_site_id
          AND s.organization_id = v_organization_id
          AND s.is_active = TRUE;

        IF v_site_id IS NULL THEN
            RAISE EXCEPTION
                'Existing active site % was not found under organization %',
                v_existing_site_id,
                v_organization_id;
        END IF;

    ELSE

        BEGIN
            INSERT INTO metadata.sites
            (
                organization_id,
                name,
                code,
                timezone,
                address,
                is_active
            )
            VALUES
            (
                v_organization_id,
                v_site_name,
                v_site_code,
                v_site_timezone,
                v_site_address,
                TRUE
            )
            RETURNING id
            INTO v_site_id;

        EXCEPTION
            WHEN unique_violation THEN
                RAISE EXCEPTION
                    'Site code % already exists under organization %; use USE_EXISTING instead',
                    v_site_code,
                    v_organization_id;
        END;
    END IF;


    --------------------------------------------------------------------------
    -- Optional physical hierarchy.
    --------------------------------------------------------------------------

    v_space_id := NULL;

    IF v_location_mode = 'USE_EXISTING_SPACE' THEN
        SELECT
            sp.id,
            f.id,
            b.id
        INTO
            v_space_id,
            v_floor_id,
            v_building_id
        FROM metadata.spaces sp
        JOIN metadata.floors f
          ON f.id = sp.floor_id
        JOIN metadata.buildings b
          ON b.id = f.building_id
        WHERE sp.id = v_existing_space_id
          AND sp.organization_id = v_organization_id
          AND b.site_id = v_site_id;

        IF v_space_id IS NULL THEN
            RAISE EXCEPTION
                'Existing space % was not found in organization % and site %',
                v_existing_space_id,
                v_organization_code,
                v_site_code;
        END IF;

    ELSIF v_location_mode = 'CREATE_LOCATION' THEN
        INSERT INTO metadata.buildings
        (
            organization_id,
            site_id,
            name,
            code
        )
        VALUES
        (
            v_organization_id,
            v_site_id,
            v_building_name,
            v_building_code
        )
        ON CONFLICT (site_id, code)
        DO UPDATE SET
            organization_id = EXCLUDED.organization_id,
            name            = EXCLUDED.name,
            updated_at      = now()
        RETURNING id
        INTO v_building_id;

        INSERT INTO metadata.floors
        (
            organization_id,
            building_id,
            name,
            code
        )
        VALUES
        (
            v_organization_id,
            v_building_id,
            v_floor_name,
            v_floor_code
        )
        ON CONFLICT (building_id, code)
        DO UPDATE SET
            organization_id = EXCLUDED.organization_id,
            name            = EXCLUDED.name,
            updated_at      = now()
        RETURNING id
        INTO v_floor_id;

        INSERT INTO metadata.spaces
        (
            organization_id,
            floor_id,
            name,
            code
        )
        VALUES
        (
            v_organization_id,
            v_floor_id,
            v_space_name,
            v_space_code
        )
        ON CONFLICT (floor_id, code)
        DO UPDATE SET
            organization_id = EXCLUDED.organization_id,
            name            = EXCLUDED.name,
            updated_at      = now()
        RETURNING id
        INTO v_space_id;
    END IF;


    --------------------------------------------------------------------------
    -- Gateway selection or creation.
    --
    -- CREATE_NEW:
    --   Resolves or creates the gateway model, then inserts a new gateway.
    --   The resolved physical space is assigned to gateway.space_id.
    --
    -- USE_EXISTING:
    --   Validates that the selected gateway belongs to the resolved
    --   organization and site. Existing gateway attributes are preserved.
    --------------------------------------------------------------------------

    IF v_gateway_mode = 'USE_EXISTING' THEN

        SELECT
            g.id,
            g.name,
            g.external_id,
            g.gateway_model_id
        INTO
            v_gateway_id,
            v_gateway_name,
            v_gateway_external_id,
            v_gateway_model_id
        FROM metadata.gateways g
        WHERE g.id = v_existing_gateway_id
          AND g.organization_id = v_organization_id
          AND g.site_id = v_site_id;

        IF v_gateway_id IS NULL THEN
            RAISE EXCEPTION
                'Existing gateway % was not found under organization % and site %',
                v_existing_gateway_id,
                v_organization_id,
                v_site_id;
        END IF;

    ELSE

        ----------------------------------------------------------------------
        -- Gateway model is a strict foreign key into the controlled
        -- metadata.gateway_models catalog -- already validated to exist
        -- above. No vendor/model text resolution or auto-create.
        ----------------------------------------------------------------------

        v_gateway_external_id :=
            admin.recommend_available_identifier
            (
                'GATEWAY',
                v_gateway_name,
                v_organization_id,
                v_site_id,
                NULL,
                NULL,
                NULL
            );

        BEGIN
            INSERT INTO metadata.gateways
            (
                organization_id,
                site_id,
                gateway_model_id,
                name,
                external_id,
                building_id,
                floor_id,
                space_id
            )
            VALUES
            (
                v_organization_id,
                v_site_id,
                v_gateway_model_id,
                v_gateway_name,
                v_gateway_external_id,
                v_building_id,
                v_floor_id,
                v_space_id
            )
            RETURNING id
            INTO v_gateway_id;

        EXCEPTION
            WHEN unique_violation THEN
                RAISE EXCEPTION
                    'Gateway external ID % already exists under organization %; use USE_EXISTING instead',
                    v_gateway_external_id,
                    v_organization_id;
        END;
    END IF;


    --------------------------------------------------------------------------
    -- Device selection or creation.
    --
    -- CREATE_NEW:
    --   Resolves the controlled category, relationship compatibility,
    --   device model, and active compatible profile before inserting.
    --
    -- USE_EXISTING:
    --   Validates that the selected device belongs to the resolved
    --   organization and gateway. Existing device attributes are preserved.
    --------------------------------------------------------------------------

    IF v_device_mode = 'USE_EXISTING' THEN

        SELECT
            d.id,
            d.name,
            d.external_id,
            d.device_model_id,
            d.firmware_version,
            d.protocol,
            d.profile_id,
            dm.device_category_id,
            dc.name,
            dp.profile_code
        INTO
            v_device_id,
            v_device_name,
            v_device_external_id,
            v_device_model_id,
            v_device_firmware_version,
            v_device_protocol,
            v_profile_id,
            v_device_category_id,
            v_device_category_name,
            v_profile_code
        FROM metadata.devices d
        LEFT JOIN metadata.device_models dm
          ON dm.id = d.device_model_id
        LEFT JOIN config.device_categories dc
          ON dc.id = dm.device_category_id
        LEFT JOIN config.device_profiles dp
          ON dp.id = d.profile_id
        WHERE d.id = v_existing_device_id
          AND d.organization_id = v_organization_id
          AND d.gateway_id = v_gateway_id;

        IF v_device_id IS NULL THEN
            RAISE EXCEPTION
                'Existing device % was not found under organization % and gateway %',
                v_existing_device_id,
                v_organization_id,
                v_gateway_id;
        END IF;

        IF v_device_category_id IS NULL
           OR v_device_category_name IS NULL
        THEN
            RAISE EXCEPTION
                'Existing device % does not have a controlled device category',
                v_existing_device_id;
        END IF;

        IF v_profile_id IS NULL
           OR v_profile_code IS NULL
        THEN
            RAISE EXCEPTION
                'Existing device % does not have an active onboarding profile',
                v_existing_device_id;
        END IF;

    ELSE

        ----------------------------------------------------------------------
        -- Controlled device category.
        ----------------------------------------------------------------------

        IF v_device_category_id IS NOT NULL THEN
            SELECT
                dc.id,
                dc.name
            INTO
                v_device_category_id,
                v_device_category_name
            FROM config.device_categories dc
            WHERE dc.id = v_device_category_id;
        ELSE
            SELECT
                dc.id,
                dc.name
            INTO
                v_device_category_id,
                v_device_category_name
            FROM config.device_categories dc
            WHERE lower(dc.name) = lower(v_device_type)
            ORDER BY dc.created_at, dc.id
            LIMIT 1;
        END IF;

        IF v_device_category_id IS NULL THEN
            RAISE EXCEPTION
                'Controlled device category was not found';
        END IF;

        -- Keep the legacy text value synchronized during the transition.
        v_device_type := v_device_category_name;


        ----------------------------------------------------------------------
        -- Controlled category-to-asset relationship compatibility.
        ----------------------------------------------------------------------

        IF v_device_category_name = 'Energy Meter' THEN
            IF v_relationship_type NOT IN
            (
                'PRIMARY_METER',
                'SECONDARY_METER',
                'SECONDARY_METER'
            )
            THEN
                RAISE EXCEPTION
                    'Relationship % is not valid for device category %',
                    v_relationship_type,
                    v_device_category_name;
            END IF;

        ELSIF v_device_category_name = 'Environmental Sensor' THEN
            IF v_relationship_type NOT IN
            (
                'TEMPERATURE_SENSOR',
                'HUMIDITY_SENSOR'
            )
            THEN
                RAISE EXCEPTION
                    'Relationship % is not valid for device category %',
                    v_relationship_type,
                    v_device_category_name;
            END IF;

        ELSIF v_device_category_name = 'Temperature Sensor' THEN
            IF v_relationship_type <> 'TEMPERATURE_SENSOR' THEN
                RAISE EXCEPTION
                    'Relationship % is not valid for device category %',
                    v_relationship_type,
                    v_device_category_name;
            END IF;

        ELSIF v_device_category_name = 'Flow Meter' THEN
            IF v_relationship_type <> 'FLOW_SENSOR' THEN
                RAISE EXCEPTION
                    'Relationship % is not valid for device category %',
                    v_relationship_type,
                    v_device_category_name;
            END IF;

        ELSIF v_device_category_name = 'Pressure Sensor' THEN
            IF v_relationship_type <> 'PRESSURE_SENSOR' THEN
                RAISE EXCEPTION
                    'Relationship % is not valid for device category %',
                    v_relationship_type,
                    v_device_category_name;
            END IF;

        ELSIF v_device_category_name = 'Digital Input Module' THEN
            IF v_relationship_type NOT IN
            (
                'STATUS_INPUT',
                'RUN_STATUS',
                'FAULT_STATUS'
            )
            THEN
                RAISE EXCEPTION
                    'Relationship % is not valid for device category %',
                    v_relationship_type,
                    v_device_category_name;
            END IF;

        ELSIF v_device_category_name = 'BMS Controller' THEN
            IF v_relationship_type <> 'CONTROLLER' THEN
                RAISE EXCEPTION
                    'Relationship % is not valid for device category %',
                    v_relationship_type,
                    v_device_category_name;
            END IF;

        ELSIF v_device_category_name = 'PLC' THEN
            IF v_relationship_type NOT IN
            (
                'CONTROLLER',
                'STATUS_INPUT',
                'RUN_STATUS',
                'FAULT_STATUS'
            )
            THEN
                RAISE EXCEPTION
                    'Relationship % is not valid for device category %',
                    v_relationship_type,
                    v_device_category_name;
            END IF;

        ELSIF v_device_category_name = 'Gateway' THEN
            RAISE EXCEPTION
                'Device category Gateway cannot be attached directly to an asset';

        ELSE
            RAISE EXCEPTION
                'No asset relationship rules are configured for device category %',
                v_device_category_name;
        END IF;


        ----------------------------------------------------------------------
        -- Device model is a strict foreign key into the controlled
        -- metadata.device_models catalog -- already validated to exist
        -- above. Confirm it belongs to the selected category and keep the
        -- legacy device_type compatibility column synchronized.
        ----------------------------------------------------------------------

        SELECT dm.device_category_id
        INTO v_existing_model_category_id
        FROM metadata.device_models dm
        WHERE dm.id = v_device_model_id;

        IF v_existing_model_category_id <> v_device_category_id THEN
            RAISE EXCEPTION
                'The selected device model does not belong to the '
                'selected device category';
        END IF;

        UPDATE metadata.device_models
        SET device_type = v_device_category_name
        WHERE id = v_device_model_id
          AND device_type IS DISTINCT FROM v_device_category_name;


        ----------------------------------------------------------------------
        -- Active payload profile.
        ----------------------------------------------------------------------

        SELECT dp.id
        INTO v_profile_id
        FROM config.device_profiles dp
        WHERE dp.profile_code = v_profile_code
          AND dp.is_active = TRUE;

        IF v_profile_id IS NULL THEN
            RAISE EXCEPTION
                'Active device profile not found: %',
                v_profile_code;
        END IF;

        IF NOT EXISTS
        (
            SELECT 1
            FROM config.device_profile_categories dpc
            WHERE dpc.profile_id = v_profile_id
              AND dpc.device_category_id = v_device_category_id
        )
        THEN
            RAISE EXCEPTION
                'Device profile % is not compatible with device category %',
                v_profile_code,
                v_device_category_name;
        END IF;


        ----------------------------------------------------------------------
        -- Insert new device.
        ----------------------------------------------------------------------

        v_device_external_id :=
            admin.recommend_available_identifier
            (
                'DEVICE',
                v_device_name,
                v_organization_id,
                v_site_id,
                NULL,
                NULL,
                NULL
            );

        BEGIN
            INSERT INTO metadata.devices
            (
                organization_id,
                gateway_id,
                device_model_id,
                name,
                external_id,
                serial_number,
                firmware_version,
                protocol,
                profile_id,
                operational_policy
            )
            VALUES
            (
                v_organization_id,
                v_gateway_id,
                v_device_model_id,
                v_device_name,
                v_device_external_id,
                v_device_serial_number,
                v_device_firmware_version,
                v_device_protocol,
                v_profile_id,
                v_device_operational_policy
            )
            RETURNING id
            INTO v_device_id;

        EXCEPTION
            WHEN unique_violation THEN
                RAISE EXCEPTION
                    'Device external ID % already exists under organization %; use USE_EXISTING instead',
                    v_device_external_id,
                    v_organization_id;
        END;
    END IF;


    --------------------------------------------------------------------------
    -- Validate relationship compatibility for both new and existing devices.
    --------------------------------------------------------------------------

    IF v_device_category_name = 'Energy Meter' THEN
        IF v_relationship_type NOT IN
        (
            'PRIMARY_METER',
            'SECONDARY_METER',
            'SECONDARY_METER'
        )
        THEN
            RAISE EXCEPTION
                'Relationship % is not valid for device category %',
                v_relationship_type,
                v_device_category_name;
        END IF;

    ELSIF v_device_category_name = 'Environmental Sensor' THEN
        IF v_relationship_type NOT IN
        (
            'TEMPERATURE_SENSOR',
            'HUMIDITY_SENSOR'
        )
        THEN
            RAISE EXCEPTION
                'Relationship % is not valid for device category %',
                v_relationship_type,
                v_device_category_name;
        END IF;

    ELSIF v_device_category_name = 'Temperature Sensor' THEN
        IF v_relationship_type <> 'TEMPERATURE_SENSOR' THEN
            RAISE EXCEPTION
                'Relationship % is not valid for device category %',
                v_relationship_type,
                v_device_category_name;
        END IF;

    ELSIF v_device_category_name = 'Flow Meter' THEN
        IF v_relationship_type <> 'FLOW_SENSOR' THEN
            RAISE EXCEPTION
                'Relationship % is not valid for device category %',
                v_relationship_type,
                v_device_category_name;
        END IF;

    ELSIF v_device_category_name = 'Pressure Sensor' THEN
        IF v_relationship_type <> 'PRESSURE_SENSOR' THEN
            RAISE EXCEPTION
                'Relationship % is not valid for device category %',
                v_relationship_type,
                v_device_category_name;
        END IF;

    ELSIF v_device_category_name = 'Digital Input Module' THEN
        IF v_relationship_type NOT IN
        (
            'STATUS_INPUT',
            'RUN_STATUS',
            'FAULT_STATUS'
        )
        THEN
            RAISE EXCEPTION
                'Relationship % is not valid for device category %',
                v_relationship_type,
                v_device_category_name;
        END IF;

    ELSIF v_device_category_name = 'BMS Controller' THEN
        IF v_relationship_type <> 'CONTROLLER' THEN
            RAISE EXCEPTION
                'Relationship % is not valid for device category %',
                v_relationship_type,
                v_device_category_name;
        END IF;

    ELSIF v_device_category_name = 'PLC' THEN
        IF v_relationship_type NOT IN
        (
            'CONTROLLER',
            'STATUS_INPUT',
            'RUN_STATUS',
            'FAULT_STATUS'
        )
        THEN
            RAISE EXCEPTION
                'Relationship % is not valid for device category %',
                v_relationship_type,
                v_device_category_name;
        END IF;

    ELSIF v_device_category_name = 'Gateway' THEN
        RAISE EXCEPTION
            'Device category Gateway cannot be attached directly to an asset';

    ELSE
        RAISE EXCEPTION
            'No asset relationship rules are configured for device category %',
            v_device_category_name;
    END IF;


    --------------------------------------------------------------------------
    -- External device identifier.
    --
    -- CREATE_NEW:
    --   Creates the required external identifier only when it is not already
    --   owned by another device.
    --
    -- USE_EXISTING:
    --   Preserves all identifiers. Optional supplied values are verification
    --   inputs only and must already belong to the selected device.
    --------------------------------------------------------------------------

    IF v_device_mode = 'CREATE_NEW' THEN

        SELECT di.device_id
        INTO v_existing_identifier_device_id
        FROM metadata.device_identifiers di
        WHERE di.identifier_type = v_identifier_type
          AND
          (
              CASE
                  WHEN v_identifier_type = 'MQTT_UID'
                  THEN lower(di.identifier_value)
                  ELSE di.identifier_value
              END
          ) = v_identifier_value
        ORDER BY di.created_at, di.id
        LIMIT 1;

        IF v_existing_identifier_device_id IS NOT NULL THEN
            RAISE EXCEPTION
                'Identifier %:% is already assigned to device %',
                v_identifier_type,
                v_identifier_value,
                v_existing_identifier_device_id;
        END IF;

        INSERT INTO metadata.device_identifiers
        (
            device_id,
            identifier_type,
            identifier_value
        )
        VALUES
        (
            v_device_id,
            v_identifier_type,
            v_identifier_value
        );

    ELSIF v_identifier_type IS NOT NULL THEN

        SELECT di.device_id
        INTO v_existing_identifier_device_id
        FROM metadata.device_identifiers di
        WHERE di.identifier_type = v_identifier_type
          AND
          (
              CASE
                  WHEN v_identifier_type = 'MQTT_UID'
                  THEN lower(di.identifier_value)
                  ELSE di.identifier_value
              END
          ) = v_identifier_value
        ORDER BY di.created_at, di.id
        LIMIT 1;

        IF v_existing_identifier_device_id IS NULL THEN
            RAISE EXCEPTION
                'Identifier %:% does not exist for the selected device',
                v_identifier_type,
                v_identifier_value;
        END IF;

        IF v_existing_identifier_device_id <> v_device_id THEN
            RAISE EXCEPTION
                'Identifier %:% belongs to device %, not selected device %',
                v_identifier_type,
                v_identifier_value,
                v_existing_identifier_device_id,
                v_device_id;
        END IF;
    END IF;


    --------------------------------------------------------------------------
    -- Asset selection or creation.
    --------------------------------------------------------------------------

    IF v_asset_mode = 'USE_EXISTING' THEN
        SELECT
            a.id,
            a.name,
            a.external_id,
            a.asset_type_id,
            a.metering_requirement
        INTO
            v_asset_id,
            v_asset_name,
            v_asset_external_id,
            v_asset_type_id,
            v_metering_requirement
        FROM metadata.assets a
        WHERE a.id = v_existing_asset_id
          AND a.organization_id = v_organization_id
          AND a.site_id = v_site_id;

        IF v_asset_id IS NULL THEN
            RAISE EXCEPTION
                'Existing asset % was not found in organization % and site %',
                v_existing_asset_id,
                v_organization_code,
                v_site_code;
        END IF;

    ELSE
        IF v_parent_asset_id IS NOT NULL THEN
            IF NOT EXISTS
            (
                SELECT 1
                FROM metadata.assets pa
                WHERE pa.id = v_parent_asset_id
                  AND pa.organization_id = v_organization_id
                  AND pa.site_id = v_site_id
            )
            THEN
                RAISE EXCEPTION
                    'asset.parent_asset_id % was not found in organization % and site %',
                    v_parent_asset_id,
                    v_organization_id,
                    v_site_id;
            END IF;
        END IF;

        v_asset_external_id :=
            admin.recommend_available_identifier
            (
                'ASSET',
                v_asset_name,
                v_organization_id,
                v_site_id,
                NULL,
                NULL,
                NULL
            );

        INSERT INTO metadata.assets
        (
            organization_id,
            site_id,
            asset_type_id,
            parent_asset_id,
            name,
            external_id,
            manufacturer,
            model,
            serial_number,
            status,
            lifecycle_status,
            metering_requirement,
            metadata,
            building_id,
            floor_id,
            space_id
        )
        VALUES
        (
            v_organization_id,
            v_site_id,
            v_asset_type_id,
            v_parent_asset_id,
            v_asset_name,
            v_asset_external_id,
            NULL,
            NULL,
            NULL,
            'active',
            v_asset_lifecycle_status,
            v_metering_requirement,
            v_asset_metadata,
            v_building_id,
            v_floor_id,
            v_space_id
        )
        RETURNING id
        INTO v_asset_id;
    END IF;


    --------------------------------------------------------------------------
    -- Asset-device relationship.
    --
    -- The canonical partial unique index allows a device to be PRIMARY_METER
    -- for at most one asset.
    --------------------------------------------------------------------------

    IF v_relationship_type = 'PRIMARY_METER' THEN
        SELECT ad.asset_id
        INTO v_existing_primary_asset_id
        FROM metadata.asset_devices ad
        WHERE ad.device_id = v_device_id
          AND ad.relationship_type = 'PRIMARY_METER'
        ORDER BY ad.created_at, ad.id
        LIMIT 1;

        IF v_existing_primary_asset_id IS NOT NULL
           AND v_existing_primary_asset_id <> v_asset_id
        THEN
            RAISE EXCEPTION
                'Device % is already PRIMARY_METER for asset %',
                v_device_id,
                v_existing_primary_asset_id;
        END IF;

        IF EXISTS
        (
            SELECT 1
            FROM metadata.asset_devices ad
            WHERE ad.asset_id = v_asset_id
              AND ad.relationship_type = 'PRIMARY_METER'
              AND ad.device_id <> v_device_id
        )
        THEN
            RAISE EXCEPTION
                'Asset % already has a different PRIMARY_METER',
                v_asset_id;
        END IF;
    END IF;

    INSERT INTO metadata.asset_devices
    (
        asset_id,
        device_id,
        relationship_type
    )
    VALUES
    (
        v_asset_id,
        v_device_id,
        v_relationship_type
    )
    ON CONFLICT
        (asset_id, device_id, relationship_type)
    DO NOTHING;


    --------------------------------------------------------------------------
    -- Optional Grafana organization mapping.
    --
    -- Reject both forms of cross-tenant reassignment:
    --
    --   1. EMS organization already mapped to a different Grafana org.
    --   2. Grafana org already mapped to a different EMS organization.
    --------------------------------------------------------------------------

    IF v_grafana_org_id IS NOT NULL THEN
        SELECT gom.grafana_org_id
        INTO v_existing_grafana_org_id
        FROM metadata.grafana_organization_map gom
        WHERE gom.organization_id = v_organization_id;

        IF v_existing_grafana_org_id IS NOT NULL
           AND v_existing_grafana_org_id <> v_grafana_org_id
        THEN
            RAISE EXCEPTION
                'EMS organization % is already mapped to Grafana org %',
                v_organization_id,
                v_existing_grafana_org_id;
        END IF;

        SELECT gom.organization_id
        INTO v_existing_grafana_org_owner
        FROM metadata.grafana_organization_map gom
        WHERE gom.grafana_org_id = v_grafana_org_id;

        IF v_existing_grafana_org_owner IS NOT NULL
           AND v_existing_grafana_org_owner <> v_organization_id
        THEN
            RAISE EXCEPTION
                'Grafana org % is already mapped to EMS organization %',
                v_grafana_org_id,
                v_existing_grafana_org_owner;
        END IF;

        INSERT INTO metadata.grafana_organization_map
        (
            grafana_org_id,
            organization_id,
            is_active
        )
        VALUES
        (
            v_grafana_org_id,
            v_organization_id,
            TRUE
        )
        ON CONFLICT (grafana_org_id)
        DO UPDATE SET
            organization_id = EXCLUDED.organization_id,
            is_active        = TRUE,
            updated_at       = now();
    END IF;


    --------------------------------------------------------------------------
    -- Build result and audit successful completion.
    --------------------------------------------------------------------------

    v_result :=
        jsonb_build_object
        (
            'organization_id',  v_organization_id,
            'organization_code', v_organization_code,
            'site_id',          v_site_id,
            'site_code',        v_site_code,
            'location_mode',    v_location_mode,
            'building_id',      v_building_id,
            'floor_id',         v_floor_id,
            'space_id',         v_space_id,
            'gateway_model_id', v_gateway_model_id,
            'gateway_id',       v_gateway_id,
            'device_model_id',  v_device_model_id,
            'device_category_id', v_device_category_id,
            'device_category_name', v_device_category_name,
            'profile_id',       v_profile_id,
            'profile_code',     v_profile_code,
            'device_id',        v_device_id,
            'device_external_id', v_device_external_id,
            'identifier_type',  v_identifier_type,
            'identifier_value', v_identifier_value,
            'asset_mode',       v_asset_mode,
            'asset_id',         v_asset_id,
            'asset_name',       v_asset_name,
            'metering_requirement', v_metering_requirement,
            'relationship_type', v_relationship_type,
            'grafana_org_id',   v_grafana_org_id
        );

    INSERT INTO admin.onboarding_audit
    (
        requested_by,
        request_payload,
        result_payload
    )
    VALUES
    (
        COALESCE(NULLIF(btrim(p_requested_by), ''), current_user),
        p_request,
        v_result
    );

    RETURN v_result;
END;
$function$;
