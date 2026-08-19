/*
===============================================================================
28_profile_field_mapping.sql

Purpose
-------
Maps raw telemetry fields from a Device Profile to EMS Logical Points.

This allows every physical device sharing the same profile to reuse one
mapping definition.

Example

ENERGY_METER_ENISCOPE_V1

P   -> Active Power
P1  -> Phase 1 Active Power
V1  -> Voltage L1
I1  -> Current L1

===============================================================================
*/

CREATE TABLE IF NOT EXISTS config.profile_field_mapping (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    profile_id UUID NOT NULL
        REFERENCES config.device_profiles(id)
        ON DELETE CASCADE,

    raw_field_name TEXT NOT NULL,

    logical_point_id UUID NOT NULL
        REFERENCES metadata.logical_points(id),

    json_path TEXT,

    transform_expression TEXT,

    source_unit_symbol TEXT,

    scale_to_canonical_unit NUMERIC(20,9) NOT NULL DEFAULT 1,

    offset_to_canonical_unit NUMERIC(20,9) NOT NULL DEFAULT 0,

    is_required BOOLEAN NOT NULL DEFAULT TRUE,

    display_order INTEGER NOT NULL DEFAULT 0,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_profile_field
        UNIQUE (
            profile_id,
            raw_field_name
        )

);

COMMENT ON TABLE config.profile_field_mapping IS
'Maps raw telemetry fields from a Device Profile to EMS Logical Points.';

COMMENT ON COLUMN config.profile_field_mapping.json_path IS
'Optional JSON path for nested payload structures.';

COMMENT ON COLUMN config.profile_field_mapping.transform_expression IS
'Optional SQL expression used to transform incoming values.';

COMMENT ON COLUMN config.profile_field_mapping.source_unit_symbol IS
'Source engineering unit emitted by the mapped field. NULL means unspecified.';

COMMENT ON COLUMN config.profile_field_mapping.scale_to_canonical_unit IS
'Multiplier used by the live path to convert numeric source values to the logical-point engineering unit.';

COMMENT ON COLUMN config.profile_field_mapping.offset_to_canonical_unit IS
'Offset added after live-path scaling to the logical-point engineering unit.';

CREATE INDEX IF NOT EXISTS idx_profile_field_mapping_profile
ON config.profile_field_mapping(profile_id);

CREATE INDEX IF NOT EXISTS idx_profile_field_mapping_point
ON config.profile_field_mapping(logical_point_id);
