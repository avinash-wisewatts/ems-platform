# 24. Troubleshooting

```
Status: CURRENT
Last verified: 2026-08-24
Verification basis: Staging (this session's own incidents), Repository
```

Format: **Symptom → Likely cause → Diagnostic steps → What NOT to do.** Every entry below is built from an incident this session actually encountered and resolved, not a hypothetical.

---

## "Device model" or vendor/model string is ambiguous or unknown

**Symptom**: You need to create a `metadata.device_models` row (vendor + model string) for a device type, and the only evidence you can find is test-fixture/mock data in `app/tests/*`, or a plausible-sounding guess.

**Likely cause**: The real vendor/model string was never seeded into the target environment, and test fixtures use placeholder values that don't necessarily match reality (e.g. this session found staging test fixtures said `vendor: 'Eniscope'`, while production's actual live data says `vendor: 'Best Energy'` for the same physical device type — the fixture was wrong).

**Diagnostic steps**:
1. Query production (read-only) directly for the real value already in use for that device type: `SELECT DISTINCT vendor, model FROM metadata.device_models WHERE device_category_id = (...)`.
2. If production has no such device yet either, check `metadata.gateway_models` for a related hint (vendor names are often shared between a gateway and its onboard devices).
3. Only fall back to test-fixture values as a last resort, and say explicitly in your work that you did so.

**What NOT to do**: Do not invent a vendor/model string because it "sounds right," and do not trust test-fixture mock data as if it were seeded production truth — verify against a real environment first.

---

## Staging DB connection fails: `Connection refused` vs `server closed the connection unexpectedly`

**Symptom**: A `psql` connection attempt to the staging tunnel (`127.0.0.1:15432`) fails.

**Likely cause / how to tell them apart**:
- `Connection refused` (or `Network unreachable`) — nothing is listening on that port. The tunnel itself is down.
- `server closed the connection unexpectedly` — the tunnel was up but dropped mid-connection or mid-query.

Both were observed multiple times in this session; see [23-known-issues-and-drift.md](23-known-issues-and-drift.md) item 3.

**Diagnostic steps**:
1. Retry once, immediately — transient drops sometimes self-resolve.
2. If it fails a second time, stop retrying in a loop. Report the exact error text (it tells you which of the two cases you're in) and that the tunnel needs to be reopened by whoever controls it.
3. Once told it's back up, verify with a trivial query (`SELECT 1;` or `SELECT current_user, current_database();`) before resuming real work.

**What NOT to do**: Do not loop retrying indefinitely, and do not assume a single successful reconnect means the tunnel is now stable for the rest of a long session — it dropped again after being confirmed working, more than once.

---

## `ERROR: permission denied for table <x>` on an INSERT/UPDATE

**Symptom**: A write against staging (or production) fails with a permission-denied error, even though read queries against the same table work fine.

**Likely cause**: You're connected as a read-only role (e.g. `ems_readonly`). This is **working as intended**, not a bug — the role's name and its granted privileges match (`SELECT` only; `INSERT`/`UPDATE`/`DELETE`/`CREATE` explicitly denied, confirmed for both the staging and production read-only roles this session).

**Diagnostic steps**:
1. Confirm the connected role with `SELECT current_user;`.
2. If it's a `*_readonly` role, this is expected — you need a write-capable role (e.g. `ems_admin`) for the operation, obtained through whatever credential-provisioning process the environment owner uses. Do not attempt to escalate the read-only role's privileges yourself.

**What NOT to do**: Do not run `GRANT` statements against a read-only role to work around this, and do not conclude the environment is broken — a permission-denied error on a write, from a role explicitly documented as read-only, is the system functioning correctly.

---

## A business-key lookup resolves *more* rows than expected (fan-out)

**Symptom**: A migration or query joins on a business key (e.g. a location `code`) expecting exactly N matches, but gets more than N — e.g. "found 25 of 22 rows resolved."

**Likely cause**: The business key is not actually unique in the environment you're querying, even though it should be conceptually. This session's concrete case: staging had two `metadata.spaces` rows both coded `DISTRIBUTIONPANEL` (under different floors), so any join on `(organization_id, space_code)` alone matched both, duplicating every row that referenced that space.

**Diagnostic steps**:
1. When a resolved count exceeds the expected count (not just falls short), suspect a duplicate business key before suspecting a bug in the query itself.
2. Query the presumed-unique key directly to find the duplicate: e.g. `SELECT code, count(*) FROM metadata.spaces WHERE organization_id = ... GROUP BY code HAVING count(*) > 1;`.
3. Compare against the authoritative environment (production) to see whether the duplicate is environment-specific drift or a real intended structure.
4. Disambiguate the join with an additional qualifier (e.g. also matching on floor code) rather than assuming the first/arbitrary match is correct.

**What NOT to do**: Do not silently pick "the first match" or add `LIMIT 1` to make the symptom disappear — that can silently attach data to the wrong physical location. Disambiguate deliberately, using the authoritative environment as the tiebreaker.

---

## Asset `INSERT` rejected: `"Asset space requires its floor and building."`

**Symptom**: Inserting into `metadata.assets` with `space_id` set (but not `building_id`/`floor_id`) fails with this exact error.

**Likely cause**: A live trigger, `metadata.validate_asset_physical_location()`, requires that if `space_id` is set, `building_id` and `floor_id` must also be set explicitly on the same row — it does not derive them for you from the space's own floor/building chain. See [23-known-issues-and-drift.md](23-known-issues-and-drift.md) item 1 for why this isn't obvious from the repository's DDL alone.

**Diagnostic steps**:
1. Resolve all three explicitly in your `INSERT`/`SELECT`: join `space → floor → building` and populate all three columns from that chain, not just `space_id`.
2. If disambiguating a duplicate space code (see the fan-out entry above) is also needed, do that first, then carry the now-unambiguous floor/building through.

**What NOT to do**: Do not set only `space_id` and expect the database to infer the rest — it will reject the row.

---

## A resolution in the aggregation chain is empty (e.g. `analytics.energy_consumption_5min`)

**Symptom**: One of the five `analytics.energy_consumption_*` resolutions has 0 rows for a device/org that otherwise has healthy telemetry and other resolutions populated.

**Likely cause — check this before assuming a bug**: `_5min` specifically is only populated for sites whose **effective telemetry capture interval is exactly 300 seconds** (see `postgres/ddl/143_persisted_validated_energy_consumption_5min.sql` and [11-aggregation.md](11-aggregation.md)). A 60-second-capture site (confirmed this session for Meenaxy Pharma / `UNIT_2` via `telemetry.resolve_site_capture_bucket()`) will *correctly* have an empty `_5min` table — its authoritative low-resolution history is `_1min` instead.

**Diagnostic steps**:
1. Check the site's effective capture interval first: `SELECT * FROM telemetry.resolve_site_capture_bucket(<site_id>, now());`.
2. If the interval is 60s, an empty `_5min` table is expected — check `_1min` instead.
3. If the interval genuinely is 300s and `_5min` is still empty, then investigate the job that populates it (`analytics.run_energy_consumption_5min_job`, check `timescaledb_information.jobs` for whether it's scheduled/active).
4. Also distinguish "not populated because too little time has elapsed" (e.g. `_daily` legitimately empty a few hours after telemetry started) from an actual gap — check whether enough wall-clock time has passed for that resolution's bucket to have closed at all.

**What NOT to do**: Do not treat an empty `_5min` table as a pipeline failure without first checking the site's capture-interval policy — this session initially suspected a bug here and it turned out to be correct-by-design behavior.
