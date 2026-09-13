# Troubleshooting

Status: CURRENT · Last reviewed: 2026-08-24
Verification basis: Staging (real incidents), Repository

Format: **Symptom → Likely cause → Diagnostic steps → What NOT to do.**
Every entry below is built from a real incident, not a hypothetical.

## `ems_readonly` cannot see triggers that `ems_admin` can

**Symptom**: `information_schema.triggers` returns 0 rows for a schema you
know has triggers (confirmed 12 active on `metadata`).

**Likely cause**: `ems_readonly`'s catalog visibility for
`information_schema.triggers` is genuinely, unexplainedly narrower than
`ems_admin`'s — not a privilege difference on the underlying tables (both
have full `SELECT`).

**Diagnostic steps**: query `pg_trigger`/`pg_proc` directly, or use
`ems_admin`, for any investigation that needs to enumerate triggers.

**What NOT to do**: do not conclude "no triggers exist" from an empty
`information_schema.triggers` result under a read-only role. See
[../04-architecture/security-and-tenancy.md](../04-architecture/security-and-tenancy.md).

## Staging DB connection fails: `Connection refused` vs. `server closed the connection unexpectedly`

**Likely cause / how to tell them apart**: `Connection refused` — the
tunnel itself is down. `server closed the connection unexpectedly` — the
tunnel was up but dropped mid-connection.

**Diagnostic steps**: retry once immediately. If it fails a second time,
stop retrying in a loop — report the exact error text and that the tunnel
needs reopening.

**What NOT to do**: do not loop retrying indefinitely, and do not assume
one successful reconnect means the tunnel is stable for the rest of a long
session.

## `ERROR: permission denied for table <x>` on an INSERT/UPDATE

**Likely cause**: you're connected as a read-only role. **This is working
as intended** — confirm with `SELECT current_user;`.

**What NOT to do**: do not run `GRANT` statements to work around this, and
do not conclude the environment is broken.

## A business-key lookup resolves *more* rows than expected (fan-out)

**Likely cause**: the business key is not actually unique in the
environment you're querying (real case: a duplicate `DISTRIBUTIONPANEL`
space existed under two floors on staging, since resolved).

**Diagnostic steps**: when a resolved count *exceeds* the expected count,
suspect a duplicate business key before suspecting a query bug. Compare
against production as the tiebreaker.

**What NOT to do**: do not silently pick "the first match" or add `LIMIT 1`
— that can attach data to the wrong physical location.

## Asset `INSERT` rejected: `"Asset space requires its floor and building."`

**Likely cause**: `metadata.validate_asset_physical_location()` requires
`building_id`/`floor_id` to be set explicitly whenever `space_id` is set —
it does not derive them from the space's own floor/building chain.

**What NOT to do**: do not set only `space_id` and expect the database to
infer the rest.

## A resolution in the aggregation chain is empty (e.g. `energy_consumption_5min`)

**Likely cause — check this before assuming a bug**: `_5min` is only
populated for sites whose effective capture interval is exactly 300
seconds. A 60-second-capture site correctly has an empty `_5min` table.

**Diagnostic steps**: `SELECT * FROM telemetry.resolve_site_capture_bucket(<site_id>, now());`
first.

**What NOT to do**: do not treat an empty `_5min` table as a pipeline
failure without checking the site's capture-interval policy first. See
[../06-platform/telemetry/aggregation.md](../06-platform/telemetry/aggregation.md).

## "Device model" or vendor/model string is ambiguous or unknown

**Likely cause**: the real vendor/model string was never seeded, and test
fixtures may be wrong (real case: staging fixtures said `vendor: 'Eniscope'`
while production's actual data says `vendor: 'Best Energy'` for the same
device type).

**Diagnostic steps**: query production (read-only) for the real value in
use; only fall back to test-fixture values as a last resort, and say so
explicitly.

**What NOT to do**: do not invent a vendor/model string because it "sounds
right."
