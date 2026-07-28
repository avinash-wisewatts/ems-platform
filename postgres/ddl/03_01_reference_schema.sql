-- ============================================================================
-- File: 03_01_reference_schema.sql
-- Purpose: Canonical configuration and controlled-vocabulary table definitions.
--
-- Deployment requirements:
--   - Must run after 01_schemas.sql.
--   - Must run before 04_metadata.sql because metadata.logical_points
--     references config.engineering_units.
--
-- Architectural rule:
--   - This file contains schema definitions only.
--   - Reference data belongs under postgres/seeds/reference/.
-- ============================================================================


-- ============================================================================
-- ENGINEERING UNITS
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.engineering_units
(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    symbol TEXT UNIQUE NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ============================================================================
-- DEVICE CATEGORIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.device_categories
(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT UNIQUE NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ============================================================================
-- COMMUNICATION PROTOCOLS
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.protocols
(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT UNIQUE NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ============================================================================
-- LOGICAL POINT CATEGORIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.point_categories
(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT UNIQUE NOT NULL,

    description TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ============================================================================
-- ADMINISTRATION STATUS DEFINITIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.status_definitions
(
    status_domain TEXT NOT NULL,
    code TEXT NOT NULL,
    label TEXT NOT NULL,
    description TEXT NOT NULL,
    sort_order SMALLINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT status_definitions_pk
        PRIMARY KEY (status_domain, code),

    CONSTRAINT status_definitions_domain_format_chk
        CHECK (status_domain ~ '^[A-Z][A-Z0-9_]*$'),

    CONSTRAINT status_definitions_code_format_chk
        CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),

    CONSTRAINT status_definitions_sort_order_chk
        CHECK (sort_order > 0),

    CONSTRAINT status_definitions_domain_sort_uq
        UNIQUE (status_domain, sort_order)
);

COMMENT ON TABLE config.status_definitions IS
'Canonical labels and descriptions for closed administration status domains. Entity columns remain protected by CHECK constraints so invalid values are rejected even when reference rows are unavailable.';
