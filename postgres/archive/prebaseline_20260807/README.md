# Pre-baseline migration archive

These files are the immutable migration history used before the 2026-08-07
pre-production baseline reset. They are retained for audit, recovery and
traceability, but are not selected by the active migration manifest.

Do not edit archived files. The active migration stream starts at
`postgres/migrations/001_ems_platform_baseline_20260807.sql`.

## Ledger reconciliation note

The production ledger contained 115 applied migrations. The archive contains
116 SQL files. `157_relationship_type_config_schema_permission.sql` was present
in the repository but absent from the production ledger; it is retained only as
historical repository material and is not incorporated into baseline 001.
