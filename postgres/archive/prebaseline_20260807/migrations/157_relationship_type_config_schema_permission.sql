-- Allow the application role to read the controlled relationship-type catalogue.
-- Table SELECT had already been granted by migration 119, but PostgreSQL also
-- requires USAGE on the containing schema.

GRANT USAGE ON SCHEMA config TO ems_app;
GRANT SELECT ON TABLE config.asset_device_relationship_types TO ems_app;
