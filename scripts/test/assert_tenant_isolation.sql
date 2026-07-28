\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS two-tenant isolation contract
--
-- This test creates two temporary EMS organizations and maps them to separate
-- Grafana organization IDs:
--
--   Grafana org 91001 -> Tenant Alpha
--   Grafana org 91002 -> Tenant Beta
--
-- All changes are rolled back after the assertions.
--
-- Important architectural boundary:
--   The analytics views expose grafana_org_id. Grafana dashboard SQL must still
--   filter with:
--
--       WHERE grafana_org_id = ${__org.id}
--
-- This test proves that the mapping and filtered view results are correct.
-- =============================================================================

BEGIN;

-- Use fixed UUIDs and unusually high Grafana organization IDs so test records
-- cannot collide with normal development/demo data.
INSERT INTO metadata.organizations (
    id,
    name,
    code,
    description,
    is_active
)
VALUES
    (
        '91000000-0000-0000-0000-000000000001',
        'Tenant Isolation Alpha',
        'TEST_TENANT_ALPHA',
        'Disposable tenant-isolation test organization',
        TRUE
    ),
    (
        '91000000-0000-0000-0000-000000000002',
        'Tenant Isolation Beta',
        'TEST_TENANT_BETA',
        'Disposable tenant-isolation test organization',
        TRUE
    );

INSERT INTO metadata.sites (
    id,
    organization_id,
    name,
    code,
    timezone,
    address,
    is_active
)
VALUES
    (
        '92000000-0000-0000-0000-000000000001',
        '91000000-0000-0000-0000-000000000001',
        'Alpha Site',
        'ALPHA_SITE',
        'Asia/Kolkata',
        '{"city": "Hyderabad"}'::jsonb,
        TRUE
    ),
    (
        '92000000-0000-0000-0000-000000000002',
        '91000000-0000-0000-0000-000000000002',
        'Beta Site',
        'BETA_SITE',
        'Asia/Kolkata',
        '{"city": "Bengaluru"}'::jsonb,
        TRUE
    );

INSERT INTO metadata.grafana_organization_map (
    grafana_org_id,
    organization_id,
    is_active
)
VALUES
    (
        91001,
        '91000000-0000-0000-0000-000000000001',
        TRUE
    ),
    (
        91002,
        '91000000-0000-0000-0000-000000000002',
        TRUE
    );

-- ---------------------------------------------------------------------------
-- Mapping integrity
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    alpha_org uuid;
    beta_org uuid;
BEGIN
    SELECT organization_id
    INTO alpha_org
    FROM metadata.grafana_organization_map
    WHERE grafana_org_id = 91001;

    SELECT organization_id
    INTO beta_org
    FROM metadata.grafana_organization_map
    WHERE grafana_org_id = 91002;

    IF alpha_org <> '91000000-0000-0000-0000-000000000001'::uuid THEN
        RAISE EXCEPTION
            'Grafana organization 91001 mapped to unexpected tenant: %',
            alpha_org;
    END IF;

    IF beta_org <> '91000000-0000-0000-0000-000000000002'::uuid THEN
        RAISE EXCEPTION
            'Grafana organization 91002 mapped to unexpected tenant: %',
            beta_org;
    END IF;

    IF alpha_org = beta_org THEN
        RAISE EXCEPTION
            'Both Grafana organizations resolve to the same EMS tenant';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- analytics.v_organizations isolation
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    alpha_count bigint;
    beta_count bigint;
    cross_tenant_count bigint;
