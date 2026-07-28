-- ============================================================================
-- File:
--   76_admin_onboarding_contract.sql
--
-- Purpose:
--   Provide the least-privilege database contract used by the EMS
--   Administration Portal.
--
-- Security model:
--
--   Browser
--       -> EMS Administration Portal
--       -> PostgreSQL login role: ems_app
--       -> admin.onboard_energy_asset(...)
--       -> metadata tables
--
--   The ems_app role receives:
--
--       1. USAGE on the admin schema.
--       2. SELECT on controlled onboarding lookup views.
--       3. EXECUTE on the onboarding function.
--
--   The ems_app role does not receive unrestricted INSERT, UPDATE, or DELETE
--   privileges on metadata, config, telemetry, or analytics tables.
--
-- V1 scope:
--
--   One request creates or reconciles:
--
--       Organization
--       Site
--       Gateway model
--       Gateway
--       Device model
--       Device
--       Device identifier
--       Root asset
--       Asset-device assignment
--       Optional Grafana organization mapping
--
--   Grafana organization creation itself remains an application-level action
--   performed through the Grafana Admin API. The numeric Grafana org ID may
--   then be supplied to this function.
--
-- Idempotency:
--
--   The schema objects are safe to recreate.
--   Repeating the same onboarding request reconciles existing records instead
--   of creating duplicates.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Successful onboarding audit records.
--
-- Failed function calls roll back with their transaction and must be logged by
-- the application layer. Successful requests are retained here for operational
-- traceability.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS admin.onboarding_audit
(
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requested_by      TEXT NOT NULL,
    request_payload   JSONB NOT NULL,
    result_payload    JSONB NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE admin.onboarding_audit IS
'Successful EMS metadata onboarding operations initiated through the administration contract.';

COMMENT ON COLUMN admin.onboarding_audit.requested_by IS
'Application user or service identity that submitted the onboarding request.';

COMMENT ON COLUMN admin.onboarding_audit.request_payload IS
'Original validated onboarding request supplied to the database function.';

COMMENT ON COLUMN admin.onboarding_audit.result_payload IS
'Identifiers and normalized values returned by the completed onboarding operation.';


CREATE INDEX IF NOT EXISTS idx_onboarding_audit_created_at
    ON admin.onboarding_audit
    USING btree (created_at DESC);


-- ----------------------------------------------------------------------------
-- 2. Controlled lookup views used by onboarding forms.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW admin.v_active_device_profiles
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    dp.id,
    dp.profile_code,
    dp.profile_name,
    dp.manufacturer,
    dp.model,
    dp.firmware_version,
    dp.protocol_id,
    dp.description,

    COALESCE
    (
        array_agg(dc.id ORDER BY dc.name)
            FILTER (WHERE dc.id IS NOT NULL),
        ARRAY[]::UUID[]
    ) AS device_category_ids,

    COALESCE
    (
        array_agg(dc.name ORDER BY dc.name)
            FILTER (WHERE dc.id IS NOT NULL),
        ARRAY[]::TEXT[]
    ) AS device_category_names

FROM config.device_profiles dp

LEFT JOIN config.device_profile_categories dpc
  ON dpc.profile_id = dp.id

LEFT JOIN config.device_categories dc
  ON dc.id = dpc.device_category_id

WHERE dp.is_active = TRUE

GROUP BY
    dp.id,
    dp.profile_code,
    dp.profile_name,
    dp.manufacturer,
    dp.model,
    dp.firmware_version,
    dp.protocol_id,
    dp.description;


COMMENT ON VIEW admin.v_active_device_profiles IS
'Active device profiles and their controlled compatible device categories for EMS onboarding.';


CREATE OR REPLACE VIEW admin.v_asset_types
WITH
(
    security_barrier = TRUE
)
AS
WITH ranked_asset_types AS
(
    SELECT
        at.id,
        at.name,
        at.description,

        COUNT(a.id) AS referenced_asset_count,

        ROW_NUMBER() OVER
        (
            PARTITION BY lower(at.name)
            ORDER BY
                COUNT(a.id) DESC,
                at.id
        ) AS asset_type_rank

    FROM metadata.asset_types at

    LEFT JOIN metadata.assets a
      ON a.asset_type_id = at.id

    GROUP BY
        at.id,
        at.name,
        at.description
)
SELECT
    id,
    name,
    description
FROM ranked_asset_types
WHERE asset_type_rank = 1;


COMMENT ON VIEW admin.v_asset_types IS
'Asset types available for selection during EMS onboarding.';


CREATE OR REPLACE VIEW admin.v_buildings
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    b.id,
    b.organization_id,
    o.code AS organization_code,
    b.site_id,
    s.code AS site_code,
    b.code AS building_code,
    b.name AS building_name,
    b.created_at
FROM metadata.buildings b
JOIN metadata.organizations o
  ON o.id = b.organization_id
JOIN metadata.sites s
  ON s.id = b.site_id;


COMMENT ON VIEW admin.v_buildings IS
'Tenant-aware building catalog for controlled onboarding selection.';


CREATE OR REPLACE VIEW admin.v_floors
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    f.id,
    f.organization_id,
    o.code AS organization_code,
    b.site_id,
    s.code AS site_code,
    f.building_id,
    b.code AS building_code,
    b.name AS building_name,
    f.code AS floor_code,
    f.name AS floor_name,
    f.created_at
FROM metadata.floors f
JOIN metadata.buildings b
  ON b.id = f.building_id
JOIN metadata.organizations o
  ON o.id = f.organization_id
JOIN metadata.sites s
  ON s.id = b.site_id;


COMMENT ON VIEW admin.v_floors IS
'Tenant-aware floor catalog for controlled onboarding selection.';


CREATE OR REPLACE VIEW admin.v_spaces
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    sp.id,
    sp.organization_id,
    o.code AS organization_code,
    b.site_id,
    s.code AS site_code,
    sp.floor_id,
    f.code AS floor_code,
    f.name AS floor_name,
    f.building_id,
    b.code AS building_code,
    b.name AS building_name,
    sp.code AS space_code,
    sp.name AS space_name,
    sp.created_at
FROM metadata.spaces sp
JOIN metadata.floors f
  ON f.id = sp.floor_id
JOIN metadata.buildings b
  ON b.id = f.building_id
JOIN metadata.organizations o
  ON o.id = sp.organization_id
JOIN metadata.sites s
  ON s.id = b.site_id;


COMMENT ON VIEW admin.v_spaces IS
'Tenant-aware space catalog for controlled onboarding selection.';


CREATE OR REPLACE VIEW admin.v_assets
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    a.id,
    a.organization_id,
    o.code AS organization_code,
    a.site_id,
    s.code AS site_code,
    a.space_id,
    a.parent_asset_id,
    a.asset_type_id,
    at.name AS asset_type_name,
    a.name AS asset_name,
    a.status,
    a.created_at,
    a.metering_requirement
FROM metadata.assets a
JOIN metadata.organizations o
  ON o.id = a.organization_id
JOIN metadata.sites s
  ON s.id = a.site_id
LEFT JOIN metadata.asset_types at
  ON at.id = a.asset_type_id;


COMMENT ON VIEW admin.v_assets IS
'Tenant-aware operational asset catalog for controlled onboarding selection.';


CREATE OR REPLACE VIEW admin.v_gateway_models
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gm.id,
    gm.vendor,
    gm.model,
    gm.protocol,
    gm.created_at
FROM metadata.gateway_models gm;


COMMENT ON VIEW admin.v_gateway_models IS
'Existing gateway models available for reuse during EMS onboarding.';


CREATE OR REPLACE VIEW admin.v_device_categories
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    dc.id,
    dc.name,
    dc.description,
    dc.created_at
FROM config.device_categories dc;


COMMENT ON VIEW admin.v_device_categories IS
'Controlled categories for physical telemetry-producing devices.';


CREATE OR REPLACE VIEW admin.v_device_models
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    dm.id,
    dm.vendor,
    dm.model,
    dm.device_type,
    dm.created_at,
    dm.device_category_id,
    dc.name AS device_category_name
FROM metadata.device_models dm
JOIN config.device_categories dc
  ON dc.id = dm.device_category_id;


COMMENT ON VIEW admin.v_device_models IS
'Existing device models with their controlled device categories.';


-- ----------------------------------------------------------------------------
-- 3. Atomic organization-to-asset onboarding function.
--
-- Expected request document:
--
-- {
--   "organization": {
--     "name": "GOOD LUCK INC",
--     "code": "GOOD_LUCK_INC",
--     "description": "Production tenant"
--   },
--   "site": {
--     "name": "HOTEL HYDERABAD",
--     "code": "HOTEL_HYD",
--     "timezone": "Asia/Kolkata",
--     "address": {"full_address": "..."}
--   },
--   "gateway": {
--     "name": "ENISCOPE CHILLER PLANT",
--     "external_id": "ENI_CHLR_PLT",
--     "vendor": "ENISCOPE",
--     "model": "Eniscope Gateway",
--     "protocol": "MQTT"
--   },
--   "device": {
--     "name": "CHILLER 1",
--     "external_id": "CHLR_1",
--     "model_vendor": "ENISCOPE",
--     "model": "Eniscope Energy Meter",
--     "device_type": "Energy Meter",
--     "firmware_version": "1.5",
--     "protocol": "MQTT",
--     "profile_code": "ENERGY_METER_ENISCOPE_V1"
--   },
--   "identifier": {
--     "type": "MQTT_UID",
--     "value": "80:34:28:16:09:eb:00:01"
--   },
--   "asset": {
--     "name": "CHILLER 1",
--     "asset_type_id": "9fdaf45a-064c-4ee2-9462-4e89e7eaf38f",
--     "relationship_type": "PRIMARY_METER",
--     "metering_requirement": "DIRECT_METER_REQUIRED",
--     "metadata": {}
--   },
--   "grafana_org_id": 2
-- }
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.onboard_energy_asset
(
    p_request       JSONB,
    p_requested_by  TEXT DEFAULT current_user
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, metadata, config
AS
$$
DECLARE
    v_organization_name        TEXT;
    v_organization_code        TEXT;
    v_organization_description TEXT;

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

    v_gateway_name             TEXT;
    v_gateway_external_id      TEXT;
    v_gateway_vendor           TEXT;
    v_gateway_model            TEXT;
    v_gateway_protocol         TEXT;

    v_device_name              TEXT;
    v_device_external_id       TEXT;
    v_device_model_vendor      TEXT;
    v_device_model             TEXT;

    -- device_type is retained temporarily for backward compatibility.
    v_device_type              TEXT;
    v_device_category_id       UUID;
    v_device_category_name     TEXT;
    v_existing_model_category_id UUID;

    v_device_firmware_version  TEXT;
    v_device_protocol          TEXT;
    v_profile_code             TEXT;

    v_identifier_type          TEXT;
    v_identifier_value         TEXT;

    v_asset_mode               TEXT;
    v_existing_asset_id        UUID;
    v_asset_name               TEXT;
    v_asset_type_id            UUID;
    v_relationship_type        TEXT;
    v_metering_requirement     TEXT;
    v_asset_metadata           JSONB;

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

    v_organization_name :=
        NULLIF(btrim(p_request #>> '{organization,name}'), '');

    v_organization_code :=
        upper(NULLIF(btrim(p_request #>> '{organization,code}'), ''));

    v_organization_description :=
        NULLIF(btrim(p_request #>> '{organization,description}'), '');

    IF v_organization_name IS NULL THEN
        RAISE EXCEPTION 'organization.name is required';
    END IF;

    IF v_organization_code IS NULL THEN
        RAISE EXCEPTION 'organization.code is required';
    END IF;

    IF v_organization_code !~ '^[A-Z0-9_]+$' THEN
        RAISE EXCEPTION
            'organization.code must contain only A-Z, 0-9, and underscore';
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize site fields.
    --------------------------------------------------------------------------

    v_site_name :=
        NULLIF(btrim(p_request #>> '{site,name}'), '');

    v_site_code :=
        upper(NULLIF(btrim(p_request #>> '{site,code}'), ''));

    v_site_timezone :=
        COALESCE
        (
            NULLIF(btrim(p_request #>> '{site,timezone}'), ''),
            'Asia/Kolkata'
        );

    v_site_address :=
        COALESCE(p_request #> '{site,address}', '{}'::JSONB);

    IF v_site_name IS NULL THEN
        RAISE EXCEPTION 'site.name is required';
    END IF;

    IF v_site_code IS NULL THEN
        RAISE EXCEPTION 'site.code is required';
    END IF;

    IF v_site_code !~ '^[A-Z0-9_]+$' THEN
        RAISE EXCEPTION
            'site.code must contain only A-Z, 0-9, and underscore';
    END IF;

    IF jsonb_typeof(v_site_address) <> 'object' THEN
        RAISE EXCEPTION 'site.address must be a JSON object';
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

    v_gateway_name :=
        NULLIF(btrim(p_request #>> '{gateway,name}'), '');

    v_gateway_external_id :=
        upper(NULLIF(btrim(p_request #>> '{gateway,external_id}'), ''));

    v_gateway_vendor :=
        NULLIF(btrim(p_request #>> '{gateway,vendor}'), '');

    v_gateway_model :=
        NULLIF(btrim(p_request #>> '{gateway,model}'), '');

    v_gateway_protocol :=
        upper(NULLIF(btrim(p_request #>> '{gateway,protocol}'), ''));

    IF v_gateway_name IS NULL THEN
        RAISE EXCEPTION 'gateway.name is required';
    END IF;

    IF v_gateway_external_id IS NULL THEN
        RAISE EXCEPTION 'gateway.external_id is required';
    END IF;

    IF v_gateway_vendor IS NULL THEN
        RAISE EXCEPTION 'gateway.vendor is required';
    END IF;

    IF v_gateway_model IS NULL THEN
        RAISE EXCEPTION 'gateway.model is required';
    END IF;

    IF v_gateway_protocol IS NULL THEN
        RAISE EXCEPTION 'gateway.protocol is required';
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize device fields.
    --------------------------------------------------------------------------

    v_device_name :=
        NULLIF(btrim(p_request #>> '{device,name}'), '');

    v_device_external_id :=
        upper(NULLIF(btrim(p_request #>> '{device,external_id}'), ''));

    v_device_model_vendor :=
        NULLIF(btrim(p_request #>> '{device,model_vendor}'), '');

    v_device_model :=
        NULLIF(btrim(p_request #>> '{device,model}'), '');

    v_device_type :=
        NULLIF(btrim(p_request #>> '{device,device_type}'), '');

    BEGIN
        v_device_category_id :=
            NULLIF(
                btrim(p_request #>> '{device,device_category_id}'),
                ''
            )::UUID;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION
                'device.device_category_id must be a valid UUID';
    END;

    v_device_firmware_version :=
        NULLIF(btrim(p_request #>> '{device,firmware_version}'), '');

    v_device_protocol :=
        upper(NULLIF(btrim(p_request #>> '{device,protocol}'), ''));

    v_profile_code :=
        upper(NULLIF(btrim(p_request #>> '{device,profile_code}'), ''));

    IF v_device_name IS NULL THEN
        RAISE EXCEPTION 'device.name is required';
    END IF;

    IF v_device_external_id IS NULL THEN
        RAISE EXCEPTION 'device.external_id is required';
    END IF;

    IF v_device_model_vendor IS NULL THEN
        RAISE EXCEPTION 'device.model_vendor is required';
    END IF;

    IF v_device_model IS NULL THEN
        RAISE EXCEPTION 'device.model is required';
    END IF;

    IF v_device_category_id IS NULL
       AND v_device_type IS NULL
    THEN
        RAISE EXCEPTION
            'device.device_category_id is required';
    END IF;

    IF v_device_protocol IS NULL THEN
        RAISE EXCEPTION 'device.protocol is required';
    END IF;

    IF v_profile_code IS NULL THEN
        RAISE EXCEPTION 'device.profile_code is required';
    END IF;


    --------------------------------------------------------------------------
    -- Extract and normalize external identifier fields.
    --------------------------------------------------------------------------

    v_identifier_type :=
        upper(NULLIF(btrim(p_request #>> '{identifier,type}'), ''));

    v_identifier_value :=
        NULLIF(btrim(p_request #>> '{identifier,value}'), '');

    IF v_identifier_type IS NULL THEN
        RAISE EXCEPTION 'identifier.type is required';
    END IF;

    IF v_identifier_value IS NULL THEN
        RAISE EXCEPTION 'identifier.value is required';
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

    v_metering_requirement :=
        upper
        (
            NULLIF
            (
                btrim
                (
                    p_request #>> '{asset,metering_requirement}'
                ),
                ''
            )
        );

    v_asset_metadata :=
        COALESCE(p_request #> '{asset,metadata}', '{}'::JSONB);

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
                'DIRECT_METER_REQUIRED, DESCENDANT_COVERAGE_ALLOWED, '
                'or NOT_REQUIRED';
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
    -- Serialize onboarding requests for the same tenant code.
    --------------------------------------------------------------------------

    PERFORM pg_advisory_xact_lock(hashtext(v_organization_code));


    --------------------------------------------------------------------------
    -- Organization.
    --------------------------------------------------------------------------

    INSERT INTO metadata.organizations
    (
        name,
        code,
        description,
        is_active
    )
    VALUES
    (
        v_organization_name,
        v_organization_code,
        v_organization_description,
        TRUE
    )
    ON CONFLICT (code)
    DO UPDATE SET
        name        = EXCLUDED.name,
        description = EXCLUDED.description,
        is_active   = TRUE,
        updated_at  = now()
    RETURNING id
    INTO v_organization_id;


    --------------------------------------------------------------------------
    -- Site.
    --------------------------------------------------------------------------

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
    ON CONFLICT (organization_id, code)
    DO UPDATE SET
        name       = EXCLUDED.name,
        timezone   = EXCLUDED.timezone,
        address    = EXCLUDED.address,
        is_active  = TRUE,
        updated_at = now()
    RETURNING id
    INTO v_site_id;


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
    -- Gateway model.
    --
    -- No natural-key constraint currently exists on this table, so the
    -- function performs a normalized lookup before inserting.
    --------------------------------------------------------------------------

    SELECT gm.id
    INTO v_gateway_model_id
    FROM metadata.gateway_models gm
    WHERE lower(COALESCE(gm.vendor, '')) = lower(v_gateway_vendor)
      AND lower(gm.model) = lower(v_gateway_model)
    ORDER BY gm.created_at, gm.id
    LIMIT 1;

    IF v_gateway_model_id IS NULL THEN
        INSERT INTO metadata.gateway_models
        (
            vendor,
            model,
            protocol
        )
        VALUES
        (
            v_gateway_vendor,
            v_gateway_model,
            v_gateway_protocol
        )
        RETURNING id
        INTO v_gateway_model_id;
    END IF;


    --------------------------------------------------------------------------
    -- Gateway.
    --------------------------------------------------------------------------

    SELECT g.id
    INTO v_gateway_id
    FROM metadata.gateways g
    WHERE g.organization_id = v_organization_id
      AND upper(COALESCE(g.external_id, '')) = v_gateway_external_id
    ORDER BY g.created_at, g.id
    LIMIT 1;

    IF v_gateway_id IS NULL THEN
        INSERT INTO metadata.gateways
        (
            organization_id,
            site_id,
            gateway_model_id,
            name,
            external_id,
            space_id
        )
        VALUES
        (
            v_organization_id,
            v_site_id,
            v_gateway_model_id,
            v_gateway_name,
            v_gateway_external_id,
            NULL
        )
        RETURNING id
        INTO v_gateway_id;
    ELSE
        UPDATE metadata.gateways
        SET
            site_id          = v_site_id,
            gateway_model_id = v_gateway_model_id,
            name             = v_gateway_name
        WHERE id = v_gateway_id;
    END IF;


    --------------------------------------------------------------------------
    -- Controlled device category.
    --------------------------------------------------------------------------

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


    --------------------------------------------------------------------------
    -- Controlled category-to-asset relationship compatibility.
    --
    -- This database-layer rule prevents direct SQL/API callers from bypassing
    -- the corresponding portal and application-service validation.
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
    -- Device model.
    --------------------------------------------------------------------------

    SELECT
        dm.id,
        dm.device_category_id
    INTO
        v_device_model_id,
        v_existing_model_category_id
    FROM metadata.device_models dm
    WHERE lower(COALESCE(dm.vendor, '')) =
          lower(v_device_model_vendor)
      AND lower(dm.model) = lower(v_device_model)
    ORDER BY dm.created_at, dm.id
    LIMIT 1;

    IF v_device_model_id IS NULL THEN
        INSERT INTO metadata.device_models
        (
            vendor,
            model,
            device_type,
            device_category_id
        )
        VALUES
        (
            v_device_model_vendor,
            v_device_model,
            v_device_type,
            v_device_category_id
        )
        RETURNING id
        INTO v_device_model_id;
    ELSE
        IF v_existing_model_category_id <> v_device_category_id THEN
            RAISE EXCEPTION
                'Device model % / % already belongs to a different category',
                v_device_model_vendor,
                v_device_model;
        END IF;

        UPDATE metadata.device_models
        SET device_type = v_device_category_name
        WHERE id = v_device_model_id
          AND device_type IS DISTINCT FROM v_device_category_name;
    END IF;


    --------------------------------------------------------------------------
    -- Active payload profile.
    --------------------------------------------------------------------------

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


    --------------------------------------------------------------------------
    -- Device.
    --------------------------------------------------------------------------

    SELECT d.id
    INTO v_device_id
    FROM metadata.devices d
    WHERE d.organization_id = v_organization_id
      AND upper(COALESCE(d.external_id, '')) = v_device_external_id
    ORDER BY d.created_at, d.id
    LIMIT 1;

    IF v_device_id IS NULL THEN
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
            profile_id
        )
        VALUES
        (
            v_organization_id,
            v_gateway_id,
            v_device_model_id,
            v_device_name,
            v_device_external_id,
            NULL,
            v_device_firmware_version,
            v_device_protocol,
            v_profile_id
        )
        RETURNING id
        INTO v_device_id;
    ELSE
        UPDATE metadata.devices
        SET
            gateway_id       = v_gateway_id,
            device_model_id  = v_device_model_id,
            name             = v_device_name,
            firmware_version = v_device_firmware_version,
            protocol         = v_device_protocol,
            profile_id       = v_profile_id,
            updated_at       = now()
        WHERE id = v_device_id;
    END IF;


    --------------------------------------------------------------------------
    -- External device identifier.
    --
    -- Never silently transfer an identifier that belongs to another device.
    --------------------------------------------------------------------------

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

    IF v_existing_identifier_device_id IS NOT NULL
       AND v_existing_identifier_device_id <> v_device_id
    THEN
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
    )
    ON CONFLICT (identifier_type, identifier_value)
    DO UPDATE SET
        device_id = EXCLUDED.device_id;


    --------------------------------------------------------------------------
    -- Asset selection or creation.
    --------------------------------------------------------------------------

    IF v_asset_mode = 'USE_EXISTING' THEN
        SELECT
            a.id,
            a.name,
            a.asset_type_id,
            a.metering_requirement
        INTO
            v_asset_id,
            v_asset_name,
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
        SELECT a.id
        INTO v_asset_id
        FROM metadata.assets a
        WHERE a.organization_id = v_organization_id
          AND a.site_id = v_site_id
          AND a.parent_asset_id IS NULL
          AND a.name = v_asset_name
          AND a.space_id IS NOT DISTINCT FROM v_space_id
        ORDER BY a.created_at, a.id
        LIMIT 1;

        IF v_asset_id IS NULL THEN
            INSERT INTO metadata.assets
            (
                organization_id,
                site_id,
                asset_type_id,
                parent_asset_id,
                name,
                manufacturer,
                model,
                serial_number,
                status,
                metering_requirement,
                metadata,
                space_id
            )
            VALUES
            (
                v_organization_id,
                v_site_id,
                v_asset_type_id,
                NULL,
                v_asset_name,
                NULL,
                NULL,
                NULL,
                'active',
                v_metering_requirement,
                v_asset_metadata,
                v_space_id
            )
            RETURNING id
            INTO v_asset_id;
        ELSE
            UPDATE metadata.assets
            SET
                asset_type_id        = v_asset_type_id,
                status               = 'active',
                metering_requirement = v_metering_requirement,
                metadata             = v_asset_metadata,
                space_id      = v_space_id,
                updated_at    = now()
            WHERE id = v_asset_id;
        END IF;
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
$$;


COMMENT ON FUNCTION admin.onboard_energy_asset(JSONB, TEXT) IS
'Atomically creates or reconciles one EMS organization, site, gateway, device, identifier, root asset, asset-device relationship, and optional Grafana organization mapping.';


-- ----------------------------------------------------------------------------
-- 4. Ownership and least-privilege grants.
-- ----------------------------------------------------------------------------

ALTER TABLE admin.onboarding_audit
    OWNER TO ems_admin;

ALTER VIEW admin.v_active_device_profiles
    OWNER TO ems_admin;

ALTER VIEW admin.v_asset_types
    OWNER TO ems_admin;

ALTER VIEW admin.v_buildings
    OWNER TO ems_admin;

ALTER VIEW admin.v_floors
    OWNER TO ems_admin;

ALTER VIEW admin.v_spaces
    OWNER TO ems_admin;

ALTER VIEW admin.v_assets
    OWNER TO ems_admin;

ALTER VIEW admin.v_gateway_models
    OWNER TO ems_admin;

ALTER VIEW admin.v_device_categories
    OWNER TO ems_admin;

ALTER VIEW admin.v_device_models
    OWNER TO ems_admin;

ALTER FUNCTION admin.onboard_energy_asset(JSONB, TEXT)
    OWNER TO ems_admin;


REVOKE ALL
    ON TABLE admin.onboarding_audit
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_active_device_profiles
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_asset_types
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_buildings
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_floors
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_spaces
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_assets
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_gateway_models
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_device_categories
    FROM PUBLIC;

REVOKE ALL
    ON TABLE admin.v_device_models
    FROM PUBLIC;

REVOKE ALL
    ON FUNCTION admin.onboard_energy_asset(JSONB, TEXT)
    FROM PUBLIC;


GRANT USAGE
    ON SCHEMA admin
    TO ems_app;

GRANT SELECT
    ON
        admin.v_active_device_profiles,
        admin.v_asset_types,
        admin.v_buildings,
        admin.v_floors,
        admin.v_spaces,
        admin.v_assets,
        admin.v_gateway_models,
        admin.v_device_categories,
        admin.v_device_models
    TO ems_app;

GRANT EXECUTE
    ON FUNCTION admin.onboard_energy_asset(JSONB, TEXT)
    TO ems_app;
