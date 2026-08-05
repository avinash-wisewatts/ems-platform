\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE cleanup_context AS
SELECT
    target.id AS target_organization_id,
    protected.id AS protected_organization_id
FROM metadata.organizations target
CROSS JOIN metadata.organizations protected
WHERE target.code = 'AVINASH_HOME_INC'
  AND protected.code = 'MEENAXY_PHARMA';

DO $$
DECLARE
    context_rows INTEGER;
    target_org UUID;
    protected_org UUID;
BEGIN
    SELECT count(*)
    INTO context_rows
    FROM cleanup_context;

    IF context_rows <> 1 THEN
        RAISE EXCEPTION
            'Safety check failed: expected exactly one target/protected organization pair, found %',
            context_rows;
    END IF;

    SELECT
        target_organization_id,
        protected_organization_id
    INTO
        target_org,
        protected_org
    FROM cleanup_context;

    IF target_org = protected_org THEN
        RAISE EXCEPTION
            'Safety check failed: target and protected organizations are identical';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.grafana_organization_map
        WHERE organization_id = target_org
          AND grafana_org_id = 5
          AND is_active
    ) THEN
        RAISE EXCEPTION
            'Safety check failed: active Avinash Home to Grafana org 5 mapping is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.grafana_organization_map
        WHERE organization_id = protected_org
          AND grafana_org_id = 6
          AND is_active
    ) THEN
        RAISE EXCEPTION
            'Safety check failed: active Meenaxy Pharma to Grafana org 6 mapping is missing';
    END IF;
END
$$;

CREATE TEMP TABLE cleanup_target_devices (
    device_id UUID PRIMARY KEY
);

INSERT INTO cleanup_target_devices (device_id)
SELECT d.id
FROM metadata.devices d
JOIN cleanup_context c
  ON c.target_organization_id = d.organization_id;

CREATE TEMP TABLE cleanup_results (
    object_name TEXT PRIMARY KEY,
    deleted_rows BIGINT NOT NULL
);

WITH deleted AS (
    DELETE FROM telemetry.energy_measurements em
    USING cleanup_context c
    WHERE em.organization_id = c.target_organization_id
    RETURNING 1
)
INSERT INTO cleanup_results
VALUES ('telemetry.energy_measurements', (SELECT count(*) FROM deleted));

WITH deleted AS (
    DELETE FROM telemetry.environment_measurements env
    USING cleanup_context c
    WHERE env.organization_id = c.target_organization_id
    RETURNING 1
)
INSERT INTO cleanup_results
VALUES ('telemetry.environment_measurements', (SELECT count(*) FROM deleted));

WITH deleted AS (
    DELETE FROM telemetry.normalized_points np
    USING cleanup_context c
    WHERE np.organization_id = c.target_organization_id
       OR np.device_id IN (
            SELECT device_id
            FROM cleanup_target_devices
       )
    RETURNING 1
)
INSERT INTO cleanup_results
VALUES ('telemetry.normalized_points', (SELECT count(*) FROM deleted));

WITH deleted AS (
    DELETE FROM telemetry.raw_messages
    WHERE source_topic ILIKE
          'wwems/v1/AVINASH_HOME_INC/%'
    RETURNING 1
)
INSERT INTO cleanup_results
VALUES ('telemetry.raw_messages — Avinash', (SELECT count(*) FROM deleted));

WITH deleted AS (
    DELETE FROM telemetry.raw_messages
    WHERE source_topic ILIKE
          'testeniscope/%'
    RETURNING 1
)
INSERT INTO cleanup_results
VALUES ('telemetry.raw_messages — testeniscope', (SELECT count(*) FROM deleted));

\echo
\echo '=== DELETION RESULTS ==='

TABLE cleanup_results;

DO $$
DECLARE
    target_org UUID;
    protected_org UUID;
BEGIN
    SELECT
        target_organization_id,
        protected_organization_id
    INTO
        target_org,
        protected_org
    FROM cleanup_context;

    IF EXISTS (
        SELECT 1
        FROM telemetry.energy_measurements
        WHERE organization_id = target_org
    ) THEN
        RAISE EXCEPTION
            'Post-check failed: Avinash energy measurements remain';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM telemetry.environment_measurements
        WHERE organization_id = target_org
    ) THEN
        RAISE EXCEPTION
            'Post-check failed: Avinash environment measurements remain';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM telemetry.normalized_points np
        WHERE np.organization_id = target_org
           OR np.device_id IN (
                SELECT device_id
                FROM cleanup_target_devices
           )
    ) THEN
        RAISE EXCEPTION
            'Post-check failed: Avinash normalized points remain';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM telemetry.raw_messages
        WHERE source_topic ILIKE 'wwems/v1/AVINASH_HOME_INC/%'
           OR source_topic ILIKE 'testeniscope/%'
    ) THEN
        RAISE EXCEPTION
            'Post-check failed: junk raw messages remain';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.organizations
        WHERE id = target_org
          AND code = 'AVINASH_HOME_INC'
    ) THEN
        RAISE EXCEPTION
            'Post-check failed: Avinash Home metadata was removed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.grafana_organization_map
        WHERE organization_id = target_org
          AND grafana_org_id = 5
          AND is_active
    ) THEN
        RAISE EXCEPTION
            'Post-check failed: Grafana org 5 mapping was removed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.organizations
        WHERE id = protected_org
          AND code = 'MEENAXY_PHARMA'
    ) THEN
        RAISE EXCEPTION
            'Post-check failed: protected Meenaxy Pharma organization is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.grafana_organization_map
        WHERE organization_id = protected_org
          AND grafana_org_id = 6
          AND is_active
    ) THEN
        RAISE EXCEPTION
            'Post-check failed: protected Grafana org 6 mapping is missing';
    END IF;
END
$$;

COMMIT;