BEGIN
    SELECT count(*)
    INTO alpha_count
    FROM analytics.v_organizations
    WHERE grafana_org_id = 91001
      AND organization_code = 'TEST_TENANT_ALPHA';

    IF alpha_count <> 1 THEN
        RAISE EXCEPTION
            'Grafana org 91001 did not resolve exactly one Alpha organization row';
    END IF;

    SELECT count(*)
    INTO beta_count
    FROM analytics.v_organizations
    WHERE grafana_org_id = 91002
      AND organization_code = 'TEST_TENANT_BETA';

    IF beta_count <> 1 THEN
        RAISE EXCEPTION
            'Grafana org 91002 did not resolve exactly one Beta organization row';
    END IF;

    SELECT count(*)
    INTO cross_tenant_count
    FROM analytics.v_organizations
    WHERE (
        grafana_org_id = 91001
        AND organization_code = 'TEST_TENANT_BETA'
    )
       OR (
        grafana_org_id = 91002
        AND organization_code = 'TEST_TENANT_ALPHA'
    );

    IF cross_tenant_count <> 0 THEN
        RAISE EXCEPTION
            'Cross-tenant organization rows were exposed: %',
            cross_tenant_count;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- analytics.v_sites isolation
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    alpha_count bigint;
    beta_count bigint;
    cross_tenant_count bigint;
BEGIN
    SELECT count(*)
    INTO alpha_count
    FROM analytics.v_sites
    WHERE grafana_org_id = 91001
      AND site_code = 'ALPHA_SITE'
      AND organization_code = 'TEST_TENANT_ALPHA';

    IF alpha_count <> 1 THEN
        RAISE EXCEPTION
            'Grafana org 91001 did not resolve exactly one Alpha site';
    END IF;

    SELECT count(*)
    INTO beta_count
    FROM analytics.v_sites
    WHERE grafana_org_id = 91002
      AND site_code = 'BETA_SITE'
      AND organization_code = 'TEST_TENANT_BETA';

    IF beta_count <> 1 THEN
        RAISE EXCEPTION
            'Grafana org 91002 did not resolve exactly one Beta site';
    END IF;

    SELECT count(*)
    INTO cross_tenant_count
    FROM analytics.v_sites
    WHERE (
        grafana_org_id = 91001
        AND site_code = 'BETA_SITE'
    )
       OR (
        grafana_org_id = 91002
        AND site_code = 'ALPHA_SITE'
    );

    IF cross_tenant_count <> 0 THEN
        RAISE EXCEPTION
            'Cross-tenant site rows were exposed: %',
            cross_tenant_count;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Inactive mapping behavior
-- ---------------------------------------------------------------------------

UPDATE metadata.grafana_organization_map
SET is_active = FALSE
WHERE grafana_org_id = 91002;

DO $$
DECLARE
    visible_beta_rows bigint;
BEGIN
    SELECT count(*)
    INTO visible_beta_rows
    FROM analytics.v_organizations
    WHERE grafana_org_id = 91002;

    IF visible_beta_rows <> 0 THEN
        RAISE EXCEPTION
            'Inactive Grafana mapping still exposes organization rows';
    END IF;

    SELECT count(*)
    INTO visible_beta_rows
    FROM analytics.v_sites
    WHERE grafana_org_id = 91002;

    IF visible_beta_rows <> 0 THEN
        RAISE EXCEPTION
            'Inactive Grafana mapping still exposes site rows';
    END IF;
END
$$;

-- Restore the mapping so subsequent assertions use the original state.
UPDATE metadata.grafana_organization_map
SET is_active = TRUE
WHERE grafana_org_id = 91002;

-- ---------------------------------------------------------------------------
-- Inactive organization behavior
-- ---------------------------------------------------------------------------

UPDATE metadata.organizations
SET is_active = FALSE
WHERE id = '91000000-0000-0000-0000-000000000002';

DO $$
DECLARE
    organization_rows bigint;
BEGIN
    SELECT count(*)
    INTO organization_rows
    FROM analytics.v_organizations
    WHERE grafana_org_id = 91002;

    IF organization_rows <> 0 THEN
        RAISE EXCEPTION
            'Inactive EMS organization remains visible in v_organizations';
    END IF;
END
$$;

SELECT
    grafana_org_id,
    organization_code,
    organization_name
FROM analytics.v_organizations
WHERE grafana_org_id = 91001;

SELECT
    grafana_org_id,
    organization_code,
    site_code,
    site_name
FROM analytics.v_sites
WHERE grafana_org_id = 91001;

ROLLBACK;

SELECT 'Core tenant-isolation assertions passed.' AS result;
