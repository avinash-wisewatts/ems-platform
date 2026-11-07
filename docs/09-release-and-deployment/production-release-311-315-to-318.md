# Production release: migrations 311 and 315–319 — checklist

(File name kept for links. 319 — the Administration App's read-only audit-history function, ADR-023 Amendment 3 — joined the release on 2026-11-04.)

Status: PREPARED 2026-11-04; **release approved by the release owner 2026-11-07 for immediate deployment, fresh backup waived** (see below).
Every step that touches production (dispatch, the backup, any SQL beyond the
read-only checks, rollback) needs its own explicit approval. Owner: Engineering.

## Backup waiver and risk acceptance (2026-11-07)

The release owner (Avinash Raavi) authorized this release on 7 November 2026
without a fresh production backup, and explicitly accepted the recovery risks,
having acknowledged in writing that application rollback does not reverse
database migrations or recover damaged data. This clears blocker B1 by waiver;
no backup was taken. No cleanup or deletion was authorized.

The most recent dump on the host is `prod_snapshot_20261023T0814Z.dump`
(6,845 MB, ledger 170 / head 298, pre-Release-D, never test-restored): it does
not contain anything written since 2026-10-23.

The approved release timing moved from the Friday 2026-11-13 07:30–09:00 UTC
window to immediately on Saturday 2026-11-07, also by the release owner. The
owner confirmed no active external users of the Administration App.

## Release blockers (all must be cleared)

| # | Blocker | State 2026-11-04 |
|---|---|---|
| B1 | Fresh production backup completed and checksummed | **Waived 2026-11-07 by the release owner (see above).** Previously: `safe_production_backup.sh` refused (free 29 GiB < database 36 GiB; no file written). Revised script (v2) proposed and tested, not approved: [../10-operations/backups-and-recovery.md](../10-operations/backups-and-recovery.md#proposed-one-time-guard-change-not-approved). |
| B2 | Production privilege exposure understood and addressed | **In progress.** Inventoried (read-only, below). 316 + 317 address `admin`; 318 the ten write-capable routines outside `admin`. Remaining sensitive *read* access: assessment below; no change without operational evidence. |
| B3 | 311 and 315–318 validated on staging | 311 (2026-10-25), 315, 316 and 317 (2026-11-04) done. 317 (#176, `b35a565`) reached staging through `rollback.yml` run 41821740458 (same image, `expected_migrations=317`) after a GitHub Git Operations incident broke run 41815489014, so `b35a565` has no successful `deploy-staging.yml` run and is not promotable. 318 (#177) pending merge and staging deployment; its prechecks evaluated read-only on staging pass (below). |
| B4 | Production prechecks re-run immediately before dispatch, and release approval | Open. |

## What the release is

| Item | Value |
|---|---|
| Release commit | the `staging` commit that contains 319, **after** its `deploy-staging.yml` run succeeded. Earlier candidates (`3dad83a`, `a6df50c`, `cf5338b`) are superseded. |
| Workflow | `deploy-production.yml`, `promotion_mode=staging-head`, `release_git_sha` = `confirm_release_git_sha` = that commit, **`expected_migrations=311,315,316,317,318,319`** (the precheck refuses any subset) |
| Current production (read-only, 2026-11-04) | `7e3da57`, image `ems-platform-app:7e3da57…@sha256:85fdfb5c347b657d7bc5d1a571941eb580fb2197d6b1aefe8c61e416bb7da8ca`, both services healthy; ledger 180 rows, head 308, fingerprint `e5ca12cf82fec87113098e76ab914f12`, nothing from 309 on |
| Content | the 22 `staging` commits after `7e3da57` (Reports 309/312, 310 backfill, 311, env-scoped migrations, ems-web container, customer API 313/314, edge, certificate checks) + #171 (Admin → Users, 315) + #174 (315 production-scoped) + #175 (316) + #176 (317) + #177 (318) + the Administration App user-management workflow and 319 |
| Services recreated | `admin-portal` and `live-telemetry` only (`deploy_release.sh`). `ems-web`, `customer-api` and `edge` are never created; the bind-mounted `/app` bundle is not updated, so the Admin → Users **screen** does not appear on production (blocked on D6). |
| Migrations | 311, 315, 316, 317, 318 and 319 apply; 309, 310, 312, 313, 314 `SKIP-ENV` |
| Inert on production | Reports, customer sessions, the web-container switch and the staff-only audience: `EMS_REPORTS_ENABLED`, `EMS_CUSTOMER_SESSION_SECRET`, `EMS_WEB_UPSTREAM`, `EMS_ADMIN_STAFF_ONLY` are all absent on production (key names checked 2026-11-04) and default off. |
| Goes live | `/api/admin/v1/*` (needs a staff session, `user.manage` except own password, same-origin JSON writes), 315's database rules, and 316–318's removal of `ems_readonly`'s write-capable and `admin` function grants and `admin.portal_users` access; the complete `/administration/users` workflow (details edit, password reset, own password, audit history via 319). `/app` stays served from the bundle on production: its no-`/app` rule applies only with `EMS_WEB_UPSTREAM` set. |

### Behaviour change on production

- `/administration/users`: an administrator can no longer change their **own**
  role, access scope or status, nor reset their own password through the
  managed function (42501; the page shows the message with HTTP 409). The
  **target** of a scope change must be inside the actor's scope. Only an
  active GLOBAL ADMIN may reset another ADMIN's password.
- **Sessions are not revoked by a password reset** (issue #172): an
  Administration App session stays valid until it expires or its owner signs
  out. After resetting a compromised account's password, also deactivate it
  until #172 ships.
- A database login as `ems_readonly` can no longer call any `admin`
  function (316 + 317; the PUBLIC-executable
  `list_accessible_asset_device_relationships` excepted), nor read
  `admin.portal_users`, nor call the ten write-capable routines (318). It
  keeps SELECT on analytics, telemetry, metadata, config and the other
  `admin` relations, and its read-only (STABLE / IMMUTABLE) function access.
  No application, Grafana datasource or release script connects as
  `ems_readonly` (repository search; 0 sessions at the 2026-11-04 snapshot);
  it is the operators' investigation login (`docs/10-operations/monitoring.md`).

## Production privilege exposure (read-only, 2026-11-04)

- `ems_readonly` (LOGIN, no memberships) could EXECUTE **98 of 110** `admin.*`
  functions, almost all SECURITY DEFINER, and SELECT every `admin` relation
  including `admin.portal_users.password_hash`. Staging and the test
  database grant it none of these. Production has **no default privileges**.
- **316**: the 14 portal-user management and authentication functions (11
  granted on production).
- **317**: every other explicit `admin` function grant (87: 44 SECURITY
  DEFINER writes, 28 actor-scoped reads, 6 volatile reads, 9 helpers) and all
  access to `admin.portal_users` and its sequence.
- **318**: the ten VOLATILE SECURITY DEFINER routines outside `admin`
  that write: `analytics.refresh_energy_consumption_{1min,5min,15min,hourly,daily}`,
  `telemetry.refresh_environment_daily`, `telemetry.ingest_live_rtdata`, and
  the trigger functions `config.ensure_asset_demand_policy_for_site`,
  `telemetry.capture_telegraf_mqtt_insert`, `telemetry.set_energy_measurement_asset_id`.
  Its precheck stops the migration if production has any *other*
  write-capable SECURITY DEFINER routine executable by `ems_readonly`, or if
  `ems_readonly` has become a member of any role (inherited EXECUTE would
  escape the explicit-ACL checks).
- `ems_readonly` has no INSERT / UPDATE / DELETE / TRUNCATE anywhere.

### Migration 318: expected effect per environment

| | Staging (read-only evaluation, 2026-11-04, ledger head 317) | Production (inventory, read-only, 2026-11-04) |
|---|---|---|
| The ten targets | present; SECURITY DEFINER, VOLATILE, owner `ems_admin`; explicit ACLs | same (inventory section 7) |
| `ems_readonly` EXECUTE on them | none (no explicit entry, not via PUBLIC) | all ten, explicit, **none via PUBLIC** |
| Other volatile SECURITY DEFINER routines with an explicit `ems_readonly` grant | 0 | 0 (exactly these ten listed) |
| `ems_readonly` role memberships | none | none |
| `ems_app` on `ingest_live_rtdata` | yes | yes (used by live-telemetry) |
| **Change 318 makes** | **none** — every REVOKE is a no-op; only the ledger row is added | **exactly ten ACL entries removed** (`ems_readonly=X/ems_admin` on each target); every other routine, relation, column and schema ACL identical |

If production has drifted since the inventory, 318 stops before revoking
anything (precheck) or rolls back (postcondition), and the release stops with
the reason in the deploy log; nothing is left half-applied.

### Remaining sensitive read access — assessment (no change proposed yet)

Still readable by `ems_readonly` after 318 (catalog inventory, no data read):

| Object / columns | Sensitivity | Operational use | Proposal |
|---|---|---|---|
| `admin.onboarding_drafts.payload`, `draft_token` | customer contact / site details; the token identifies a draft (no longer usable by `ems_readonly`: 317 removed the draft functions) | onboarding investigation | column-level revoke of `payload` and `draft_token`, keep status / timestamps |
| `admin.onboarding_audit.request_payload`, `result_payload` | full onboarding requests | incident review | keep, or replace with a redacted view (`admin.redact_audit_json` exists) |
| `admin.onboarding_event_audit` / `v_onboarding_event_audit` (`draft_token`, `event_context`) | draft identifier | timeline review | column-level revoke of `draft_token` |
| `admin.portal_user_audit.event_payload` | role / scope / status / e-mail changes; no hashes (tested) | user-management review | keep |
| `admin.audit_events.previous_values`, `new_values` | entity before / after values | change review | keep |
| `metadata.organizations.primary_contact`, addresses | personal contact data | rarely needed for telemetry work | column-level revoke of `primary_contact` |
| raw telemetry payloads | device data, no credentials | core investigation | keep |

**Evidence needed before any revoke** (operational impact must be proven):
which queries `ems_readonly` actually runs. It had 0 sessions at the
snapshot, and production keeps no per-role query history in the repository's
view. Options, each needing approval: (a) a read-only check whether
`pg_stat_statements` is installed and, if so, `ems_readonly`'s statements;
(b) temporarily enabling `log_connections` / statement logging for
`ems_readonly` (a configuration change); (c) asking the operators who hold the
`ems_readonly` credentials. Then a narrowly scoped migration 319, staging first.

## Migration 311 risks

| Risk | Assessment / mitigation |
|---|---|
| Changes `telemetry.recover_failed_raw_messages` (body 305 → 311) | Procedure body only; no table, data, job or grant change. Precondition met on production 2026-11-04 (body md5 `76e7c9e2`); the runner refuses otherwise. |
| Query plan of the bounded lookup | Custom plan: per-device index-only scan on one chunk (cost 5.6 / 6.4). Generic plan: Hash Join over the window's batches of all devices (~1.32 M rows, cost 46,164); `plan_cache_mode = auto` (EXPLAIN only, production 2026-10-25). Unbounded 305 scans all compressed chunks, so 311 is never worse. Staging: 5,046 ms → 11.9 ms. |
| Who runs it | Job 1061 (`run_failed_message_recovery_job`), **paused** on production (2026-11-04). Nothing exercises 311 at release time; resuming 1061 is a separate decision after the release. |
| First-deploy transition | Production runs `7e3da57`'s `deploy_release.sh` path the first time; the runner falls back to `ENVIRONMENT_NAME=production` for the scope (proven by staging's transition, run 40188640925). |
| Reversal | `postgres/maintenance/311_recovery_lookup_event_time_bound_rollback.sql`: guarded, restores 305's body exactly, no ledger change, tested in CI. Separate approval. |

## Migration 319

Read-only: one new SECURITY DEFINER function, no table, row, role or job change; catalog only, sub-second. Preconditions: `admin.portal_users`, `admin.portal_user_audit`, `admin.portal_user_scope_contains_user`, `admin.redact_audit_json`, role `ems_app` (all present on production per the baseline). No reverse migration is needed: if it is ever dropped, the Users pages show the history as unavailable.

## Migrations 315–318 risks

| Risk | Assessment / mitigation |
|---|---|
| Locks | Function replacement (315) and GRANT / REVOKE (316–318) update catalog rows only; no table rewrite, no data change; sub-second. |
| Application | `ems_app` keeps every function it calls (each migration asserts it); the previous image runs on all of them (rollback below). |
| Unreviewed drift | 316–318 each assert full before / after ACL snapshots; 318's precheck stops on an unreviewed write-capable routine. A failed postcondition rolls the migration back and the release stops. |
| Operators using `ems_readonly` | Lose `portal_users`, every `admin` function and the ten write routines; keep all SELECT and read functions. Portal-user checks, and any manual tier refresh (normally done by the jobs as their owner), run as `ems_admin` through the approved operator path; never re-grant to `ems_readonly`. |

## Before dispatch (read-only unless stated; each run needs approval)

1. **Exposure query**: `scripts/verify/portal_user_scope_exposure.sql`.
   Expect: one active GLOBAL ADMIN only, 0 rows in check 2. Any other row
   stops the release for review. Rule until 315 is applied: no tenant-level
   ADMIN is created on production.
2. **Precheck**: ledger 180 rows, head 308, fingerprint as above; image digest
   as above; 311 precondition `76e7c9e2`; 315's replaced functions present,
   its new ones absent; no customer-session or Reports objects; settings key
   names as above; `staging` HEAD = the release commit; 0 lock waiters / long
   transactions; disk; failures and failing jobs recorded as the baseline.
3. **Privilege baseline** (read-only): `ems_readonly` executable `admin`
   functions (98) and the ten routines (none via PUBLIC); no other
   write-capable routine executable by it and no role membership (318 would
   stop otherwise).
4. **Backup** (B1): completed, checksummed, `pg_restore --list` verified.
5. **Window**: a weekday 07:30–09:00 UTC (13:00–14:30 IST), clear of the F1
   policy runs (05:13 / 17:13 UTC) and the nightly reconcile (23:00 UTC); the
   backup (~50–60 min) finished first; no operator session in the
   Administration App. Deploy plus checks ~5–10 min.
6. **Dispatch** (approval). The workflow refuses unless the host's runner would
   apply exactly 311, 315, 316, 317, 318 and 319 and no staging-only migration.

## After the release (read-only)

- Ledger: 311, 315, 316, 317, 318 and 319 once each, checksums = repository files
  (311 `f6a0cb25…`, 315 `ec3e95e1…`, 316 `dbb40118…`, 317 `80c399fa…`, 318
  `68b3f080…`, 319 = staging's); prior 180 rows unchanged; no 309 / 310 / 312 / 313 / 314 row.
- 319: `admin.list_manageable_portal_user_audit` SECURITY DEFINER, STABLE, owner `ems_admin`,
  EXECUTE `ems_app` only; `ems_app` has no SELECT on `admin.portal_user_audit`.
- 315 functions: owner `ems_admin`, SECURITY DEFINER,
  `search_path=pg_catalog, admin[, metadata]`; body md5s equal staging's.
- 316–318: `ems_readonly` executes no `admin` function except the PUBLIC one
  (98 → 1), none of the ten routines, and has no privilege on
  `admin.portal_users`; `ems_app` executes every function the application
  calls (incl. `telemetry.ingest_live_rtdata`); `ems_readonly` SELECT
  elsewhere unchanged.
- 311: recovery body md5 `31f4db2f`.
- REQUIRED post-deploy gates pass, including "staging-only objects absent".
- `admin-portal` / `live-telemetry` on the pinned digest, healthy; `/health`
  200; no 5xx or tracebacks; signed-out `/api/admin/v1/users` → 401; live
  stream still updating (ingest via `ems_app`).
- Exposure query again: unchanged.
- Signed-in staff check of `/administration/users` — manual, by the operator
  ([../10-operations/admin-users-browser-checklist.md](../10-operations/admin-users-browser-checklist.md)).

## Rollback: application image only — 315–318 stay applied

**Procedure** (approval): `rollback.yml`, `target_environment=production`,
`image_tag=ghcr.io/avinash-wisewatts/ems-platform-app:7e3da5762ca6b69b1258f6264999ae546f7dc6a2@sha256:85fdfb5c347b657d7bc5d1a571941eb580fb2197d6b1aefe8c61e416bb7da8ca`,
`release_git_sha=7e3da57…`, **`expected_migrations=none`**.

Why this works with 311 and 315–318 still applied:

- The rollback precheck takes its deny scope from `origin/staging`
  (`precheck_release_migrations.sh`). 311 and 315–318 are not scoped there,
  so their ledger rows are not "leaks"; `7e3da57`'s manifest ends at 308, so
  nothing is pending (`test_rollback_to_7e3da57_after_the_311_and_315_to_318_release_is_allowed`).
  `7e3da57`'s runner only walks its own manifest and ignores later ledger rows.
- `7e3da57` calls `create_managed_portal_user` (9 args),
  `change_managed_portal_user_role` (3), `set_managed_portal_user_active` (3)
  and `set_managed_portal_user_access_scope` (5): 315 kept every signature,
  owner and grant. It never calls the three new functions. A 315 refusal
  reaches it as a `DatabaseError` and is shown as the page message (409).
- 316–318 remove only `ems_readonly`'s grants; `7e3da57` connects as `ems_app`.
- `7e3da57` runs on the 311 body (procedure only; job 1061 paused).

After a rollback: `/api/admin/v1/*` disappears (old image), the database rules
remain, and the post-deploy checks above are repeated for the old digest. If
311 itself must be reversed, its guarded rollback script is a separate,
approved step.

**Why there is no reverse migration for 315–318** (decision 2026-11-04):

- Reverting 315 reopens a live cross-tenant hole: an ORGANIZATION
  administrator could move a user of another organization, or a GLOBAL user,
  into their own organization, and administrators could change their own role,
  scope and status. Reverting 316–318 would let any `ems_readonly` login
  manage portal users, onboard and commission, read password hashes, or
  rewrite persisted energy tiers again.
- Nothing needs them reversed: the previous application image runs on all of them.
- The migration system is forward-only by design ([rollback.md](rollback.md)).
- **Must stay true:** none of 315–318 goes into
  `postgres/migration_environment_scope.csv`. If one did, every later
  production release and rollback precheck would refuse, because it would be
  "scoped away" yet recorded in production's ledger.

A defect in any of them is fixed by a **new forward migration** that keeps the
security rules, reviewed and released normally.
