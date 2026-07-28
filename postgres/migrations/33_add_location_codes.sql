BEGIN;

-- Stable business identifier for each building.
-- Building codes are unique only within their parent site.
ALTER TABLE metadata.buildings
    ADD COLUMN code TEXT NOT NULL,
    ADD CONSTRAINT buildings_code_format_chk
        CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    ADD CONSTRAINT buildings_site_code_uq
        UNIQUE (site_id, code);

-- Stable business identifier for each floor.
-- Floor codes are unique only within their parent building.
ALTER TABLE metadata.floors
    ADD COLUMN code TEXT NOT NULL,
    ADD CONSTRAINT floors_code_format_chk
        CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    ADD CONSTRAINT floors_building_code_uq
        UNIQUE (building_id, code);

-- Stable business identifier for each space.
-- Space codes are unique only within their parent floor.
ALTER TABLE metadata.spaces
    ADD COLUMN code TEXT NOT NULL,
    ADD CONSTRAINT spaces_code_format_chk
        CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    ADD CONSTRAINT spaces_floor_code_uq
        UNIQUE (floor_id, code);

COMMIT;
