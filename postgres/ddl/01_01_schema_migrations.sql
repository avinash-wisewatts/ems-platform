-- =============================================================================
-- File: 01_01_schema_migrations.sql
-- Purpose:
--   Record every forward database migration applied to an EMS database.
--
-- Design:
--   * migration_id is a stable identifier derived from the migration filename.
--   * file_path records the repository-relative migration path.
--   * checksum_sha256 detects changes to an already-applied migration.
--   * applied_at and applied_by provide deployment auditability.
--   * execution_ms supports operational troubleshooting.
--
-- Governance:
--   Once a migration has been applied, its file must never be edited.
--   Corrections must be delivered through a new forward migration.
-- =============================================================================

CREATE TABLE IF NOT EXISTS admin.schema_migrations (
    migration_id text PRIMARY KEY,

    file_path text NOT NULL UNIQUE,

    checksum_sha256 text NOT NULL,

    applied_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    applied_by text NOT NULL DEFAULT session_user,

    execution_ms bigint NOT NULL,

    application_mode text NOT NULL,

    CONSTRAINT schema_migrations_id_not_blank
        CHECK (btrim(migration_id) <> ''),

    CONSTRAINT schema_migrations_file_path_not_blank
        CHECK (btrim(file_path) <> ''),

    CONSTRAINT schema_migrations_checksum_format
        CHECK (checksum_sha256 ~ '^[0-9a-f]{64}$'),

    CONSTRAINT schema_migrations_execution_ms_nonnegative
        CHECK (execution_ms >= 0),

    CONSTRAINT schema_migrations_application_mode_valid
        CHECK (application_mode IN ('applied', 'baseline'))
);

COMMENT ON TABLE admin.schema_migrations IS
'Immutable audit ledger of forward database migrations applied to this EMS database.';

COMMENT ON COLUMN admin.schema_migrations.migration_id IS
'Stable migration identifier, normally the migration filename without its .sql suffix.';

COMMENT ON COLUMN admin.schema_migrations.file_path IS
'Repository-relative path of the migration file that was applied.';

COMMENT ON COLUMN admin.schema_migrations.checksum_sha256 IS
'SHA-256 checksum of the exact migration file contents at application time.';

COMMENT ON COLUMN admin.schema_migrations.applied_at IS
'Database timestamp at which the migration was successfully recorded.';

COMMENT ON COLUMN admin.schema_migrations.applied_by IS
'Database session user that applied the migration.';

COMMENT ON COLUMN admin.schema_migrations.execution_ms IS
'Elapsed migration execution time in milliseconds.';

COMMENT ON COLUMN admin.schema_migrations.application_mode IS
'How the migration was recorded: applied by execution or baseline only.';

-- Migration history is administrative metadata. Application and telemetry roles
-- must not be able to modify it directly.
REVOKE ALL ON TABLE admin.schema_migrations FROM PUBLIC;
REVOKE ALL ON TABLE admin.schema_migrations FROM ems_app;
REVOKE ALL ON TABLE admin.schema_migrations FROM telegraf_writer;
REVOKE ALL ON TABLE admin.schema_migrations FROM grafana_reader;
REVOKE ALL ON TABLE admin.schema_migrations FROM ems_readonly;
