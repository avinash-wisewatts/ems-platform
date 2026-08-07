# EMS pre-production baseline correction

This correction replaces the failed historical-replay baseline.

It makes two changes:

1. Promotes all authoritative `canonical_mirror`/`ddl` manifest entries to
   `canonical`, so clean deployment installs current DDL through file 121.
2. Replaces baseline 001 with an additive baseline containing only migrations
   162, 169, and 171-179, which have no canonical DDL mirror.

The correction also updates historical SQL contract tests to read immutable
files from `postgres/archive/prebaseline_20260807/migrations/`.

Production must not execute baseline 001. Existing production receives only a
migration-ledger reset after the corrected clean-install and full integration
suite pass.
