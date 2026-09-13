# Environment Matrix — Staging vs. Production

Status: CURRENT
Last verified: 2026-08-24
Verification basis: Staging (read-write via `ems_admin`, read-only via `ems_readonly`), Production read-only (`ems_readonly`)

## Principle: business keys vs. environment-specific UUIDs

**Every primary-key UUID in this system (organization, site, gateway,
device, asset, profile, category IDs) is environment-specific and must
never be copied between environments.** Resolution between staging and
production must always go through **business keys**: organization `code`,
site `code`, building/floor/space `code`, gateway `external_id`, device
`external_id`, asset `external_id`, `profile_code`, and category/type
`name`. This was the explicit, enforced rule for this session's Meenaxy
Pharma staging migration and should be treated as a platform-wide
invariant, not a one-off convention.

One exception, confirmed empirically this session: the Meenaxy Pharma
**organization UUID happened to be identical** between staging and
production (`c4bde6d1-6688-46f0-95df-cdc1a943d17b`) — this is coincidental
(likely from an early environment clone), not architectural guarantee.
Every other entity's UUIDs differed between the two environments as
expected. Never rely on UUID coincidence; always resolve by business key.

**Physical facts that must be reused verbatim, unlike UUIDs**: a device's
`MQTT_UID` (e.g. `80:34:28:16:22:fe:00:01`) identifies real physical
hardware — this value is copied as-is between environments (it is not
regenerated per environment), unlike every surrogate UUID.

## What is identical (business-key level)

- Organization/site codes, when the same tenant is provisioned in both environments.
- Location hierarchy codes (building/floor/space), when correctly provisioned — see drift note below.
- Device profile codes and their semantics (`config.device_profiles`, `config.profile_field_mapping`).
- Device category names (`config.device_categories`).
- `compose.yaml` itself (shared unchanged between environments — see [17-cicd-and-deployment.md](../17-cicd-and-deployment.md)).

## What is intentionally environment-specific

- All surrogate UUIDs (see above).
- `TIMESCALEDB_DATA_PATH` — staging: `./postgres/data/pgdata`; production:
  `./postgres/data` (production's TimescaleDB predates the current
  deployment pipeline and already had live data at that path).
- Host bind addresses (`GRAFANA_BIND_HOST`, `ADMIN_PORTAL_BIND_HOST`) —
  both default to `127.0.0.1` for safety; staging may override to `0.0.0.0`
  for direct host access, production should not without a deliberate
  exposure architecture (reverse proxy, TLS, auth).
- Gateway/device lifecycle state — see next section.

## Known differences at the time of this verification (2026-08-24)

| Aspect | Production | Staging |
|---|---|---|
| Meenaxy Pharma gateway `lifecycle_status` | `ACTIVE` (all 3) | `REGISTERED` (all 3) — deliberately left unchanged during the metadata migration |
| Meenaxy Pharma device `lifecycle_status` | `ACTIVE` (all 22) | `ACTIVE` (all 22) — reached via a separate, manual, controlled commissioning action, not the migration itself |
| Telemetry history depth | long-running | began only at commissioning time this session — no historical backfill |
| `ems_readonly` role's schema-object visibility | (not separately tested this session) | Confirmed **not equivalent** to `ems_admin`'s: `information_schema.triggers` returned 0 rows for `metadata` schema under `ems_readonly`, but 12 real triggers under `ems_admin` — a role-privilege effect, not evidence those triggers don't exist |

## Drift found and resolved during this session (staging-only, now corrected)

Staging's location hierarchy had a **duplicate `DISTRIBUTIONPANEL` space**
under both the `GROUND` and `MEZZANINE` floors, for the same organization.
Production has this space only under `MEZZANINE`. This caused a real query
ambiguity during the Meenaxy Pharma migration (a business-key `(org,
space_code)` lookup matched two rows instead of one). Per explicit
instruction, staging's location data was **not modified** to fix this —
the migration query was corrected instead (qualified by floor). The user's
subsequent context indicated this staging-only duplicate was later removed
as a separate, explicit action; this manual has not independently
re-verified that removal in this document's own verification pass — treat
as reported, not independently re-confirmed here.

## How to safely compare environments

1. Never compare or copy by UUID. Resolve every entity by its business key
   on each side independently, then compare the resolved records.
2. Use the existing read-only roles (`ems_readonly` for production,
   `ems_admin` or `ems_readonly` for staging depending on what's granted)
   — never write to production under any circumstance.
3. When a discrepancy is found, determine whether it's a legitimate
   environment-specific difference (see table above) or genuine drift
   before treating it as a bug — see
   [23-known-issues-and-drift.md](../23-known-issues-and-drift.md) for the
   classification this manual uses.
