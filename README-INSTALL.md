# Device lifecycle cleanup

This patch reduces device lifecycle values to:

- `REGISTERED`
- `ACTIVE`
- `INACTIVE`
- `DECOMMISSIONED`

Existing `DISCOVERED`, `UNASSIGNED`, and `COMMISSIONING` device rows are migrated to `REGISTERED`. Commissioning readiness/status and asset assignment remain separate derived concepts. `ACTIVE` remains available only through the controlled commissioning action.

Apply migration 179 to `ems_test` first, run the focused tests, then back up and apply to production.
