# EMS pre-production migration baseline patch

This patch archives the pre-baseline migration history and introduces baseline
`001_ems_platform_baseline_20260807.sql`. Do not reset the production migration
ledger until a clean disposable database has passed the complete integration
workflow.

Installation sequence:

1. Extract into `/opt/ems-platform`.
2. Run `scripts/baseline/install_baseline_repository_layout.sh`.
3. Run repository contract tests.
4. Reset and rebuild `ems_test` from canonical deployment plus baseline 001.
5. Run the complete integration workflow.
6. Back up production.
7. Reset the existing production migration ledger using the guarded cutover
   script. Do not execute baseline SQL on the already-upgraded production DB.
