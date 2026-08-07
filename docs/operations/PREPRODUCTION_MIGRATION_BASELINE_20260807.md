# EMS platform pre-production migration baseline — 2026-08-07

## Decision

Before the first real client deployment, the active forward-migration history
was reset to a clean baseline.

- Canonical DDL, reference seeds and jobs remain the clean-install foundation.
- Former forward migrations are preserved unchanged under
  `postgres/archive/prebaseline_20260807/migrations/`.
- Their final post-canonical effect is consolidated into
  `postgres/migrations/001_ems_platform_baseline_20260807.sql`.
- Future migrations begin at `002`.

## Rules from this point

1. Baseline 001 is immutable after cutover.
2. Every later database change receives the next migration number.
3. Corrections never edit 001; they use a new migration.
4. Clean test installation must run canonical deployment, baseline 001 and the
   full integration assertions.
5. Existing databases may reset only their migration ledger after proving they
   already contain pre-baseline migration 179.
6. Historical migration files remain archived in Git for audit and recovery.

## Clean installation

```bash
scripts/test/test_database.sh reset
scripts/test/deploy_test_database.sh
scripts/test/apply_test_migrations.sh
```

The complete integration workflow remains:

```bash
scripts/test/run_integration_environment.sh
```

## Existing database cutover

The schema is not replayed on an existing database that already reached
migration 179. After a full backup and verification:

```bash
scripts/baseline/reset_existing_migration_ledger.sh --execute
```

The script exports the previous ledger before replacing it with one baseline
entry. It refuses to run unless migration 179 is the latest recorded migration.
