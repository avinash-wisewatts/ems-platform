# Production Release Plan: Migrations 266 → 301

Status: **Release A deployed 2026-10-17 and accepted 2026-10-18** (section 6, "Release A acceptance"; 48-hour window closed 2026-10-19); **Release B1 (268, 269) deployed and accepted 2026-10-19** (section 2, "B1 execution record"); **Release B2 (14 migrations, 263–286) deployed 2026-10-20, D3 PASS** (section 2, "B2 execution record"); **Release C1 (15 migrations, through 291) deployed 2026-10-22 and accepted 2026-10-22 23:37 UTC** ("C1 acceptance"); **Release C2′ (292–295, 297, 298, `d52b049`) deployed 2026-10-23 05:23 UTC, run 39905366140, postcheck PASS; accepted 2026-10-25** ("C2′ acceptance"); **Release D (299–308, `7e3da57`) deployed 2026-10-23 13:00 UTC, run 39957525916, postcheck PASS; six migration-300 jobs kept on five-minute schedules (user decision); 24-hour acceptance pending** ("Release D execution record"); D1 / D4a / D4b / D8 / D9 decided 2026-10-17 (D8 condition confirmed), D3 decided 2026-10-19 for B1 and 2026-10-20 for B2, others open · Prepared: 2026-10-14 · Updated: 2026-10-25 · Owner: Engineering
Only Releases A and B1 have been executed. Every other dispatch, precheck and operator
step below needs its own explicit approval
([release-process.md](release-process.md#every-phase-requires-its-own-explicit-approval)).

This plan promotes production from migration 265 towards staging's head
in normal `deploy-production.yml` runs with
`promotion_mode=staging-milestone` ([ci-cd.md](ci-cd.md#promotion-modes)).
It continues the 223–290 staged promotion, whose Stages 1–3 (223–265) were
deployed on 2026-10-08. Releases A, B and C replace that plan's Stages 4–6
and keep the same commit boundaries.

**Update 2026-10-17.** Migration 300 passed its staging 24-hour acceptance
on 2026-10-15, but a read-only production assessment on 2026-10-16 found
production **NOT READY** for 299–302 (section 4, G3b). Release C is therefore
split into **C1** and **C2′**, which stop before 299. Migrations 299–302 and
the routing fix 303 form a later **Release D**, gated separately. The
assessment is recorded in the operations plan
(`docs/10-operations/staging-optimization-implementation-plan.md` §10.17,
a living document kept outside this branch).

Evidence labels used in this document:

- **[V]** verified from the repository, GitHub Actions or a read-only
  staging query on 2026-10-14.
- **[P]** production state from the last read-only production checks
  (2026-10-08 to 2026-10-14). Not re-checked for this document; the
  prechecks below re-check them.
- **[M]** measured on production by a read-only session on 2026-10-16
  (`default_transaction_read_only=on`, 30 s statement timeout).
- **[E]** estimate. **[A]** assumption.

## 1. Starting point

| Item | Value | Basis |
|---|---|---|
| Last production release | `9ca461e` (Stage 3, migrations 264–265), run `37746225677`, 2026-10-08 | [V] newest `deploy-production.yml` run |
| Production ledger | 131 rows, head 265 (before A); **133 rows, head 267** after Release A, 2026-10-17; **135 rows** (268, 269 added) after Release B1, 2026-10-19 | [P] / [M] |
| Staging HEAD | `b1c8b09` (migration 301), `deploy-staging.yml` run `38569347439` | [V] |
| Staging ledger | 173 rows, head 301, applied in manifest order, all 42 pending checksums equal to the repository files | [V] read-only query |
| Pending manifest rows | 42 | [V] |
| Staging HEAD on 2026-10-17 | `740cbaf` (migration 302), `deploy-staging.yml` run `38896720234`; ledger 174 | [V] |
| TimescaleDB | Production **2.28.2** [M]; staging **2.29.2** [V 2026-10-16]. The chain was tested locally on 2.28.2, but staging evidence comes from a newer minor version | [M] / [V] |

**Manifest order, not numeric order [V].** `scripts/apply_migrations.sh`
applies every `postgres/restructure_manifest.csv` row that has no ledger
row, in manifest order, each in its own transaction, and stops on a
checksum mismatch. The pending rows are:

```text
266 267 268 269 263 270 279 275 276 277 278 280 281 282 283 284 285 286
253 254 255 256 257 258 259 260 261 262 287 288 289 290 291 292 293 294
295 297 298 299 300 301
```

271–274 and 296 are not in the manifest. 296 is an unmerged draft (PR #122).

**No checksum risk [V].** Each of the 42 files was added by one commit
and never edited. No applied migration (≤265) changed between `9ca461e` and
`b1c8b09`.

**Migration 266 is first in every later milestone [V].** No commit
after `9ca461e` can be promoted without applying 266. Its precondition (G1
below) therefore gates every release.

## 2. Releases

| Release | Milestone (full SHA) | `deploy-staging.yml` | Migrations, in apply order | Ledger after |
|---|---|---|---|---|
| **A** (deployed 2026-10-17, accepted 2026-10-18) | `f06683d957b285754df2cebb1db5b737e2eb8d03` | `36022033311` success, 2026-09-24 | 266, 267 (2) | 133 |
| **B** (split: B1 = 268, 269 deployed 2026-10-19 from `546a718`; B2 = the rest, proposed) | `ba2cb4be254644c3ebd4a30b02b68f1d1ae4d601` | `37273913405` success, 2026-10-05 | 268, 269, 263, 270, 279, 275, 276, 277, 278, 280, 281, 282, 283, 284, 285, 286 (16) | 149 |
| **C** | `b1c8b0956ddecbdcbfe7d474bfeb1b7eae8cb485` | `38569347439` success, 2026-10-14 | 253–262, 287, 288, 289, 290, 291, 292, 293, 294, 295, 297, 298, 299, 300, 301 (24) | 173 |
| **C1** | `105c6c15e66785151b20ca4b605e797bc558973e` | `37738437514` success, 2026-10-08 | 253–262, 287–291 (15) | 164 |
| **C2′** | `d52b049b8acd2f741868f6ef10286e11767b07d4` | `38363172078` success, 2026-10-13 | 292, 293, 294, 295, 297, 298 (6) | 170 |
| **D** (not ready) | a staging commit containing 303 (not yet merged) | — | 299, 300, 301, 302, 303 (5) | 175 |

**Agreed split (2026-10-17).** Release C at `b1c8b09` is **not** used: it
contains 300. Production goes A → B → C1 → C2′, which keeps the 290 / 291
deadlines and stops before 299. Release D waits for gate G3b. C1 and C2′
are milestones that staging deployed successfully [V]; `d52b049`'s staging
deploy applied 298 alone and its 24-hour acceptance passed on 2026-10-14.

**301 and 302 wait for D.** The runner applies every pending manifest row in
manifest order and has no "stop at" option [V `scripts/apply_migrations.sh`],
so no milestone can deliver 301 without 299 and 300. 301's md5 preconditions
also rule out an equivalent earlier migration. 302 needs 300's phased
schedule to change anything. The routing fix 303 will be appended after 302,
so it cannot reach production before 299–302 either (decision D9).

All [V]. Each milestone is a strict descendant of `9ca461e` and of the
milestone before it, so the forward-only gate accepts them in this order.

**Never promote these commits [V]:**

- `59ba395` (266 alone): its staging post-deploy verification failed.
- `dfdb379` (263 without 270): CI failed. On staging, 263 alone made the
  canonical Energy read take about 25 minutes for fingerprint reads.
- `96d2893` (253–262 without 287): the assignment Save path moves ACTIVE
  assets into COMMISSIONING. 287 fixes this.

**Why three releases.** A cannot be merged into anything: 266 is first.
B and C are separate because their main risks differ (B: chunk locks and
the Grafana Energy read switch; C1 / C2′: the new F1 job, the bounded
environment loader and the demand schedule; D: ingest cadence, routing and
the deadlock fix). On the IO-limited production host, combining them would make
a regression hard to attribute. **Migration 301 ships in D**, in its
manifest position. No pending migration changes the two loader bodies that
301 replaces, and nothing depends on 301 [V].

**Non-migration content [V].** The releases also deploy the app image and
the repository at the milestone commit. There are no `compose.yaml`,
Grafana, Telegraf or env-file changes in any range.

- A: generated env-loader code.
- B: Analytics API.
- C: Analytics API, Admin Portal asset point assignment
  (`app/src/main.py`, `asset_detail.html`, `asset_point_assignment*.py`),
  `verify_jobs.sh`, `deploy-production.yml`.

`deploy-production.yml` does not deploy the Web SPA bundle. Production
therefore gets the Analytics API but not the Analytics UI. This is by
design until a production frontend rollout is separately authorized
([PHASE8_FRONTEND_DEPLOYMENT.md](../operations/PHASE8_FRONTEND_DEPLOYMENT.md#production-promotion--later-same-immutable-artifact)).

### Split of Release B (audit 2026-10-19; B1 approved and deployed 2026-10-19, B2 proposed)

[V 2026-10-19] After Release A, **every** later manifest commit's pending set
starts with 268, then 269, then 263. Because `apply_migrations.sh` applies all
pending rows in manifest order, no migration can reach production before 268
and 269, and none after 269 can reach it before 263 (G2). The commits that
add the next rows, with their pending sets on production:

| Commit | Pending on production | `deploy-staging.yml` |
|---|---|---|
| `c54e646a62ff7afc3f9141339e68ff58e5513bb1` | 268 | `36131058307` success |
| **`546a718dce6bcc005bcf32cff87947be3e9cb0fe`** | **268, 269** | **`36142660006` success** |
| `dfdb379` | 268, 269, 263 | failure (never promote) |
| `09e644b` | 268, 269, 263, 270 | `36171137551` success |
| `ba2cb4b` | 268 … 286 (16) | `37273913405` success |

Proposal: split B into **B1 = `546a718` (268, 269)** and **B2 = `ba2cb4b`
(263, 270, 279, 275–278, 280–286)**. B1 takes all of B's chunk-lock risk
without the Grafana read switch; B2 then carries only the G2 parity risk.

- Checksums [V]: the 42 pending files at `origin/staging` equal staging's
  ledger (268 `f8572080…`, 269 `313d39f4…`).
- App content [V]: `f06683d..546a718` changes only migrations, tests and docs,
  so the image behaves like Release A's.
- Lookup [V 2026-10-19 14:30 UTC, corrected]: the workflow's
  "Require a successful deploy-staging.yml run" step filters server-side
  with `gh run list --commit <sha>`, so the 100-run limit applies to runs of
  that one SHA, not to all staging runs. The earlier "50th of the latest
  100, expiry risk" reading was wrong. Running the step's exact query
  returns `36142660006` (success, 2026-09-25 13:42 UTC).
- Image [A]: the existence of `ghcr.io/<repo>-app:546a718…` was not verified
  (the token lacks `read:packages`). The workflow checks it and fails before
  any change if it is missing.

**B1 lock profile.** [V] 268 adds constant-default columns (catalog-only, no
rewrite) and NOT VALID checks to `energy_consumption_1min/5min`. 269 adds
counters to `energy_consumption_15min/hourly/daily`, a NOT VALID check on
1min/5min, and `CREATE OR REPLACE` of 10 Energy views and 5 functions. Each
migration takes ACCESS EXCLUSIVE on the hypertables, their chunks and the
views, in its own transaction. Staging execution was 1,135 ms and 628 ms.
Production ran Release A's migrations 1.1–1.3 times slower than staging,
250–252 and 265 1.8–3.1 times slower, and 264 20 times slower (5.4 s);
expect seconds to tens of seconds. [M] Production has
12 chunks for each of 1min, 15min, hourly and daily (5min has none) and
no default `lock_timeout` or `statement_timeout`, and the runner sets neither.
**The risk is lock queueing:** a long reader of these tables or views makes
the ALTER wait, and every later query queues behind it. Plan:

1. Dispatch window: away from the compression policies (16:34–16:36 UTC),
   retention (04:34 UTC) and reconcile 1131 (22:30 UTC). The migrations
   start about 2 minutes after dispatch (Release A: dispatch 12:02:47,
   apply 12:05:04).
2. Pre-dispatch (read-only): P1, P2 (pending exactly 268, 269), P10, plus no
   active or idle-in-transaction session older than 60 s on the Energy
   tables or views.
3. During apply (read-only): sample `pg_stat_activity` / `pg_locks` every
   5 s for sessions waiting on the migration backend.
4. Abort rule (needs approval as part of B1): if the migration waits more
   than 60 s while other sessions queue behind it, cancel the migration
   backend (`pg_cancel_backend`). Its transaction rolls back and the
   workflow stops. If 269 is cancelled, 268 stays applied. The containers
   keep the old image (section 6, "A release can stop partway").

**B1 verification.** Ledger 135 rows with the staging checksums; REQUIRED
gates; 268/269 postconditions (built into the migrations); the
`config.energy_reconstruction_scope` GLOBAL row disabled; jobs 1063, 1064,
1097, 1100, 1103 and 1062 keep succeeding; failure total unchanged; and a
read-only before/after comparison of closed-day Energy totals for the
PRIMARY_METER assets. [V] 269's golden tests prove its output is unchanged.

**B1 recovery.** Forward only. Everything in 268 is inert (switch off; no
writer). If a 269 read regresses, a forward migration re-creates the pre-269
definitions from `app/tests/fixtures/energy_269_baseline.sql`. No image
rollback is needed: the app image behaves like Release A's.

#### B1 readiness evidence (2026-10-19, read-only)

| Prerequisite | Evidence | Status |
|---|---|---|
| Ledgers | Production 133 rows, head 267; digest of `migration_id:checksum` over all rows `7e872b46…` = staging's same 133 rows [M] | Met |
| Pending set (P2, local) | Manifest at `546a718` minus the production ledger = exactly 268, 269 [V] | Met |
| Checksums | Repository at `546a718` = staging ledger: 268 `f8572080a4467f61…27e4a`, 269 `313d39f4951d11ad…31ed4` [V] | Met |
| Preconditions | 268 and 269 contain postconditions only (no environment preconditions) [V]; their objects are absent on production (precheck PRE line) | Met |
| Staging proof | `deploy-staging.yml` `36142660006` success (all CI gates, deploy, post-deploy verification). The workflow's own `--commit` lookup finds it [V 2026-10-19 14:30 UTC] | Met (no window expiry) |
| Image | `ghcr.io/avinash-wisewatts/ems-platform-app:546a718…` pushed 2026-09-25, digest `sha256:bbcbe139…` [V run log]; no image-cleanup workflow or script in the repository [V]; Release A's older image resolved on 2026-10-17. Not re-verified 2026-10-19: the package is private (anonymous pull 403) and the local `gh` token lacks `read:packages`; the production host's registry login was deliberately not used. The workflow's "Verify the SHA-derived image exists in GHCR" step checks it before any change | Expected; re-checked by the workflow |
| Forward-only | Last promoted release = `f06683d` (run `39030992116`); `546a718` is ahead [V]. An aborted B1 leaves `f06683d` as the reference, so the same SHA can be dispatched again; the runner then skips any migration already recorded with a matching checksum [V workflow + runner] | Met |
| Release A | Accepted; 48-hour observation closed 2026-10-19 14:20 UTC, all criteria PASS (1128/1129 12:05 runs Success, 1130 201/201 runs, 50/50 hours at 3,144 rows, 0 deficits, failure total 2840, 0 locks) [M] | Met |
| Precheck dry run | `prod_b1_precheck.sql` (sha256 `2cd0066fc220544e…`) on production 2026-10-19 14:34:52 UTC: every line PASS [M]. Not the binding run (step 2) | Met |
| Capture asset set | 56 PRIMARY_METER assets in active Grafana organizations [M 14:28 UTC] | Met |

**Dispatch window [M 2026-10-19].** All scheduled jobs run under 3 s; the
1-minute jobs (1062, 1063, 1064, 1044, routing) cannot be avoided and are
sub-second. Avoid :05–:09 past each hour (1103 :05:54, 1105 :08:28, 1057 at
07:09 / 19:09), 12:00–12:06, 16:34–16:51 (compression), 21:30, 22:30–22:32
(1131) and 04:34–04:42 (retention and compression). Migrations start about
2 min 15 s after dispatch. Recommended: dispatch at **HH:12 UTC** in 13:00–15:59
or 17:00–21:00 UTC, so the apply lands at about HH:14–HH:16. No Grafana
session was connected during the 2026-10-19 samples (only the app pool and
Telegraf).

**Procedure (each step needs the approval listed under "B1 approvals").**

1. Read-only, about 30 minutes before dispatch:
   `prod_b1_precheck.sql` (every line PASS); then
   `energy_parity_capture.sql` with `label=b1_pre1`, then again with
   `label=b1_pre2`: range `2026-09-23 18:30+00` → `2026-09-27 18:30+00`
   (site-local days Sep 24–27 IST, older than the 21-day daily
   `reconcile_window`), `resolutions=1d`, `max_assets=56`, `timeout=300s`.
   `energy_parity_compare.py b1_pre1 b1_pre2 --criterion full
   --expect-assets 56` must PASS (repeatability). Both captures must
   **finish before dispatch**: they read the tables B1 locks.
2. Re-run `prod_b1_precheck.sql` within 2 minutes of dispatch.
3. Dispatch `deploy-production.yml`: `release_git_sha` =
   `confirm_release_git_sha` = `546a718dce6bcc005bcf32cff87947be3e9cb0fe`,
   `promotion_mode=staging-milestone`.
4. Start `prod_b1_lockwatch.sql` (read-only, 5 s samples, stops by itself
   after 180 samples = 15 min) as soon as the workflow reaches the deploy
   job. Afterwards confirm no `ems_b1_lockwatch` session is left connected.
5. Abort rule: only if a sample shows `ABORT_CANDIDATE` (the migration
   backend has waited on one lock for 60 s or more **and** at least one
   session is queued behind it), run `prod_b1_guarded_cancel.sql -v
   pid=<mig_pid>` once. `LONG_WAIT` (60 s, nothing queued) is reported, not
   acted on. If the script prints no `CANCEL` line, `signalled` is false, or
   `AFTER15S` shows the backend still present: stop, report and wait. Never
   `pg_terminate_backend`.
6. After the workflow ends: `prod_b1_postcheck.sql` (every line PASS); then
   `energy_parity_capture.sql` with `label=b1_post`, same variables;
   `energy_parity_compare.py b1_pre2 b1_post --criterion full
   --expect-assets 56` must PASS (D3). Its
   timing lines are the canonical-read before/after comparison
   (cold-cache effect: compare with `b1_pre2`, not `b1_pre1`).
7. Next scheduled check after 1 hour, then the usual daily checks.

**Guarded cancel (the only action in the procedure):**
`scripts/diagnostics/prod_b1_guarded_cancel.sql`. It re-checks the whole
abort rule when it runs and calls `pg_cancel_backend` only if `:pid` is still
the migration backend (client backend, `ems_admin`, application `psql`, in
a transaction), still waiting on a lock, has waited 60 s or more, and has at
least one session queued behind it. Then it waits 15 s and reports whether
the backend is gone. It never calls `pg_terminate_backend`.

[V 2026-10-19 14:34–14:36 UTC, throwaway local postgres:16, read-only
session settings] At 3 s waiting: `WAITING`, guard refused. At 64 s with
nothing queued: `LONG_WAIT`, guard refused. At 83 s with one session queued:
`ABORT_CANDIDATE`, guard printed `CANCEL|147|true|84|1|84` and
`AFTER15S|147|false`; the fake migration's psql got "canceling statement due
to user request" and exited 3; the queued session completed.
[M 2026-10-19 14:28 UTC] On production the only `ems_admin` client sessions
are diagnostics; the app is `ems_app`, Telegraf `telegraf_writer`, and
TimescaleDB jobs are background workers, so they count as queued but can
never match the migration-backend filter. Any ad-hoc psql during the window
must set its own `application_name`.

Earlier simulation [V local, 2026-10-19]: the
waiting `LOCK … ACCESS EXCLUSIVE` statement fails with "canceling statement
due to user request". psql (`ON_ERROR_STOP`) exits non-zero, and the open
transaction (migration plus its ledger insert) rolls back. The queued
reader then completed. A non-matching pid returns 0 rows and cancels
nothing. On production, `apply_migrations.sh` and `deploy_release.sh` (both
`set -Eeuo pipefail`) then stop before `compose up`. The deploy job fails,
`verify-production` is skipped (`needs: deploy-production`), and the
containers keep Release A's image while the host checkout is at `546a718`
(section 6). If 269 is cancelled, 268 stays applied (134 rows); a later
dispatch of the same SHA applies 269 only.

**Tooling status [V 2026-10-19].**

- `prod_b1_precheck.sql`: ran on the local dev database (syntax and logic;
  local IDs differ, so its FAIL lines there are expected).
- `prod_b1_postcheck.sql`: ran read-only on staging, where 268/269 are
  applied. Every 268/269 postcondition and the switch check PASS; the ledger,
  failure-total and paused-job lines FAIL there as expected (staging
  differs).
- `prod_b1_lockwatch.sql`: local simulation (reader holding ACCESS SHARE,
  migration waiting for ACCESS EXCLUSIVE, a job queued behind it). It
  identified the migration pid, its blocker and the one queued session, and
  flagged `ABORT_CANDIDATE` at 63 s, not before. Since 2026-10-19 14:40 UTC
  it requires a queued session for `ABORT_CANDIDATE` (`LONG_WAIT`
  otherwise) and stops after 180 samples: an unbounded `\watch` stopped by
  killing its client left an idle backend connected in the local test.
- `energy_parity_compare.py --expect-assets N`: INVALID unless both
  captures cover exactly N assets with one line per resolution (local
  synthetic tests: PASS 0, value mismatch 1, missing asset 2, full-column
  mismatch 1).
- `energy_parity_capture.sql` + `energy_parity_compare.py`: locally,
  read-only, repeatable, timeout and bad-range runs fail closed (INVALID),
  and six negative comparator cases are detected. Staging minimal probe
  (1 asset, `1d`, 4 days, run twice): identical full fingerprint, 4 rows,
  1.7 s cold / 0.34 s warm. **Not yet run on staging for all assets or
  for P5's resolutions** (needs approval).

#### B1 execution record (2026-10-19) — DEPLOYED

Approvals given by the user 2026-10-19: D3 = exact equality, zero
tolerance, `1d` only, exactly 56 assets; dispatch 17:12 UTC; read-only
steps; deployment; guarded cancel at most once on `ABORT_CANDIDATE`.

| Step | Evidence [M] | Result |
|---|---|---|
| Precheck (T−20 min) | 16:52:41 UTC, 12/12 PASS | PASS |
| Baseline captures | `b1_pre1` 16:52:50 (56 calls, 0 errors, 17.5 s), `b1_pre2` 16:53:20 (56, 0, 11.9 s); compare `--criterion full --expect-assets 56` PASS. Baseline: 48 assets × 4 days, 6 × 3, 2 × 0; 52 with import > 0; 25,193.8 kWh | PASS |
| Final gates | 17:10:10 precheck 12/12 PASS; lookup → `36142660006` success | PASS |
| Dispatch | First attempt at 17:12 blocked by the agent's permission classifier (nothing created). After explicit user permission: fresh precheck 17:22:35 PASS + lookup PASS, dispatched **17:22:38 UTC**, run `39293585987` | — |
| Workflow | Validate 17:22:48–17:22:58; deploy 17:23:01–17:24:16; verification 17:24:19–17:26:00; all success. Image `…:546a718…@sha256:bbcbe139…`. APPLY exactly 268, 269; 133 SKIP. REQUIRED gates PASSED. Advisory FAILs: energy-routing pipeline "2 stages not SUCCESS" (at 17:28:37 only the known `derived_space_dew_point_1min` NEVER_RUN remained → second one transient, not identified), alert job unregistered, 1 disabled policy (1053) — all pre-existing in kind | PASS |
| Lock watch | 180 samples 17:22:53–17:37:48 (stopped itself at `c=180`): 166 IDLE, 14 RUNNING, max lock wait 0 s, queued 0 throughout; no `WAITING`/`LONG_WAIT`/`ABORT_CANDIDATE` | Guarded cancel **not used** |
| Ledger | 135 rows; 268 applied 2,642 ms, 269 applied 1,036 ms, staging checksums; earlier 133 digest unchanged | PASS |
| Postcheck | 17:25:02 all PASS (columns, NOT VALID checks, switch OFF, counters, 7/7 security_barrier, failure total 2840, 0 errors, 8/8 paused, 0 lock waiters). Job 1062's line printed blank (it was mid-run, NULL fields); checked separately: Success 3.2 s | PASS |
| Post-deploy refresh jobs | 1097 (15 min) 17:26:41 Success, 1100 (hourly) 17:28:17 Success, 1063/1064/1062 Success; 1103 (daily) 18:05:54 Success 0.37 s. 18:07 UTC check: failure total 2840, 0 failing, 0 job errors, 8/8 paused, 0 lock waiters, lag energy 110 s / environment 170 s, 0 leftover `ems_b1_*` sessions, admin-portal + live-telemetry healthy on the `546a718` image | PASS |
| D3 parity | `b1_post` 17:28:46 (56 calls, 0 errors, 20.8 s); read function REPLACED (`0cbac573…` → `57470d84…`); `b1_pre2` → `b1_post` `--criterion full --expect-assets 56` **PASS**, 56/56 identical | PASS |
| Canonical-read timing (`1d`) | `b1_pre2` p50 198 / p95 404 / max 458 ms; `b1_post` p50 258 / p95 1,102 / max 1,522 ms. `b1_post` was the first call set after the function replacement; it resembles the cold `b1_pre1` (p50 256 / p95 714 / max 1,037 ms). One post capture cannot separate cold cache from a plan regression | Informational; see warm repeat |
| Warm repeat (approved 2026-10-19) | `b1_warm` 19:06:43 UTC, read-only, same 56 assets / range / `1d`: 56 calls, 0 errors, 17.1 s; read function `57470d84…` (unchanged since deploy). D3 `b1_pre2` → `b1_warm` `--criterion full --expect-assets 56` **PASS**, 56/56 identical. Timing p50 271 / p95 465 / max 1,376 ms | PASS (parity); timing below |

**Timing after the warm repeat [M] (diagnostic only; D3 unchanged).**

| Capture | First 3 calls (ms) | p50 / p95 / max, calls 3–56 (ms) |
|---|---|---|
| `b1_pre1` (cold, pre-269) | 831, 1,037, 987 | 252 / 503 / 987 |
| `b1_pre2` (warm, pre-269) | 359, 150, 136 | 198 / 404 / 458 |
| `b1_post` (first after 269) | 1,522, 1,407, 1,257 | 253 / 667 / 1,257 |
| `b1_warm` (post-269, +1 h 38 min) | 1,376, 1,172, 760 | 267 / 404 / 760 |

- The p95 of 1,102 ms did not persist. Once the first three calls are
  excluded, `b1_warm`'s p95 equals the baseline (404 ms).
- The median stayed about 35% higher across all assets: 4-row assets
  198 → 272 ms (n=48), 3-row assets 219 → 278 ms (n=6).
- The slow first three calls are the same three assets every time
  (`05264ec8`, `061e78ef`, `1128ade6`). They were also slow in the cold
  `b1_pre1`, and fast only in `b1_pre2`, which ran 30 s later. So they
  are not a session-start cost; see the read-path diagnosis below.

**Read-path diagnosis (approved 2026-10-20, read-only) [M].**

Run on production 05:46–05:48 UTC.
- Sample: four assets (`3e5c227c` median, `6d03dc97` slowest,
  `d15a45e4` 3-row, `05264ec8` slow-first), 1d, same range as D3.
- Statement timeout 15 s. Load guard: 1-min load ≤ 1.0 and ≥ 300 MB
  available, never tripped (peak 0.72, ≥ 650 MB). No leftover sessions.
- Pre-269 vs post-269 is a same-moment A/B: both 1d view chains, inlined
  as CTEs with the same shape.
  - Old chain from `app/tests/fixtures/energy_269_baseline.sql`. Only
    migrations 032–035 defined these views before 269, so this is
    production's pre-B1 definition.
  - New chain from migration 269.
  - Also measured: the real view and `get_canonical_energy_read`.
  - Equivalence: for every asset, the new inline query returns exactly
    the real view's rows (full-row md5), and old and new agree on every
    value column.

| Measure | Pre-269 chain | Post-269 chain | Real view (post-269) |
|---|---|---|---|
| Planning, first statement of a fresh session | 62–148 ms | 66–109 ms | 71–99 ms |
| Planning, warm | 6–10 ms | 7–11 ms | 6–10 ms |
| Execution, 2nd run (TIMING OFF), median of 4 | 204 ms (158–226) | 264 ms (242–295) | 268 ms (216–282) |
| Execution, 1st run in session | 252–412 ms | 245–446 ms | 266–317 ms |

- Function calls: first call in a fresh session 295–370 ms; warm
  180–222 ms (`05264ec8`: 305–323 ms).
- First touch of `05264ec8`: 3,273 shared-buffer reads, 424 ms against
  about 250 ms warm.
- Findings:
  - **Planning is not the cause.** Cold-session planning is under
    150 ms, both chains are similar, and warm planning is under 12 ms.
  - **269 adds about 60 ms of CPU per 1d call (about +30%) in the
    15-minute rollup.** For `05264ec8`, comparing self time old → new:

    | Stage | Old | New |
    |---|---|---|
    | Native scan | 68 ms | 81 ms |
    | Sort (wider rows) | 84 ms | 108 ms |
    | 15-min aggregate (extra `FILTER` / `NOT interior` aggregates) | 62 ms | 102 ms |

    For `3e5c227c`, the old plan aggregated partially in parallel workers.
    The new plan aggregates serially after `Gather`.
  - **Pre-existing, larger factor: the 1d read aggregates the device's
    whole retained native history.** This is the same before and after
    269.
    - Chunk scans are bounded only by `device_id`. All 22 chunks of the
      two native hypertables are read; the 1-min table holds 12 chunks,
      2026-07-30 → 10-22.
    - The date range applies only after the 15-min rollup, at the join to
      `metadata.sites`. For `05264ec8`, 5,923 of 6,257 buckets are
      discarded and 334 kept; about 92,600 native rows are aggregated for
      a 4-day read.
    - Read cost therefore grows with history length, not with the
      requested range. 269's per-row cost is applied to all of it.
  - **The 1.2–1.5 s first calls in the captures were not reproduced.**
    Cold-buffer reads explain about +170 ms. The remainder at 17:28 and
    19:06 is unexplained [I]. Likely causes are colder cache plus
    concurrent refresh jobs on the 2-vCPU host; not verified.
- Recommendations (none approved, no action taken):
  1. Accept 269's +60 ms per call. Its cause is understood, and 1d reads
     stay around 0.3 s.
  2. Treat the unbounded 1d native scan as a design follow-up. Options:
     - bound `bucket_start` in the 1d branch of `get_canonical_energy_read`
       (a site-timezone-padded range);
     - read the persisted `analytics.energy_consumption_daily` tier, which
       269 extended with the counters.

     Either is a migration with its own parity proof. The same
     view-chain pattern likely affects the other aggregate tiers; check
     with plan-only EXPLAIN locally or on staging first.
  3. No further production diagnostics needed for B1.

Follow-ups:

- **Postcheck NULL lines: fixed locally 2026-10-19, not run on
  production.**
  - Cause: while a job runs, TimescaleDB's `job_stats` has
    `last_run_duration` NULL. The concatenated line, including its
    PASS/FAIL suffix, became NULL.
  - Effect on the gate: it only looks for `FAIL`, so it passed silently.
    A previous **Failed** run on a mid-run job would also have printed
    blank and passed. A job or `point_telemetry_1h` row missing from the
    catalog printed no line at all.
  - Fix in `prod_b1_postcheck.sql`:
    - The energy-job line is now driven by the 6 expected job ids,
      left-joined to `job_stats`.
    - All fields are coalesced. A missing job prints `none … FAIL`.
    - A running job prints `<status of previous run> (previous run;
      running since HH:MM:SS) PASS/FAIL`.
    - The 1h checkpoint line is NULL-safe the same way.
    - A full pass prints exactly 26 PASS lines. The runbook gate now
      requires exactly 26; the B1 run printed 25, so the blank line would
      have been caught.
    - The `INFO routing lag` line (ungated) prints `unknown` for a
      missing `pipeline_state` row or NULL timestamp instead of a blank
      line (2026-10-20).
    - Pinned sha256 prefix: `6244577e4711dabe`. History: `5ea5e2bbe8cc0a6a`
      at the B1 run, then `dc193de898b34222` after the health-line fix on
      2026-10-19.
  - Local test: dev DB, HEALTH section, in a transaction that was rolled
    back (catalog verified unchanged).

    | Scenario | Original | Fixed |
    |---|---|---|
    | 1062 mid-run, previous Success | line missing | `PASS` line |
    | 1062 mid-run, previous Failed | line missing (gate passes) | `FAIL` line |
    | Duration NULL, not running | line missing | `(- s) PASS` |
    | Jobs absent from the catalog | no lines | `FAIL` lines |
  - Gate fail-closed check (rerun 2026-10-20 on `6244577e…`, local,
    `b1_psql` stubbed). Only a 26-PASS, rc 0, FAIL-free output passes
    (gate rc 0). Every other case returns gate rc 1:
    - the B1-run output (25 PASS, blank line);
    - a missing line (25);
    - an extra line (27);
    - a FAIL line;
    - empty output (rc 0 and 255);
    - an SQL error (rc 3);
    - 26 PASS with rc 1;
    - a tampered script (pin mismatch, psql not run).

    The full script on the local 269-schema test DB runs with rc 0, 0
    errors, all 26 gated lines present and 0 blank result lines. On a
    pre-268 DB it exits 3.
  - INFO line, local dev DB, rolled back (rows verified unchanged):

    | Scenario | Output |
    |---|---|
    | Known timestamps | `energy=110 s environment=170 s` |
    | Energy row missing | `energy=unknown environment=170 s` |
    | Environment timestamp NULL | `energy=110 s environment=unknown` |
    | `normalized_points` missing | both `unknown` |
    | All three rows missing | both `unknown` |
- Timing: diagnosed 2026-10-20 (above); the unbounded 1d native scan is a
  design follow-up
  ([energy-read-unbounded-history-scan.md](../06-platform/telemetry/energy-read-unbounded-history-scan.md)).
  Decided 2026-10-20: its A2 fix is **deferred, deployment NO-GO**, and it
  does not block B2, C1, C2′ or D.
- Postcheck `INFO routing lag` blank line: fixed 2026-10-20 (above), not
  run on production.

#### B2 preparation (2026-10-20, local; nothing run on production)

State [M 2026-10-20, read-only ledger reads]: production 135 rows, head 269;
staging 178 rows, head 306 = `origin/staging` `e844e2a`. Every ledger
checksum on both equals the repository. Manifest at `ba2cb4b` minus the
production ledger = exactly 263, 270, 279, 275, 276, 277, 278, 280, 281,
282, 283, 284, 285, 286 (ledger after: 149). All 14 files are unchanged from
`ba2cb4b` to `origin/staging`; staging's checksums equal them.
`deploy-staging.yml` `37273913405` succeeded for `ba2cb4b`; `546a718` →
`ba2cb4b` → `origin/staging` is a forward chain.

**Migration 283's precondition depends on the session time zone [V].** It
pins `md5(pg_get_viewdef('analytics.v_energy_semantic_rollup_15min'))` =
`7a79ad57…`, which `pg_get_viewdef` produces only in an `Asia/Kolkata`
session (the `date_bin` origin is rendered in the session time zone; UTC
gives `394451e7…`). The runner sets no time zone, so production's
`ems_admin`/`ems` default must still be `Asia/Kolkata` at dispatch. The
precheck checks both.

Tooling (`scripts/diagnostics/`; local tests in `scripts/diagnostics/b2_tests/`, see `lib.sh`):

- `prod_b2_precheck.sql`: 26 checks. Ledger 135 rows with digest
  `f7273fa8…`; pending set exactly the 14 in manifest order (`ba2cb4b`'s 149
  manifest rows are embedded); no ledger row outside that manifest; canonical
  read = 269 body (`57470d84…`); runner time zone and 283's view pin; 27
  objects and roles B2's preconditions need; nothing B2 creates exists yet;
  bridge 112 rows / 56 assets = the capture set; P10 (2840, no errors since
  2026-10-17 12:00 UTC, 1053 and 1114–1120 paused); six Energy jobs; no
  long, idle-in-transaction or `metadata.sites` lock holders.
- `prod_b2_postcheck.sql`: 45 checks. Ledger 149 rows; each of the 14 with its
  staging checksum, applied in manifest order after the B1 rows; B1 rows
  unchanged (`f7273fa8…`); all 149 = staging's digest (`a6d33cb0…`); ten
  function definitions and their PUBLIC / `ems_app` / `grafana_reader`
  execute privileges; the two dropped functions absent; 280's availability
  comment; 275's trigger enabled; bridge unchanged; health as B1 (2840, no
  errors, Energy jobs, lock waiters, paused jobs, 1h checkpoint).
- `prod_b2_gate.py`: fail-closed gate. PASS only with psql exit 0, exactly
  the expected keys once each, all PASS, one `now` line, `INFO` lines, and
  the `END` line last; anything else (blank, ERROR / WARNING, truncation,
  duplicate, unknown key) fails.

Local validation [V 2026-10-20, disposable test container]:

- A database built from `546a718` (canonical deploy + runner, 135 migrations)
  equals production's B1 state: ledger digest `f7273fa8…`, canonical read
  `57470d84…`, 283's view pin `7a79ad57…` (Asia/Kolkata). The runner at
  `ba2cb4b` then listed exactly the 14 as pending and applied them (14 APPLY,
  135 SKIP, 283's precondition passed), ledger digest `a6d33cb0…`.
- On those databases every precheck and postcheck line passes except the
  seven that read production-only state (database name, the 56-asset bridge,
  baseline 2840, production job IDs, 1h checkpoint).
- 22 mutation cases on copies of those databases fail exactly the intended
  checks (ledger checksum, extra / missing / foreign ledger row, UTC default
  time zone, a B2 object or trigger already present, canonical body changed,
  `metadata.sites` lock holder, ledger order, PUBLIC grant, revoked Grafana
  grant, disabled trigger, re-created dropped function, comment, missing
  function).
- 39 gate cases (both kinds) behave as specified.
- Staging, read-only: the postcheck's seven function pins for functions no
  later migration replaces match staging exactly; the three that 288 / 302
  replace match those migrations' own md5 pins of the B2 definitions.

**Precheck run 1, 2026-10-20 13:49:45 UTC [M production, read-only]: gate
FAIL, stopped.** 25 of 26 PASS (ledger 135 / `f7273fa8…`, pending exactly the
14, runner time zone Asia/Kolkata and 283's view pin `7a79ad57…`, canonical
269 body, bridge 112 / 56 = capture set, failure total 2840, 0 errors, 1053
and 1114–1120 unscheduled 8/8, no lock holders). `JOBS.1063` failed: the
1-minute job was mid-run and `job_stats.last_run_status` is NULL during a run
(TimescaleDB resets `last_finish` to -infinity at start). No captures ran.

**Fix (local, 2026-10-20; precheck `42a6b831…`, postcheck `fb0e81b5…`, gate
unchanged `d69387a6…`).** Job lines read `_timescaledb_internal.bgw_job_stat`:
Scheduled needs the latest completed run 'Success'; Running needs the previous
completed run to have succeeded (`last_run_success`, 0 consecutive failures, a
successful finish other than -infinity) and the failure total still 2840;
Paused, missing job or stats row and NULL evidence fail. `P10.failures` /
`HEALTH.failures` count a job as failing from `last_run_success`, so a running
job whose previous run failed is no longer missed. The postcheck had the same
defect (a running job printed `none … FAIL`), shown by the tests. Tests: 28
job-state cases (14 per script, running and not running, previous failure,
changed failure count, NULL status, never succeeded, missing stats row or job,
paused, SQL error), the 22 earlier mutation cases and 39 gate cases all pass;
the fixed postcheck runs read-only on staging.

**D3 for B2: decided 2026-10-20.** Exact equality, zero tolerance,
`energy_parity_compare.py --criterion full --expect-assets 56`, 0
`PARITY_ERROR`, for two captures per stage: range `2026-09-23 18:30+00` →
`2026-09-27 18:30+00` (the B1 range) at `1d,1h,15m`, and the closed day
`2026-09-26 18:30+00` → `2026-09-27 18:30+00` (IST Sep 27) at `native`.
Repeatability gate: pre1 vs pre2 PASS for both before dispatch; then pre2
vs post PASS for both. Reconcilers 1114–1120 stay paused from the first
capture to the last. The read function changes (269 → 270): the comparator
reports `REPLACED`, which is expected. Timing is informational.

**Proposed staging validation (not run; needs approval).** Read-only, at
`origin/staging` (already past B2, so it validates tooling, repeatability,
timing and errors at full scale, not B2's before/after): two range captures
and two native captures with the D3 parameters for staging's 54 assets
(2 × 162 + 2 × 54 = 432 canonical-read calls), one session at a time,
`statement_timeout` 300 s per capture, `lock_timeout` 2 s; a guard before
each capture (load1 < 1.5, MemAvailable > 400 MB, no lock waiter) and stop
on any guard failure, timeout or `PARITY_ERROR`; then compare each pair
locally with `--expect-assets 54`.

**Staging validation, 2026-10-20 13:22–13:46 UTC [M staging, read-only].**

| Capture | Guard before (load1 / MB available / lock waiters) | Result |
|---|---|---|
| `b2s_pre1_range` | 0.60 / 759 / 0 | 162 calls, 0 errors, 39.1 s; 54 assets with rows |
| `b2s_pre1_native` | 1.00 / 771 / 0 | 54 calls, 0 errors, 1.7 s |
| `b2s_pre2_range` | 1.00 / 775 / 0 | 162 calls, 0 errors, 32.8 s |
| `b2s_pre2_native` | **1.51** / 781 / 0 at 13:24 | **not run: guard failed (load1 ≥ 1.5); workload stopped** |
| `b2s_pre2_native` (approved re-run, 13:46 UTC) | 0.70 / 768 / 0 | 54 calls, 0 errors, 1.5 s |

- `b2s_pre1_range` vs `b2s_pre2_range`, `--criterion full --expect-assets 54`:
  **PASS**, 162 pairs, read function unchanged (`667f9cc2…`, 270).
- Timing (informational, per call): 1d p50 232–353 ms (max 2.1 s, first
  capture); 1h p50 240 ms (max 0.9 s); 15m p50 85 ms; native p50 28 ms.
- `b2s_pre1_native` vs `b2s_pre2_native`, same criterion: **PASS**, 54 pairs.
- **Staging validation PASSED** (432 calls, 0 errors, both pairs exact). No
  session left after either run.

#### B2 execution record (2026-10-20, production)

| Step | Result |
|---|---|
| Precheck run 2 (fixed script `42a6b831…`), 16:11:57 UTC | 26/26 PASS, gate exit 0 |
| Baseline captures, guard before each (load1 / MB / waiters) | `b2_pre1` range 0.16/740/0, 168 calls, 0 errors, 32.9 s; native 0.77/714/0, 56 calls, 1.6 s; `b2_pre2` range 0.89/718/0, 168 calls, 30.9 s; native 1.29/717/0, 56 calls, 1.4 s |
| pre1 vs pre2 (`--criterion full --expect-assets 56`) | range **PASS** 168 pairs; native **PASS** 56 pairs; read function unchanged (`57470d84…`) |
| Dispatch-time precheck, 17:09:37 UTC | 26/26 PASS, gate exit 0; staging proof lookup = `37273913405` |
| Dispatch | **17:12:01 UTC**, `deploy-production.yml` staging-milestone `ba2cb4b…`, run `39463974731` (validate 17:12:08–17:12:17, deploy 17:12:20–17:13:47, verification 17:13:49–17:15:21): success. 14 APPLY in manifest order, 135 SKIP; REQUIRED gates PASS. Advisory FAILs identical to B1's run `39293585987` (2 pipeline stages, alert job not registered, 1 disabled job) |
| Lock watch | Migration backend sampled 17:14:18–17:15:08: RUNNING only, 0 s lock wait, 0 blockers, 0 queued. No `ABORT_CANDIDATE`; guarded cancel not used |
| Postcheck, 17:16:08 UTC | 45/45 PASS, gate exit 0: ledger 149, digest `a6d33cb0…` (= staging), earlier 135 unchanged, ten function pins, trigger enabled, failures 2840, paused 8/8, 1h checkpoint 17:00 SUCCESS; routing lag energy 57 s |
| Post captures | range guard 1.14/657/0, 168 calls, 0 errors, 48.4 s; native 1.01/673/0, 56 calls, 1.9 s; read function `667f9cc2…` (270) |
| pre2 vs post | range **PASS** 168 pairs; native **PASS** 56 pairs; read function REPLACED (expected). Timing informational: range p50 179 → 254 ms, max 845 ms → 2.15 s |
| After | 1053 and 1114–1120 unscheduled; failure total 2840 |

**B2 deployed 2026-10-20; D3 PASS.** Production ledger 149, head 286.

#### C1 preparation (2026-10-21; nothing changed on production)

State [V / M 2026-10-21, read-only]: production 149 rows, digest `a6d33cb0…`
(head 286); staging 178 rows, head 306, at `8490e48` (`deploy-staging.yml`
`39552368907`: 0 APPLY, 178 SKIP, ledger digest unchanged). Manifest at
`105c6c1` = `ba2cb4b`'s 149 rows plus exactly 253, 254, 255, 256, 257, 258,
259, 260, 261, 262, 287, 288, 289, 290, 291 (ledger after: 164, digest
`0591dde9…` = staging's same 164 rows). Each of the 15 files was added once,
never edited, and is byte-identical at `origin/staging`; staging's checksums
equal them. `deploy-staging.yml` `37738437514` succeeded for `105c6c1` (all CI
gates, deploy, post-deployment verification). `ba2cb4b` → `105c6c1` →
`origin/staging` is a forward chain.

Local validation [V, disposable test container, copy of production's B2
state]: the runner at `105c6c1` applied exactly the 15 (15 APPLY, 149 SKIP)
in an Asia/Kolkata **and** in a UTC session. No C1 precondition depends on
the session time zone; every post-C1 definition is the same in both. The
post-C1 state equals staging's for every C1 object except the environment
loader (replaced on staging by 303), staging's `ems_investigator` grants and
its one live commissioning record.

Production compatibility [M 2026-10-21 06:36 UTC, read-only transaction, 3 s]:

- 288: catalog `586a533d…`, availability `ab4e1d4d…`, comment `bb352ba5…`, no
  object depends on the catalog. 290: every dependency present, nothing it
  creates exists. 291: loader body `a3820ee2…` (267's),
  `bucket_start` is a compression order-by column. Roles `ems_admin`,
  `ems_app`, `ems_readonly` exist. No locks on the C1 tables.
- Reference data (units, display categories, parameters, logical points) is
  identical to the tested database (four digests and a line diff), so
  254 / 262 / 289's data postconditions behave as tested.
- **P9.** F1 (290): the oldest `energy_measurements` data is
  2026-08-04 12:11 UTC (one device); several devices from 2026-08-09. With
  90-day retention (daily at 04:34 UTC) real loss starts about
  **2026-11-03** (2026-11-08 for several devices). 290's first run starts
  at that oldest row. 291: **53,634** rows in compressed
  `environment_measurements` chunks (43,600 on 2026-10-08); the 267 loader
  fails above 100,000.

290 operational load [V staging, E production]: the forward job backfills one
day per 5-minute run from 2026-08-04, about 80 runs (about 7 hours). Staging:
forward job 3,973 runs, 0 failures, 2.6 s average; reconcile job 14 runs, 0
failures, **278 s per daily run** (first production run at 23:00 UTC after
deploy). Daily source volume is the same (`energy_measurements` chunk 64 MB
production, 65 MB staging). Staging's F1 table is 877 MB for about 9 weeks;
production will add about 1 GB before F1's own compression policy (30 days)
catches up.

Locks: 253 and 254 run `ALTER TABLE … ADD COLUMN` on `metadata.asset_points`
(read by every canonical Energy read since 263) and `config.parameters`
(ACCESS EXCLUSIVE; no `lock_timeout`). The B1 lock watch and guarded cancel
apply unchanged (they identify the runner's psql backend, not a table).

Energy parity: C1 does not replace the canonical read (`667f9cc2…`, 270) and
the Energy path selects logical points by name, so 254's `parameter_id`
remapping cannot change Energy results [V].

Customer-visible changes (production is API-only, D6): Admin Portal "Assign
Data Points" Save goes live (D5); the Analytics catalogue reports power
units as kW / kVA / kvar (289) and keeps closed assignments with their
periods (288; production has only open bridge rows).

Tooling (uncommitted, `scripts/diagnostics/`; local tests in `c1_tests/`):

- `prod_c1_precheck.sql` (31 checks; `105c6c1`'s 164 manifest rows embedded):
  ledger 149 / `a6d33cb0…`; pending exactly the 15 in manifest order; nothing
  C1 creates exists; 288, 290 and 291's preconditions; reference data; P9 (F1
  oldest data at least 2 days from its drop; compressed environment rows
  under 100,000); P10; nine pipeline / Energy jobs (adds 1000, 1001, 1012);
  no long, idle-in-transaction or C1-table lock holders.
- `prod_c1_postcheck.sql` (60 checks): ledger 164 / `0591dde9…`, each of the
  15 with its checksum in manifest order, the 149 unchanged; 15 routine
  definitions, owners and execute privileges; 288's comment, 291's body; the
  two new columns, 7 groups, reference data, inert commissioning backfill
  (0 records, worker unscheduled), F1 table / policies / two scheduled jobs /
  state; bridge; health as B2 plus jobs 1000, 1001, 1012.
- `prod_c1_gate.py`: `prod_b2_gate.py` with C1's keys.
- Tests: 36 mutation cases (18 per script, including running-job cases and
  an SQL error) and 39 gate cases pass.
- sha256 prefixes: precheck `9818e2d5…`, postcheck `aa15f135…`, gate
  `ac2fb7b2…`.

Decisions (2026-10-21): D2 keep the 2026-10-27 F1 target; D5 Assignment Save
goes live with C1; parity = the B2 rule (exact equality, zero tolerance, no
`PARITY_ERROR`; pre1 = pre2 before dispatch, pre2 = post after; 1d/1h/15m and
native).

Production precheck (approved, read-only, run once 2026-10-21 11:45:14 UTC):
**31/31 PASS**, gate exit 0. Ledger 149 `a6d33cb0…`, pending exactly the 15,
F1 oldest data chunk dropped from 2026-11-03, compressed env rows 53,634,
failures 2840, 1053 + 1114–1120 unscheduled, no long/idle transactions or C1
table holders. Disk 11:45 UTC: `/` (holds `/opt/ems-platform/postgres/data`)
98,122 MB, 62,790 used, 35,317 free (65%; 59% on 2026-10-18); database
31,462 MB. F1's ~1 GB fits; the ~6-point rise in 3 days is for the deferred
disk review.

Baseline captures (approved, read-only, 2026-10-21; B2 windows, 56 assets,
300 s / 2 s; guard load / MB available / lock waiters):
`c1_pre1` range 0.22/715/0, 168 calls, 0 errors, 46 s; native 0.83/705/0, 56,
0, 3 s. `c1_pre2` range 0.70/716/0, 168, 0, 46 s; native 1.25/713/0, 56, 0,
5 s. Read function `667f9cc2…` in all four. pre1 vs pre2 (`--criterion full`):
**PASS**, range 168 pairs (56 each of 1d/1h/15m), native 56 pairs, no
duplicates, no `PARITY_ERROR`. After: ledger 149, failures 2840, 1053 +
1114–1120 unscheduled. Next: dispatch, on separate approval.

#### C1 execution record (2026-10-22)

- Dispatch-time precheck 05:10:16 UTC: 31/31 PASS (compressed env rows
  63,657, about +10k/day). Disk 66%, 34,242 MB free.
- Dispatched 05:12:01 UTC, `deploy-production.yml` run `39726655853`
  (staging-milestone, `105c6c1`): success. 15 APPLY (05:13:28–05:13:35) /
  149 SKIP; REQUIRED gates PASS; advisory FAILs identical to B2's. Two benign
  psql transaction WARNINGs from 253's own BEGIN/COMMIT.
- Lock watch 05:10:29–05:25:27: 180 samples (167 IDLE, 13 RUNNING), 0 s lock
  wait, no ABORT_CANDIDATE; guarded cancel not used.
- Postcheck 05:16:18: **60/60 PASS**; ledger 164, digest `0591dde9…`.
- Post captures (guards 1.07/674/0 and 1.19/690/0) and pre2 vs post:
  **PASS**, 168 range + 56 native pairs; read function `667f9cc2…` unchanged.
- F1 (jobs 1135 forward, 1136 reconcile 23:00 UTC, 1133/1134 policies, 1132
  commissioning unscheduled): first run 05:17, then about 2 days per 10 min;
  06:28 checkpoint 2026-08-18 12:00, table 90 MB, 0 failures, failures 2840,
  1053 + 1114–1120 unscheduled, free disk 33,732 MB.

#### C1 acceptance (accepted 2026-10-22 23:37 UTC)

Criteria: section 6 "Evidence of success" (C1 row and "All"), plus F1
backfill completion and the first daily reconcile (job 1136) succeeding.

**Accepted.** Final read-only check 2026-10-22 23:37 UTC [M]
(`ssh ems-production` → `docker exec ems-timescaledb psql`,
`default_transaction_read_only=on`, `BEGIN READ ONLY … ROLLBACK`,
statement_timeout 20–30 s, lock_timeout 2 s; catalog, statistics, state
tables and the ledger only, no hypertable scan):

| Criterion | Evidence | Result |
|---|---|---|
| F1 backfill complete | Checkpoint 23:30 UTC = last closed bucket, lag 0. Caught up between 11:42 and 13:57 UTC (13:57 check: checkpoint 13:45 = last closed bucket), within the 12:30–13:30 UTC estimate | PASS |
| F1 forward job (1135) steady state | 204 runs, 204 successes, 0 failures; one-bucket runs (23:34 UTC: 5.6 s, 960 rows; no-op runs about 0.02 s); 8 runs 22:56–23:37 UTC, none skipped during 1136 | PASS |
| First daily reconcile (1136) | 1 run, Success, 23:00:00 → 23:03:56 UTC (3 min 56 s, limit 20 min); next 2026-10-23 23:00 UTC; 0 job errors | PASS |
| 1136 repairs | 0 rows rewritten or added [E]: F1 chunk counters (`pg_stat_user_tables`) 22:56 → 23:37 UTC show `n_tup_upd` +0 on both chunks in the 3-day window (`_hyper_76_828` Oct 15, `_hyper_76_829` Oct 22) and `n_tup_ins` +2,880 = 3 forward buckets × 960 rows. 1136 records no repair count, so this is inferred from statistics counters, not instrumented | PASS (0 repairs, inferred) |
| Environment routing (291) | 1012 last run SUCCESS 0.69 s at 23:36 UTC | PASS |
| No new job failures | Failure total (excluding 1114) 2840 (all jobs 3021, unchanged all day); 0 jobs failing; 0 job errors in the last 14 h | PASS |
| Ledger | 164 rows, head `291_environment_loader_bounded_update`, digest `0591dde9…` (unchanged) | PASS |
| Host | 0 lock waiters, 0 transactions older than 2 min; disk 69 %, 31 GB free; DB 35 GB; ems-timescaledb healthy, Postgres up since 2026-09-22 04:34 UTC | PASS (disk review deferred) |
| Paused jobs | 1053, 1114–1120, 1123, 1124, 1132 unscheduled (unchanged by C1) | Unchanged |

Intermediate read-only checks the same day: 10:28 UTC (checkpoint
2026-09-27 12:00), 11:39 / 11:42 UTC (2026-10-08 / 10-09 12:00), 13:57 UTC
(caught up), 22:56 UTC (pre-reconcile snapshot; 1136 not yet started).
No job was retried, rescheduled or altered.

Earlier read-only check 2026-10-22 08:26 UTC [M] (superseded by the table
above):

| Criterion | Evidence | Result |
|---|---|---|
| Run, gates, ledger, postcheck | Execution record above; ledger 164 `0591dde9…` re-confirmed 07:18 UTC | PASS |
| F1 forward job advancing | 1135: 34 runs, 0 failures, last 08:22:15 SUCCESS in 49 s, 63,200 rows; `max_catchup_window` 1 day, every 5 min | PASS |
| F1 backfill complete | Checkpoint (`pipeline_state.last_received_at`) **2026-09-07 12:00 UTC**; about 45 days remain, so ETA about 12:30–13:30 UTC today [E]; table 424 MB, 6 chunks, none compressed | **INCOMPLETE** |
| First daily reconcile (1136) | Not yet run; next start 2026-10-22 23:00 UTC | **PENDING** |
| Environment routing (291) | 1012 last run SUCCESS 0.42 s; `environment_measurements` checkpoint 08:23 UTC | PASS |
| No new job failures | Failure total (excluding 1114) 2840; 0 failing; 0 job errors since 05:10 UTC | PASS |
| Host | 0 lock waiters, 0 long transactions; disk 67 %, 33,159 MB free | PASS (disk review deferred) |
| Paused jobs | 1053, 1114–1120, 1123, 1124, 1132 unscheduled (unchanged by C1) | Unchanged |

At 08:26 UTC C1 was not yet accepted; the re-checks above closed both open
criteria. C2′ preparation was waiting on this acceptance and now needs its own
decision. The parity audit and the R0 resolution of
U1–U5 are in
[staging-production-parity-2026-10-22.md](../10-operations/staging-production-parity-2026-10-22.md).

#### C2′ preparation (2026-10-23)

Status: **deployed 2026-10-23** (see "C2′ execution record" below). The
preparation record is kept as written before dispatch. C1 acceptance did not
authorize C2′; the user authorized C2′ separately, conditional on the gates
below. Neither covers Release D or any other production change.

Scope [V]: target `d52b049b8acd2f741868f6ef10286e11767b07d4` (#132,
2026-10-13). `105c6c1` → `d52b049` → `origin/staging` is a forward chain.
The manifest at `d52b049` is `105c6c1`'s 442 rows plus exactly 292, 293,
294, 295, 297, 298, in that order (296 was never in the manifest). Ledger
after: 164 → 170. Each of the six files was added once, never edited, and
is byte-identical at `origin/staging` (sha256 prefixes: 292 `a280f4c5`,
293 `83622a4f`, 294 `dbc6d2da`, 295 `f71ce79b`, 297 `ff575c4c`, 298
`ae9ae743`). `deploy-staging.yml` `38363172078` succeeded for `d52b049`
(all CI gates, both images built and pushed, staging deploy, post-deployment
verification).

Intervening changes `105c6c1..d52b049` (17 first-parent commits, 90 files):

- Database: only the six migrations and their manifest rows.
- Application image: `analytics_api_service.py`, `analytics_trends_service.py`,
  `routers/analytics_api.py` (B3 point series and per-phase Energy on 292/293,
  series summary over completed periods). Production is API-only (D6), so
  these appear as new or changed API responses only.
- Web (`web/`): Analytics F6/F7, CSV formula neutralization, Demand UI,
  responsive navigation. Not deployed to production
  (`deploy-production.yml` never runs `deploy_web_bundle.sh`).
- Workflow: `deploy-production.yml` #110 (45-minute verification timeout)
  and #111 (forward-only check reads the deployed release). Both are already
  on `origin/staging` and were the workflow version used for B2 and C1; the
  file is identical at `d52b049` and `origin/staging`.
- `scripts/release/deploy_release.sh`, `scripts/apply_migrations.sh`,
  `compose.yaml`, Grafana and Telegraf configuration: unchanged.
- Tests and docs only otherwise.

The image `ghcr.io/<repo>-app:d52b049…` was pushed by `38363172078`; it was
not re-listed (no `read:packages` scope locally). The workflow's
`resolve-image` step resolves and pins its digest before any SSH, so a
missing image fails the run before production is touched.

Production precheck [M 2026-10-23 05:03 UTC, read-only transaction,
statement_timeout 20 s, lock_timeout 2 s; catalog, job catalog and small
metadata tables only]:

| Check | Evidence | Result |
|---|---|---|
| Ledger | 164 rows, head 291, digest `0591dde9…`; 0 rows for 292–298 | PASS |
| 292 / 293 preconditions | Source tiers and tenancy / capture helpers present; none of the 292 functions exists | PASS |
| 294 / 295 preconditions | `admin.save_asset_point_assignments` and required tables present; no 294 / 295 function exists | PASS |
| 294 / 295 inert on production | 0 `onboarding_audit` rows at the 294 anchor (2026-10-09 12:56:55.116554 IST); 0 `asset_points` rows at the 295 anchor (2026-09-25 21:06:21.442284 IST). The production parity bridge rows have a different `created_at` | PASS (never call these functions on production) |
| 297 preconditions (P6) | Body md5 `9084fb8b…`, `7ba7388b…`, `35ff7b9c…` = expected | PASS |
| 297 targets | Reconcile jobs 1116 (15-min), 1118 (daily), 1120 (environment daily) are **unscheduled** (last runs Oct 16–17, 0 failures); 297 changes their bodies only, so there is no runtime effect until they are resumed | Note |
| 298 / P7 | Exactly one demand job: **1062**, every 1 minute, `fixed_schedule` true, `initial_start` 2026-08-10 11:20:03.058347 UTC, max_runtime 10 min, 3 retries / 5 min, config unchanged since D4a; last run Success 0.59 s; 104,222 runs, 1 failure (historical) | PASS |
| 298 grace | 7 enabled demand policies; grace 5 min 30 s ≤ the 7-minute phase, so no WARNING | PASS |
| Health | Failure total (excluding 1114) 2840; 0 jobs failing; 0 job errors in 24 h; 0 lock waiters, 0 long transactions; unscheduled 1053, 1114–1120, 1123, 1124, 1132; disk 69 %, 31 GB free; DB 34 GB; TimescaleDB 2.28.2 | PASS |

Rollback readiness:

- **Database backup: none established [M].** No `emsadmin` crontab, no backup
  entries in `/etc/cron.d` or systemd timers, no backup directories on the
  host. Host or EBS snapshots, if any, are outside this repository and were
  not checked (no AWS access). A, B1, B2 and C1 were deployed under the same
  posture ([backups-and-recovery.md](../10-operations/backups-and-recovery.md)).
  **Decided 2026-10-23 (user):** proceed without a snapshot; the
  forward-only recovery risk is explicitly accepted for C2′.
- Image: `rollback.yml` can redeploy `105c6c1`. **It reverses no migration**
  (section 7): the six migrations, their functions and 298's schedule stay
  in place after an image rollback. The `105c6c1` app does not call the 292
  functions, so it runs unchanged on top of them.
- Every database reversal below is a production change with its own
  approval, shipped as a new forward migration (revert PR):
  - 292: `DROP FUNCTION analytics.get_portal_asset_point_series(bigint, uuid,
    uuid[], text[], text[], timestamptz, timestamptz, text, timestamptz)`,
    `analytics.get_portal_analytics_point_availability(bigint, uuid, text[],
    text[])`, `analytics.get_analytics_point_resolution_floors(timestamptz)`
    and the helper `analytics.analytics_point_source_scale` (nothing in the
    database depends on them; the d52b049 app's B3 endpoints do, so roll the
    image back first).
  - 293: replaces 292's series function only; reversed by 292's drop.
  - 294: `DROP FUNCTION` `admin.restore_bulk_assignment_history_20261009`,
    `admin.restore_bulk_assignment_history_core`,
    `admin.bulk_assignment_restore_plan`, `admin.bulk_restore_first_reading`
    (wrapper first). 295 calls `bulk_restore_first_reading`, so reverse 295
    first.
  - 295: `DROP FUNCTION` `admin.narrow_standin_energy_assignments_20260925`,
    `admin.revert_standin_energy_narrowing`,
    `admin.narrow_standin_energy_assignments_core`,
    `admin.standin_energy_narrow_plan`.
  - None of 292–295 changes data; their functions are never called on
    production, so dropping them loses nothing.
- 297: `docs/10-operations/prepared/T1.1/297_rollback.sql`, **committed
  `cd11e47`** (sha256 `4cf93c85…`). It restores the exact migration-213
  bodies (precondition: the 297 bodies `c0426e6b…` / `8789f6ea…` /
  `e71b2511…`; postcondition: `9084fb8b…` / `7ba7388b…` / `35ff7b9c…`, which
  are production's current bodies) plus owner `ems_admin`, SECURITY DEFINER,
  search_path and grants; no data or ledger change. Validated 2026-10-11 in
  a rolled-back transaction on the local test DB, and re-checked 2026-10-23
  by recomputing every restored body's md5. Its target jobs 1116 / 1118 /
  1120 are unscheduled, so 297 has no runtime effect either way.
- 298: `alter_job(1062, schedule_interval => INTERVAL '1 minute',
  fixed_schedule => true, initial_start => '2026-08-10 11:20:03.058347+00')`
  (the recorded pre-298 values; 298 changes nothing else, by its
  postcondition). Re-check the job ID by `proc_name` first.

Approvals (dispatch authorized by the user 2026-10-23, conditional on every
gate below passing):

1. Backup decision: forward-only posture accepted (above).
2. Read-only P6 / P7 re-run immediately before dispatch (this precheck,
   repeated) and the B1-style lock watch.
3. Dispatch of `deploy-production.yml`, `promotion_mode=staging-milestone`,
   `release_git_sha=d52b049b8acd2f741868f6ef10286e11767b07d4`, at a named
   time that avoids the 23:00 UTC 1136 reconcile and the 05:13 / 17:13 UTC
   F1 policy runs.
4. Postcheck: ledger 170 (292–298 APPLY, 164 SKIP), 1062 at :07/:22/:37/:52
   UTC, demand intervals finalized with the same VALID share, 0 new failures.

Release D (299–303) stays separate, with its own scope decision and G3b.

#### C2′ execution record (2026-10-23)

Preparation commits on `docs/prod-release-plan-266-301` (pushed before
dispatch; PR #137 itself was already squash-merged on 2026-10-21 as
`8490e48`, so these commits are not yet on `staging`): `8c1c06a` (C1 record,
parity audit), `cd11e47` (297 rollback script), `b55d41b` (C2′ preparation).

Final gate [M 2026-10-23 05:21 UTC, read-only, statement_timeout 20 s,
lock_timeout 2 s]: ledger 164 `0591dde9…`, 0 rows for 292–298; 292–295
preconditions PASS; 294 / 295 anchors 0 / 0; 297 body md5s
`9084fb8b…` / `7ba7388b…` / `35ff7b9c…` with owner `ems_admin`, SECURITY
DEFINER, ACL `{ems_admin=X/ems_admin}`; 1116 / 1118 / 1120 unscheduled; 1062
equal to the recorded rollback values (1 minute, fixed, initial_start
2026-08-10 11:20:03.058347 UTC); grace 5 min 30 s; failures (excl. 1114)
2840, 0 failing, 0 job errors in 24 h, 0 lock waiters, 0 long transactions;
disk 69 % (31 GB free), load 0.51; running image `105c6c1`. Staging success
run for `d52b049`: `38363172078`, which pushed
`ems-platform-app:d52b049…@sha256:964d5002…`. Rollback script on the remote
branch, sha256 `4cf93c85…`. Window: after the 05:13 UTC policy runs, well
before 17:13 and 23:00 UTC.

| Step | Evidence | Result |
|---|---|---|
| Dispatch | 05:22:06 UTC, `deploy-production.yml --ref staging`, `promotion_mode=staging-milestone`, `release_git_sha=d52b049b8acd2f741868f6ef10286e11767b07d4`; run **39905366140** | success |
| Validate (05:22:12–05:22:33) | Forward-only check passed (last promoted `105c6c1`); image verified in GHCR; resolved `…@sha256:964d5002c71e…` = the staging-proven digest | PASS |
| Deploy (05:22:36–05:23:49) | Digest re-resolved and pinned (same `964d5002…`); **6 APPLY / 164 SKIP**: 292 05:23:33.3, 293 .7, 294 05:23:34.1, 295 .5, 297 .9, 298 05:23:35.3 (26–58 ms each) | PASS |
| Lock watch | 108 samples 05:21:59–05:30:54 (5 s, read-only): 96 IDLE, 12 RUNNING, max lock wait 0 s, 0 queued, never `WAITING` / `LONG_WAIT` / `ABORT_CANDIDATE`. The migrations ran between samples (about 2 s in all); the RUNNING samples (05:24:14–05:25:09) were the verification job's sessions. Guarded cancel not used | PASS |
| Post-deployment verification (05:23:51–05:25:24) | REQUIRED: database structure PASS, metadata integrity PASS, energy routing metric identity PASS. ADVISORY (non-blocking): telemetry pipeline FAIL (1 stage not SUCCESS = `derived_space_dew_point_1min` NEVER_RUN, pre-existing; 4 stages older than 10 min, which are stages on 15-minute or longer cadences), job verification FAIL (alert job not registered, 1 policy disabled, routing max_runtime WARNs): same findings as C1 | PASS (advisories pre-existing) |

Postcheck [M 05:32 UTC, read-only]:

| Check | Evidence | Result |
|---|---|---|
| Ledger | 170 rows, head 298, digest `543b536b…`; the six rows present once, checksums = file sha256 (`a280f4c5…`, `83622a4f…`, `dbc6d2da…`, `f71ce79b…`, `ff575c4c…`, `ae9ae743…`), applied by `ems_admin`; 0 unexpected rows; the 164 prior rows byte-identical before and after (id, checksum, applied_at) | PASS |
| 292 / 293 | 4 functions; the three portal reads SECURITY DEFINER, STABLE, `ems_admin`, EXECUTE `ems_admin` + `ems_app` only; helper `analytics_point_source_scale` owner-only | PASS |
| 294 / 295 | 8 functions, `ems_admin`-owned, not granted; 0 restore / narrowing audit records (not executed) | PASS (inert) |
| 297 | Bodies `c0426e6b…` / `8789f6ea…` / `e71b2511…` (= the 297 postcondition); owner, SECURITY DEFINER, ACL and search_path unchanged; 1116 / 1118 / 1120 still unscheduled | PASS |
| 298 | 1062 every 15 min, `fixed_schedule`, `initial_start` 2026-10-23 05:37:00 UTC (minute 37 → :07/:22/:37/:52); max_runtime 10 min, 3 retries / 5 min, config and check function unchanged; last run 05:23:03 Success (the final 1-minute run); next 05:37:00 | PASS |
| App | `ems-admin-portal` and `ems-live-telemetry` on `ems-platform-app:d52b049…`, both healthy; database container healthy, Postgres up since 2026-09-22 | PASS |
| Health | Failures (excl. 1114) 2840; 0 failing; 0 job errors since dispatch; 0 lock waiters, 0 long transactions, 0 leftover lock-watch backends; unscheduled set unchanged; disk 69 %, 31 GB free; load 0.57 | PASS |

C2′ acceptance criteria: the first quarter-hour demand runs (05:37 UTC
onward) finalize intervals with the same VALID share as before, and no new
failures over the following day. No job was retried, rescheduled or altered
apart from 298's own change; no frontend was deployed. Recorded as accepted
on 2026-10-25 ("C2′ acceptance" below).

Interim acceptance check [M 06:41 and 06:53 UTC, read-only; not an
acceptance record]:

| Check | Evidence | Result |
|---|---|---|
| 1062 cadence | Runs 05:37, 05:52, 06:07, 06:22, 06:37, 06:52 all Success (4.6–5.9 s); next 07:07; total_failures 1 (unchanged); 0 job errors since dispatch | PASS |
| Finalization | One batch of 56 rows per run, each finalizing the bucket that closed 7 min earlier (05:15 at 05:37 … 06:30 at 06:52); before the deploy the same buckets were finalized at +6 min by the 1-minute runs; checkpoint 06:45 SUCCESS; no missing buckets | PASS |
| VALID share | 24 h before 05:15: 5376 rows / 96 buckets, 86.83 % VALID (702 NO_DATA, 6 INCOMPLETE). Buckets 05:15–06:00 and 06:30: 48 VALID / 56, identical by site to before. Bucket 06:15: 32 VALID, because all 22 `Unit 2` asset rows were INCOMPLETE (12 of 15 observations, 73.33 %); the 06:52 run re-evaluated it within the 30-minute overlap and it stayed INCOMPLETE, so the 3 minutes are absent from the source, not late. At 06:30 `Unit 2` returned 22 VALID, including its 6 usually NO_DATA assets | Not attributable to C2′ (source gap at one site); share still under observation |
| Health | Failures (excl. 1114) 2840; 0 lock waiters, 0 long transactions; unscheduled set unchanged; ledger 170 / `543b536b…`; app containers healthy; disk 69 % | PASS |

#### C2′ acceptance (accepted 2026-10-25)

Criteria: section 6 "Evidence of success" (C2′ row and "All"), over the
24 hours after the first quarter-hour demand run: 2026-10-23 05:37 UTC →
2026-10-24 05:37 UTC.

**Accepted** (recorded at the user's instruction on 2026-10-25, from the
evidence below). This acceptance covers C2′ only. **Release D's 24-hour
acceptance is separate and is not decided here** ("Release D execution
record").

Read-only checks 2026-10-25 07:22–07:40 UTC [M] (`ssh ems-production` →
`docker exec ems-timescaledb psql`, `default_transaction_read_only=on`,
`BEGIN TRANSACTION READ ONLY … ROLLBACK`, statement_timeout 30 s,
lock_timeout 2 s; job catalog and statistics, the ledger,
`analytics.demand_intervals` and `telemetry.raw_messages` bounded to the
window):

| Criterion | Evidence | Result |
|---|---|---|
| Run, gates | Run 39905366140 success; REQUIRED gates (database structure, metadata integrity, energy routing metric identity) PASS; the advisory FAILs are the pre-existing C1 findings ("C2′ execution record") | PASS |
| Ledger | Postcheck 05:32 UTC: 170 rows, the six C2′ rows once each, checksums = staging. Re-checked 2026-10-25: the six rows still `applied`, `checksum_sha256` = sha256 of the repository files (292–308 compared at `7e3da57`: 16 / 16 identical) | PASS |
| No new job failures | 0 rows in `timescaledb_information.job_errors` between 2026-10-23 05:22 and 2026-10-24 05:37 UTC. The 12:59 UTC Release D gate saw failures (excl. 1114) 2840, 0 failing. The first new failure after C2′ is job 1061 at 2026-10-24 07:58 UTC, after this window (see below) | PASS |
| 1062 schedule | Every 15 min, `fixed_schedule` true, `initial_start` 2026-10-23 05:37:00 UTC → :07/:22/:37/:52; max_runtime 10 min. `total_failures` 1 (historical, unchanged since before C2′); 167 runs against 166 expected since 2026-10-23 13:49:54 UTC | PASS |
| Finalization | 0 missing quarter-hour buckets 2026-10-23 05:15 → 2026-10-24 05:15 UTC (97 buckets × 56 rows). Finalized at interval end + 7:05–7:16 (p50 425 s / p99 435 s, C2′-only part) and + 7:03–7:06 (C2′ + D part); before C2′, + 6:05–6:09 with the 1-minute runs. The extra minute is 298's :07 slot, as designed | PASS |
| VALID share | Steady state is 96.43 % (54 / 56 per bucket). The two rows missing in every bucket are the single assets of `SVSS Nivas` and `Vivekanandanagar Home`, whose gateways send no raw messages (NO_DATA in all 97 buckets of the window). Same share before and after: 96.43 % on 2026-10-19 and 2026-10-21 (whole days, before C2′) and on 2026-10-24 and 2026-10-25 (after). Window: 05:15–12:45 UTC 91.07 % (1,680 rows); 12:45 UTC → 05:30 UTC 96.38 % (3,752 rows). The 24 h immediately before C2′ (86.83 %) is not a usable baseline: it falls inside the `Unit 2` gateway outage (2026-10-22 07:48 → 2026-10-23 about 06:00 UTC) | PASS |
| Non-VALID rows in the window | All explained by missing source data, none by C2′: `Unit 2` NO_DATA 24 rows (4 buckets 05:15–06:00, end of the outage); `Unit 2` INCOMPLETE 66 rows = 22 assets × buckets 06:15, 11:45 and 12:00, each matching minutes with **no `Unit 2` raw messages at all** (06:15–06:17, 11:58–11:59, 12:00), while the neighbouring buckets 11:30 and 12:15 have raw data in every minute; `Coimbatore` INCOMPLETE 2 rows (13:30) | PASS (source gaps) |
| Host and app | 2026-10-25: checkout `7e3da57`; `ems-admin-portal` / `ems-live-telemetry` healthy, `/health` 200; database container healthy; disk 64 %, 36 GB free | PASS |

**Overlap with Release D.** Release D was deployed at 13:00 UTC on
2026-10-23, 7.5 hours into this window. From then on, C2′ is observed
together with D's five-minute pipeline schedule (migration 300). C2′'s
criteria are specific to job 1062 and the demand VALID share, and both still
hold under D (above). A failure that started after D could not be attributed
to C2′ alone, but none occurred inside the window.

**Not part of C2′; open under Release D.** On 2026-10-25 the failure total
(excl. 1114) is **2847**, 7 more than the 2840 baseline. All 7 hit a job's
`max_runtime` after this window:

- job 1061 (`run_failed_message_recovery_job`): 3 runs of exactly 10 min on
  2026-10-24 07:58, 08:23 and 08:58 UTC; now unscheduled (audited pause),
  last status Failed. PR #152 traces this to the recovery body that
  migration 305 installed (Release D); the fix (migration 311) is not merged.
- job 1060 (`run_raw_receipt_state_job`): 4 runs of exactly 1 min on
  2026-10-24 12:47, 12:49, 12:50 and 14:18 UTC; it has run successfully since.
  No cause recorded.

These count against Release D's criterion "failures still 2840 and no job
errors", not against C2′.

#### Release D execution record (2026-10-23)

Scope approved by the user on 2026-10-23: all ten pending migrations
299–308 from staging tip `7e3da57` (PR #144 squash, which added 307 / 308),
default `staging-head` mode. Release-plan branch pushed before dispatch at
`44a30b6` (G3b amendment, prepared post-deploy scripts). Backup taken first:
`/opt/ems-platform/postgres/backups/prod_snapshot_20261023T0814Z.dump`
(7,178,004,332 bytes, sha256 `46978832…`, `pg_restore --list` 6,955 entries;
not test-restored), kept in place.

Final gate [M 2026-10-23 12:59 UTC, read-only, statement_timeout 30 s,
lock_timeout 2 s]: `origin/staging` = `7e3da5762ca6…`; ledger 170, head 298,
digest `543b536b…` (= staging's first 170 rows), 0 rows ≥ 299; staging
checksums for 299–308 = repository (`d91ec61f`, `849bd7fb`, `3568c0a8`,
`644f278a`, `535b2dcf`, `f4e83b40`, `7776509c`, `fd558234`, `3abc40a7`,
`9340d524`); every precondition of 299–308 true (those of 300 / 305 / 306
that depend on earlier members of the set are supplied by them); views
already the 307 body; PUBLIC EXECUTE on the six 308 routines; failures
(excl. 1114) 2840, 0 failing, 0 job errors since 05:20; 1062 every 15 min
fixed at :07/:22/:37/:52; unscheduled set unchanged (1053, 1114–1120, 1123,
1124, 1132); 0 lock waiters, 0 long transactions, no compression /
retention due within 90 min; routing lag 127 s; disk 34 GB free (65 %);
containers healthy.

| Step | Evidence | Result |
|---|---|---|
| Dispatch | 12:59:21 UTC, `deploy-production.yml --ref staging`, `promotion_mode=staging-head`, `release_git_sha` = `confirm_release_git_sha` = `7e3da5762ca6b69b1258f6264999ae546f7dc6a2`; run **39957525916** | success |
| Validate (12:59:25–12:59:30) | `release_git_sha` = staging HEAD; image `ems-platform-app:7e3da57…@sha256:85fdfb5c…` (the staging-proven artifact of run 39922794254) | PASS |
| Deploy (12:59:33–13:01:14) | Staging HEAD re-verified; **10 APPLY / 170 SKIP**: 299 13:00:47.49 … 308 13:00:52.34 (20–155 ms each). 300 printed its expected WARNING (capture policy 5: 300 + 30 s, accepted as D8) and six NOTICEs with the previous 1-minute settings of 1000 / 1001 / 1012 / 1044 / 1063 / 1083 | PASS |
| Post-deployment verification (13:01:17–13:02:45) | REQUIRED: database structure 24 / 24, metadata integrity 27 / 27, energy routing metric identity PASS. ADVISORY (non-blocking) FAIL with the same findings as C2′: alert job not registered, 1 policy disabled (1053), routing max_runtime WARN ×2, 1 pipeline stage not SUCCESS; the job check now passes "runs every 5 minutes" for normalization and both routing jobs | PASS (advisories pre-existing) |

Postcheck [M 13:04 and 13:16 UTC, read-only]:

| Check | Evidence | Result |
|---|---|---|
| Ledger | 180 rows, head 308; the 170 prior rows unchanged (digest `543b536b…`); 299–308 once each, `applied`, checksums as above | PASS |
| App | Checkout `7e3da57`; `ems-admin-portal` and `ems-live-telemetry` on `…@sha256:85fdfb5c…`, healthy; `/health` 200; 0 error lines in the app log since dispatch | PASS |
| 299 / 302 | DEFAULT policy `normalized_receiving_threshold_seconds` 600; `energy_stale_pipeline_allowance(60)` 00:08:20 → Analytics stale threshold 10:20 (phased path, as on staging) | PASS |
| 303 / 305 / 306 | Late-sweep job 1137 hourly at hh:31:30 (first run 14:31:30 UTC by design); demand reconciler 1119 config now `wide_every` 6 h / `wide_window` 58 h with `config.assert_demand_reconciliation_job_config`, **still unscheduled** (Oct-17 pause, not resumed) | PASS |
| 307 / 308 | View md5s `2c75df88…` / `8a6d00ca…`, `security_barrier=true` (no change, production already had them); PUBLIC EXECUTE 0 / 6, `ems_admin` 6 / 6 | PASS |
| Health | Failures (excl. 1114) 2840, 0 failing, 0 job errors since 12:59; 102 jobs, 91 scheduled (+1137); unscheduled set unchanged; 0 lock waiters; disk 34 GB free; demand 13:07 run on slot, latest interval 54 / 56 VALID (as before) | PASS |

**Schedule decision (user, 2026-10-23): keep the six migration-300 jobs on
five-minute schedules.** The prepared switch-back
(`post_deploy_restore_1min_schedules.sql`) was **not run**. This supersedes
D9's post-deploy restore: D9's restore existed because production routing
was too slow for its 30 s slot on 2026-10-16 (§10.17 of the operations plan:
p50 546 s, routing read 30 s timeouts); that cause is gone (migrations 267
and 303; P12 25 / 33 ms; 93 h of 1-minute routing runs, all under a minute).
Five minutes is what migration 300, `scripts/verify/verify_jobs.sh`
(`f6efc1f`, PR #134) and staging (2,611 / 2,611 slots per job since
2026-10-14, 0 job errors) all expect. Restoring 1 minute would have left
three advisory FAILs on every later production deploy.

First five-minute cycles on production [M 13:02–13:50 UTC]: normalization
1.7–5.3 s per batch (estimate on 2026-10-16 was 32–103 s against a 90 s
budget), energy routing 0.31–0.74 s, environment routing 0.14–0.16 s,
`ca_energy_1min` / phase-power refreshes 0.05–0.57 s, 1-minute tier
0.49–0.54 s; every slot ran; lag normalized 232–301 s, routing 327–395 s,
1-minute tier 329–397 s (staging 15-minute limits 330 / 450 / 540 s); demand
on slot.

**24-hour acceptance: pending.** Read-only script
`docs/10-operations/prepared/release-d/post300_24h_acceptance.sql`, baseline
2026-10-23 13:49:54 UTC (dry-run clean, 3.8 s), due at or after 2026-10-24
13:50 UTC. Criteria (staging §10.13–10.14): +288 ± 1 runs per job, demand
+96 ± 1; failures still 2840 and no job errors; demand finalization p99 ≤
end + 8 min, max ≤ + 23 min; lag ≤ 330 / 450 / 540 s; 1-minute tier
publication delay 4–8 min; non-VALID demand rows explained by gateways with
no raw messages; no 5-minute energy window missing devices outside such
gaps. Not measured by it: worst-case / percentile run durations (no
per-run history; `enable_job_execution_logging` off).

Remaining staging / production differences [M 2026-10-23 ~13:55 UTC, every
job compared by procedure name, read-only]:

| Difference | Production | Staging / repository | Status |
|---|---|---|---|
| Routing `max_runtime` (1001, 1012) | 30 min | 5 min (migration 194) | D7, below; not changed |
| Oct-17 pauses | 1053 (raw_messages compression), 1114–1120 reconcilers unscheduled | scheduled | Intentional (D1 baseline 2840); resuming needs its own approval |
| Dew-point forward job (1123) | unscheduled | scheduled (enabled out-of-band on staging; the repository registers it unscheduled) | Staging drift |
| Alert evaluation job | not registered | registered (manual step `postgres/jobs/238_alert_evaluation_job.sql`) | Intentional; the job check reports an advisory FAIL |
| `run_raw_message_failure_capture_job` config | no `max_window` | `max_window` 60 min | Staging hand-tuning (parity audit) |
| `run_failed_message_recovery_job` limit | 100 | 1000 | Staging hand-tuning (parity audit) |
| Phases of the 15-minute / hourly / daily tier jobs | registration-time offsets differ (e.g. 15-minute tier at +1:41 vs +2:28 in each 5 minutes) | — | Benign: both run after the 1-minute tier's +5:00 |

**D7 (routing max_runtime 30 → 5 min): recommended, separately approved.**
The 30-minute value was set by hand after migration 194 (applied
2026-08-25) and before 2026-10-08, when production routing runs took
466–592 s and a 5-minute limit would have killed every run. Today, on a
fixed 5-minute grid, a run longer than 5 min skips the next slots anyway, so
30 min only lets a stuck run (lock wait, IO stall) hold its advisory lock
and delay routing, demand and every 1-minute tier for up to 30 min before it
is killed; 5 min caps that at one slot. A killed run is retried after 1 min
and its work is redone by the next run (checkpointed, idempotent). The risk
of 5 min: a run that genuinely needs longer (catch-up after an outage; each
run is bounded by `max_window` 2 h) would be killed repeatedly, and after
`max_retries` 3 consecutive failures TimescaleDB stops retrying until the
next scheduled slot. Evidence: steady-state routing 0.3–0.7 s per 5-minute
batch [M]; a 2-hour catch-up window is ~24 batches, ≈ 10–20 s at today's
rate [E], not measured on production since 303. Recommendation: after the
24-hour acceptance passes, align to 5 minutes through a small forward
migration (a no-op on staging, which already has 5 min), not a manual
`alter_job`, so the change is version-controlled and the advisory WARNs
clear.

#### B1 approvals required (given 2026-10-19, see execution record)

1. The read-only production steps 1, 2, 4 and 6: precheck, three parity
   captures (56 canonical-read calls each), lock watch, postcheck.
2. The dispatch of `546a718…` at a named time (step 3).
3. The guarded cancel under the abort rule (step 5), at most once.
   `pg_terminate_backend` is not covered.

**B1 risks as assessed before dispatch** (outcome 2026-10-19: the
workflow verified the image; lock wait 0 s; D3 decided and PASS; 269
timing measured in the execution record and the read-path diagnosis).

- 269 replaces `get_canonical_energy_read` and 10 Energy views. On staging
  this exact body served for only about 2.5 hours (Sep 25, before 263
  replaced the function); the local test database does not show plan
  regressions. The b1_pre2 / b1_post timing lines measure it on production
  for the daily resolution only.
- Image existence is not re-verified today (the workflow checks it).
- The production lock-hold time is estimated (staging 1.1 s / 0.6 s; earlier
  production migrations ran 1.1–20 times slower).
- D3 is proposed (exact equality, `--criterion full --expect-assets 56`) but
  not decided.

## 3. Migration readiness

Every migration below is applied and verified on staging [V].

| Migration | Change | Production dependency or risk | Status |
|---|---|---|---|
| 266 | Activates the four `point_telemetry_1h` jobs (forward every 15 min, reconcile 22:30 UTC, compression, retention) | **G1.** The forward job's first run looks back only 2 days, so the 1h backfill must reach (activation − 2 days) first. That first run refreshes about 50 hours in one call under a 10-minute `max_runtime`, and compression of chunks older than 30 days starts right after activation: both are IO-heavy (section 4) | **Blocked** |
| 267 | Routing loaders bound `window_end` to `event_time ≥ now() − 1 day` | Asserts the loader bodies and `compress_after = 1 day` | Ready, precheck P4 |
| 268 | Reconstruction columns and NOT VALID checks on compressed `analytics.energy_consumption_1min/5min`; `config.energy_reconstruction_scope` (disabled) | **ACCESS EXCLUSIVE lock on every chunk. No pending migration sets `lock_timeout`** [V] | Ready, dispatch window (B) |
| 269 | Measured-vs-reconstructed views and refresh functions; switch stays OFF | Output unchanged | Ready |
| 263 | `analytics.get_canonical_energy_read` (used by Grafana) moves from PRIMARY_METER to `asset_points` | Needs the 112-row production parity bridge [P] and 269 | Ready, **G2** |
| 270 | Selective device reads for 263 | Must ship with 263 | Ready |
| 279, 275–278, 280 | Analytics v1 reads. 275 blocks site timezone edits once a site has telemetry | 280 drops 278's function; the app changes in the same milestone | Ready |
| 281 | Fixes 279's 15m checkpoint boundary | Must ship with 280 | Ready |
| 282–286 | Analytics fixes and read performance. 282 replaces a 6-argument function with a 7-argument one | App changes in the same milestone | Ready |
| 253–262 | Asset point assignment: Save path, commissioning backfill (job registered, **left unscheduled**), unit categories | Must ship with 287 | Ready with 287 |
| 287 | Save commissions DRAFT assets only; removes defective PENDING records | Raises if more than 2 defective records. The table is new on production | Ready |
| 288, 289 | Catalogue assignment periods; power units W→kW, VA→kVA, VAR→kvar (metadata) | None | Ready |
| 290 | F1 register-delta 15m tier. Its forward job backfills history oldest-first, 1 day per run | **Deadline.** Production IO cost unknown (staging: 4.2 s average per run) | Ready, deadline |
| 291 | Environment loader UPDATE bounded to correctable buckets ([pipeline.md](../06-platform/telemetry/pipeline.md)) | **Deadline.** The production loader fails once compressed rows exceed 100,000 | Ready, deadline |
| 292, 293 | B3 point series and plan fixes | Must ship together (292 alone timed out on staging) | Ready |
| 294, 295 | Staging-only one-time history restores | No-op on production: 0 rows at both anchors [P]. **Never call these functions on production**: they hard-code staging UUIDs | Ready (inert) |
| 297 | Reconcile windows aligned to the tier grain | md5 preconditions on the migration-213 bodies | Ready, precheck P6 |
| 298 | Demand job every 15 min at :07/:22/:37/:52 UTC | Needs exactly one demand job (production job 1062 [M]); staging 24 h acceptance passed 2026-10-14. Safe without 300: demand finalizes only up to the newest routed `energy_measurements` bucket (migration 210 watermark), so routing lag delays intervals but does not make them incomplete [V] | Ready (C2′), precheck P7, decision D4a |
| 299 | `normalized_receiving_threshold_seconds` = 600 | Changes customer-visible freshness; prerequisite of 300 | **Not ready (D)**, decision D4b |
| 300 | Six ingest jobs to fixed 5-minute batches | Raises unless all six run every minute, 298 is in place and 299's threshold is ≥ 480. **Staging 24 h acceptance PASSED 2026-10-15** (6 targets, 0 failures, demand p99 end + 7:06.8). **Production NOT READY 2026-10-16** (G3b). Capture policy 5 makes it raise a WARNING (D8) | **Blocked (G3b)** |
| 301 | Deadlock fix: `device_telemetry_state` upserts ordered by `device_id` | md5 pins on the two loader bodies (identical on staging and production [P]). Only production can show the effect: no new 40P01. Held behind 300 by manifest order | Ready, **held (D)** |
| 302 | Schedule-aware Analytics stale flag (threshold 10 min 20 s under 300's phases; the migration-282 sum otherwise) | Needs 300 to change anything; on staging since 2026-10-16 (validated). With production routing lag it would flag persistently if 300 were active [E] | **Blocked (G3b)** |
| 303 | Routing loaders: forward read bounded to uncompressed `normalized_points` chunks, plus an hourly late-data sweep (PR pending, not merged) | Removes the full compressed-chunk scan that every routing run does today. Must be validated on staging first | **Not ready (D)** |

Reverse steps are described in the headers of 298, 299 and 300 (and other
migration headers); none is a tested script. **300's header and NOTICEs
name staging job IDs.** Production job IDs [M 2026-10-16] are:

| Role | Production job | 300 target |
|---|---|---|
| Normalization (`telemetry.run_normalization_job`) | 1000 | yes |
| Energy routing (`telemetry.run_energy_routing_job`) | 1001 | yes |
| Environment routing (`telemetry.run_environment_routing_job`) | 1012 | yes |
| `ca_energy_1min` refresh | 1044 | yes |
| `ca_energy_phase_power_1min` refresh | 1083 | yes |
| Consumption 1-minute (`analytics.run_energy_consumption_1min_job`) | 1063 | yes |
| Demand (`analytics.run_demand_calculation_job`, 298) | 1062 | — |
| Raw receipt state (301's other loader) | 1060 | — |

Re-check them with a read-only lookup by `proc_name` / `hypertable_name`
immediately before any rollback; never copy IDs from a migration header. 297's header points to
`docs/10-operations/prepared/T1.1/297_rollback.sql`, which is **not
committed** to `staging` [V] (it exists only as uncommitted local work).

## 4. Gates

### G1: 1h backfill frontier (blocks Release A and therefore everything) — MET 2026-10-17

[M] Met: Release A's first forward run (2026-10-17 12:07 UTC) refreshed
[Oct 15 10:00, Oct 17 12:00) UTC, overlapping the backfill frontier, so no
top-up was needed and no 1h hour is missing. D1 was decided as option (a)
with baseline 2840. The points below are the pre-deploy record.

- [P 2026-10-17 11:48 UTC] Production `analytics.point_telemetry_1h` is
  filled without gaps from 2026-09-04 00:00 to 2026-10-15 10:00 UTC (995
  hourly checkpoints, validated per hour; 28 outage hours Sep 20-22 hold
  0 rows). That is as far as the runner's 48-hour rule allows. No runner
  or STOP is active.
- [V] Gap left by the first forward run (window [H − 50 h, H) for UTC hour
  H): none if it starts by 2026-10-17 13:52 UTC; otherwise
  [2026-10-15 11:00, H − 50 h). A top-up launched at closed-15m hour Hc
  reaches Hc − 48 h, so the first forward run must start no later than
  Hc + 2 h (its :52 slot). Prefer a :07 slot: all three retries then stay in
  the same hour.
- The backfill runner is an operator tool installed on the production host,
  outside this repository. It calls `analytics.backfill_point_telemetry_1h`
  hour by hour and stops on health gates.
- [P] One of those gates is a job-failure baseline: the sum of
  `timescaledb_information.job_stats.total_failures` for every job except
  1114. The runner records the current value at launch and stops the run if
  it rises. The last accepted baseline was 2832 (2026-10-13). Production is
  now at **2834** after two 40P01 deadlocks on 2026-10-14 (job 1060 at
  04:57 IST, job 1000 at 05:22 IST), with no backfill running. This plan does
  not change the baseline; the policy below needs a decision (D1).
- [P] These deadlocks are the lock-order race that migration 301 fixes.
  About eight were seen in the week to 2026-10-14. Until Release D they will
  keep raising the count, so a fixed baseline blocks every future run, and
  any run lasting several hours has a real chance of being stopped by one [E].

**Proposed baseline policy (not approved).**

1. Before each launch, run R4 from the fact refresh (section 5). Accept the
   current count as the new baseline only if every job error since the last
   accepted baseline is SQLSTATE 40P01 in job 1000 (`run_normalization_job`)
   or job 1060 (`run_raw_receipt_state_job`), and no job's last run failed
   (`failed_non1114 = 0`). Record the accepted value and time.
2. Any other job, any other SQLSTATE, or a job still in a failed state: do
   not launch; report.
3. During a run the runner's gate stays strict: any increase stops the run.
   Archiving the STOP file and resuming still need approval each time.
4. The exception ends at Release D (301). After 301, any 40P01 is a
   regression to investigate, not a known cause.

**Timing rule for the activation frontier [V from migration 265 code].**

- The forward job's first run (checkpoint NULL) starts at `now − 2 days` on
  the hour and also re-derives a 2-hour overlap before it.
- [P] The runner refuses windows ending within 48 hours of the latest closed
  15m hour.
- So the final top-up must finish no more than about 1.5 hours before the
  first forward run, which is the next :07/:22/:37/:52 UTC slot after the
  deploy. In practice: top up, then dispatch A immediately.
- [E] The first run refreshes about 50 hours in one call against a 10-minute
  `max_runtime`. [P] Production call times at baseline IO were 2.6–76 s per
  hour, so the call may time out at baseline. It then rolls back and retries
  (3 retries, 5 minutes apart) without losing data. In burst windows calls
  took 0.3–1.8 s per hour. Dispatch A in a burst window.
- [P] The final top-up is [2026-10-15 11:00, Hc − 48 h): 21 h for a first
  forward run at 2026-10-18 10:07 UTC, 69 h at 2026-10-20 10:07 UTC. Each
  hour of delay adds one hour. Burst-window runs on 2026-10-17 took about
  12 s per hour.

**Why not activate 266 with the gap and let reconcile fill it [V from
migration 265 code and 266's job settings].**

- The reconcile job repairs at most 7 days per night, at 22:30 UTC (04:00
  IST), with a 30-minute `max_runtime`. The whole run is one transaction: a
  timeout rolls back every day it repaired.
- [P] At baseline IO one backfill day took 25–59 minutes. A 7-day repair is
  very unlikely to finish in 30 minutes, so the gap would probably never
  shrink. Each attempt (up to 4 per night) holds the forward job's advisory
  lock, so the 1h tier stops advancing meanwhile, and every timeout adds job
  failures.
- [V] On staging the nightly reconcile has never had to repair anything
  (0 mismatches every night since 2026-09-25, 45–64 s per run), so large
  repairs are untested anywhere.
- It only looks back 35 days from the checkpoint. Gap hours older than that
  are never examined: Sep 24 07:00 UTC leaves the window if activation is
  later than about 2026-10-29.
- [A] Gaps stay repairable while the 15m tier holds the source data
  (120-day retention, so until about early January 2027 for 2026-09-04).

### G2: Energy parity for 263 (Release B)

Before dispatch, capture a parity baseline of
`analytics.get_canonical_energy_read` for the 56 PRIMARY_METER assets and
confirm bridge coverage. After deploy, compare against the same ranges. The
pass criterion is decision D3.

**Readiness status 2026-10-18: BLOCKED. Do not dispatch until every item
below is resolved, each with its own approval.** Update 2026-10-20: A + 48 h
and D3 are resolved; B1 (268, 269) is deployed, so the lock item below
applied to B1 and is done (lock wait 0 s). B2 still needs the staging
validation and the P5 ranges and resolutions.

- A + 48 h: the observation window ends 2026-10-19 12:05 UTC (section 6,
  "Release A acceptance"). Closed 2026-10-19 14:20 UTC, all PASS.
- G2 / P5 tooling exists since 2026-10-19
  (`energy_parity_capture.sql`, `energy_parity_compare.py`; tested locally
  and with a 1-asset staging probe). Still needed: a staging validation for
  all 56 assets at P5's resolutions (needs approval: read load), and the P5
  ranges and resolutions themselves (proposed: the B1 range at `1d`, `1h`
  and `15m`, plus one closed day at `native`).
- D3 (pass criterion) is still open. Decided 2026-10-19 (section 9).
- 268 takes an ACCESS EXCLUSIVE lock on every `energy_consumption_1min/5min`
  chunk with no `lock_timeout` (section 3). Dispatch when the energy jobs that
  touch those tables are idle, and watch for lock waits (P10 plus
  `pg_locks`).
- [M 2026-10-18] The energy reconcilers 1114–1118 are paused. B does not
  need them, but the parity baseline and the post-deploy comparison must be
  taken in the same state, or a reconciler repair between the two could show
  up as a false parity mismatch.

### G3a: Migration 300 staging acceptance (Release D) — PASSED

[V] Passed 2026-10-15 12:16 UTC (24 h 24 min after deploy): six targets
+293 runs each, 0 failures, demand p99 end + 7:06.8, all reconcilers
healthy. 302 was deployed to staging on 2026-10-16 and validated.

### G3b: Production readiness for 299–303 (Release D) — MET for deployment 2026-10-23 (amended gate, below)

Read-only production assessment, 2026-10-16:

| Evidence | Value |
|---|---|
| Normalization 1000, 1-minute batch (60 runs, 12:49–13:49 UTC) | [M] p50 11.0 s, p95 33.5 s, max 38.6 s; 3,144 rows per run |
| Energy routing 1001 (7 runs) | [M] p50 546 s, max 592 s; starts every 8–10 minutes; lag 15–21 min |
| Environment routing 1012 (6 runs) | [M] p50 504 s, max 576 s |
| Demand 1062 (43 runs) | [M] p50 24 s, max 81 s; lag 24–35 min |
| Routing `window_events` read after 267 | [M] hit the 30 s statement timeout 6 of 6 times (staging 0.12–0.21 s). It scans all 12 compressed chunks, 353 MB |
| Five-minute normalization batch (15,720 rows) | [E] 32–103 s against a 90 s budget; **not measured** |
| Host IO | [M] PSI io *some* 85–90 %, disk util ~87 % at ~20 MB/s at baseline |
| Capture policy 5 (site `49500fb9-0ea9-4496-8eeb-55131c89d0c2`) | [M] 300 + 30 s, so 300 raises its WARNING (D8) |

[E] With 300 active today, routing would miss its 30-second slot most
cycles, batches would publish a cycle late, and 302 would show persistent
"No recent data".

Release D may be considered only when **all** of these pass, each with its
own approval:

1. Release A deployed (**done 2026-10-17**); production routing durations
   measured (≥ 24 h, read-only sampler P11; **not yet run**. A 10-minute
   spot sample on 2026-10-18 is in section 6, "Release A acceptance").
   **Met 2026-10-23 by existing run counts instead of the sampler (G3b
   amendment, below).**
2. Migration 303 merged, deployed to staging and validated there (plans,
   completeness, late data, catch-up, demand, rollback).
3. The bounded routing read timed read-only on production (P12) and found
   well within budget. **Passed 2026-10-23: 25 ms energy, 33 ms environment
   (G3b amendment).**
4. The five-minute normalization batch validated on a production-snapshot
   replica (D9; proposed setup in the operations plan, not yet approved). No
   one-off production normalization test is approved, and no production job
   is to be delayed to create a batch. **Moved 2026-10-23 to the separate
   approval to enable five-minute batching; no longer a deployment gate
   (G3b amendment).**
5. D8's condition met: the 300-second capture policy 5 confirmed
   intentional by the product owner (2026-10-17, recorded in section 9).

**Item 2, last staging check: chunk rollover (B6) — PASSED with a documented
source-data exception** (closed 2026-10-23, user-approved ruling).
Evidence run 2026-10-23 05:00 UTC, read-only, by the scheduled B6 task
(`ems-ops-snapshots/rollover-303/20261023T050002Z`); attribution queries
08:20 UTC, read-only on staging.

| Criterion | Evidence | Result |
|---|---|---|
| Floor advanced 7 days | R1 floor 2026-10-22 00:00 UTC (was 2026-10-15); chunk `_hyper_7_525_chunk` compressed; 9 compressed / 1 uncompressed | PASS |
| Compression job | 1073 Success 04:48:49 UTC, 3 min 53 s; failures 14 (all 2026-09-18/19, unchanged) | PASS |
| Routing durations | 1001 0.45 s, 1012 0.12 s (same order as +2 h); late sweep 1142 140 runs / 0 failures | PASS |
| Checkpoints | Sweep 30 min behind forward, `never_ahead` true for both pipelines | PASS |
| Completeness (corrected V6) | Energy 8,448 / 8,448 minutes, environment 695 / 695 device-minutes, 0 missing, 0 pending | PASS |
| Demand VALID share (V7, stop rule > 1 pp drop) | 90.1 % last 24 h vs 100.0 % before; **fired** | Exception (below) |

Source-data exception, attribution verified:

- Raw messages per hour from gateway `Eniscope_3_Meenaxy_Unit2` (Meenaxy
  Pharma, Unit 2): 2,027 at 06:00 and 1,670 at 07:00 UTC on 2026-10-22, then
  **0 for every hour from 08:00 UTC on 10-22 to 05:00 UTC on 10-23**, then
  1,553 at 06:00 and 2,287 at 07:00 UTC. The sibling gateways Eniscope 1 and
  2 on the same site stayed at 2,049–2,302 per hour throughout, so the outage
  is the one gateway, upstream of ingestion.
- No normalized points or energy rows exist for its meters inside the gap
  (checked for meter `E3_EM4_HTR_P1_01`), so nothing was received and dropped.
- All 510 non-VALID demand intervals in the V7 window belong to that
  gateway's 6 assets (504 NO_DATA 10-22 08:00 → 10-23 04:45, 6 INCOMPLETE at
  07:45 as it went silent). Excluding those 6 assets, the VALID share is
  **100.00 % in both 24-hour windows** (4,608 / 4,608).
- After recovery the 6 assets are VALID again (36 / 36 intervals from 06:30
  UTC). The gap started a day before the rollover, so it is not related to
  the chunk boundary or to 303.

Ruling: the V7 drop is a source outage, not a pipeline regression; B6 is
recorded as passed. Item 2 is complete.

After D, routing p99 must stay comfortably under ~25 s before five-minute
batching is (re)activated.

#### G3b amendment (2026-10-23, user-approved)

Two changes to the gate, approved by the user on 2026-10-23 to keep the
readiness process proportionate. They apply to this deployment only;
nothing else in G3b changes.

1. **Item 1 is satisfied by existing production run counts instead of a
   24-hour sampler.** Read-only `timescaledb_information.job_stats` /
   `_timescaledb_internal.bgw_job_stat` on production [M]:

   | Job (fixed 1-minute schedule) | From | To (2026-10-23 11:27 UTC) | Runs | Minutes | Failures |
   |---|---|---|---|---|---|
   | Energy routing 1001 | 93,174 runs, 2026-10-19 14:19:50 UTC | 98,761 | 5,587 | ≈ 5,587 (93 h) | 1,434 → 1,434 |
   | Normalization 1000 | 129,033 runs, 2026-10-22 07:18:24 UTC | 130,721 | 1,688 | ≈ 1,689 (28 h) | 39 → 39 |

   On a fixed schedule a run that outlasts its minute skips the next slot,
   so one run per minute for 93 hours shows that no routing run exceeded
   one minute and none failed. Supporting [M]: latest single runs 0.3–3.5 s
   (1001 3.54 s, 1012 0.29 s, 1000 1.06 s at 11:21 UTC); energy routing lag
   76–136 s throughout the 51-minute production backup (08:14–09:05 UTC),
   112 s at the 11:22 UTC precheck; before Release A (2026-10-16) routing
   started only every 8–10 minutes.
   **Not measured:** worst-case and percentile (p95 / p99) run durations.
   Production records only each job's latest duration and cumulative
   totals (`timescaledb.enable_job_execution_logging` is off), so the
   evidence bounds every run below 60 s but does not show whether runs fit
   the ~25 s routing slot that five-minute batching needs. Cumulative
   baseline at 11:27 UTC for a later mean: 1000 1,401,676.86 s / 130,721
   runs; 1001 3,012,706.48 s / 98,761; 1012 2,894,253.32 s / 98,371.
2. **Item 3 passed** (P12, 2026-10-23 ~11:24 UTC, read-only,
   `default_transaction_read_only=on`, 30 s timeout,
   `scripts/diagnostics/prod_routing_bounded_read_timing.sql`). The guard
   found 13 compressed chunks and 1 uncompressed (floor 2026-10-22 00:00
   UTC) and a plan touching no compressed chunk. Bounded energy read over a
   5-minute receipt window: **25 ms** (15,720 rows, index scan of the one
   uncompressed chunk, 526 buffers); bounded environment read **33 ms**.
   The unbounded read timed out at 30 s 6 / 6 times on 2026-10-16. This
   proves the 303 forward read is fast on production's data and chunk
   layout; it does not time a whole routing run.
3. **Item 4 moves out of this gate.** Five-minute batching validation is a
   condition of the separate, future approval to enable five-minute
   batching on production, not of deploying Release D. Deploying keeps
   production on 1-minute schedules: migration 300 is applied with the
   rest, and the six jobs are returned to their 1-minute schedules
   immediately after the deploy (D9; prepared step below). The same future
   approval must show routing p99 under ~25 s (item 1's open point).

Gate status after the amendment: items 1, 2, 3 and 5 met; item 4 deferred
to the batching approval. G3b no longer blocks the deployment; the
deployment itself still needs explicit scope and dispatch authorization.

**Remaining risks accepted with the amendment:**

- From migration 300's commit until the restore, the six jobs run on
  five-minute schedules (expected: the rest of the deploy run plus the
  restore, minutes [E]). Effect if a batch overruns: data reaches
  dashboards one 5-minute cycle later; no data loss (checkpointed,
  idempotent; staging 24 h acceptance 2026-10-15) [A for production].
- Worst-case / percentile routing durations unknown (item 1).
- Migration 299's 600 s normalized-data "receiving" threshold becomes
  active on deploy (D4b): devices count as receiving for up to 10 minutes
  after their last normalized data instead of 5 (on staging since
  2026-10-14).
- The 2026-10-23 production backup
  (`prod_snapshot_20261023T0814Z.dump`, 7.18 GB, sha256 `46978832…`) is
  structurally verified (`pg_restore --list`, 6,955 entries) but has not
  been test-restored.

#### Release D post-deploy step: 1-minute schedules (prepared, not run — superseded 2026-10-23: the six jobs stay on five-minute schedules)

Run once, with its own approval, right after the deploy run and its
post-deployment verification pass:

1. `docs/10-operations/prepared/release-d/post_deploy_restore_1min_schedules.sql`
   with `-v target=production`. One transaction. It refuses unless
   migrations 300 and 308 are in the ledger, the six jobs resolve by name
   to production IDs 1000, 1001, 1012, 1063, 1044 and 1083, and all six are
   still on migration 300's five-minute fixed schedule. It restores
   production's pre-300 settings read on 2026-10-23 (fixed 1-minute grid
   and original `initial_start` for 1000 / 1001 / 1012 / 1063; non-fixed
   1 minute for the 1044 / 1083 refreshes) and proves that no other
   setting or job changed.
2. `post_deploy_restore_1min_verify.sql` (read-only) at T0 and T+60 min.
   Pass: all six on 1 minute and scheduled; each job's run count up by
   59–61 per hour; failures unchanged (2,840 excluding 1114) and no job
   errors since the restore; ingest checkpoint lag and energy routing lag
   under 5 minutes.

Tested 2026-10-23 on the disposable local test database (all migrations
through 308, so in the post-300 state): `target=production` refused on the
local job IDs; `target=local-test` restored all six and committed; a second
run refused ("already restored"); the verification script ran clean, and
in the next minute each job ran once, successfully, at its restored second
(:18, :19, :24, :24, :48, :50). If a
check fails on production, the transaction rolls back and the jobs stay on
five-minute schedules, which is the staging-validated configuration.

## 5. Read-only production prechecks

Each needs explicit authorization.

**Fact refresh (once, before the Release A decision is acted on).**
`scripts/diagnostics/prod_release_266_301_fact_refresh.sql` re-checks every
[P] fact in this document in one read-only transaction that ends in
ROLLBACK. It was validated read-only on staging (about 7 seconds).

| Query | Refreshes |
|---|---|
| R1 | Ledger 131 rows, head 265; digest of applied rows. Expected digest, from staging's matching 131 rows: `86ddfe42b46b281cb77491133d839909` |
| R2 | 1h frontier and row count |
| R3 | The four 1h jobs (unscheduled, 265 settings) and their NULL checkpoint |
| R4 | Failure counter as the runner computes it, and every job error since the 2832 baseline |
| R5 | 267 preconditions (P4) |
| R6 | 301 md5 pins (P8) |
| R7 | Retention policies (90-day raw, 120-day 15m source) |
| R8 | Oldest `energy_measurements` chunks up to the first with two or more devices (F1 deadline) |
| R9 | Rows in compressed `environment_measurements` chunks (291 deadline) |
| R10 | Parity bridge: 112 rows, 56 assets, no other `asset_points` rows |

**Release prechecks.** Run them immediately before the release that depends
on them.

| Check | Confirms | Release |
|---|---|---|
| P1 | Ledger row count and head; checksums of applied rows match the repository | Every release |
| P2 | `scripts/apply_migrations.sh --status` lists exactly that release's migrations as pending, in manifest order (call the script directly, not a test wrapper) | Every release |
| P3 | 1h jobs still unscheduled with their 265 configuration; 1h frontier meets G1 | A |
| P4 | Routing loader bodies match migrations 215/228; `normalized_points` `compress_after` = 1 day | A |
| P5 | Bridge coverage and parity baseline (G2). Tooling: `scripts/diagnostics/energy_parity_capture.sql` + `energy_parity_compare.py` (2026-10-19; tested locally and with a 1-asset staging probe; full staging validation pending approval) | B (B1 uses the same tooling for its before/after check) |
| P6 | Migration-213 function md5s expected by 297 | C |
| P7 | Exactly one job for each 298/300 target (IDs in section 3); all six 300 targets on 1-minute schedules; capture policies within 60 + 60 s. **Policy 5 (300 + 30 s) fails the last clause [M]**: D needs decision D8 | C2′ (298), D (300) |
| P8 | Loader md5s expected by 301 | D |
| P9 | Compressed `environment_measurements` row count (291) and oldest non-empty `energy_measurements` chunk (290) | C1 |
| P10 | No backfill or STOP active; failure count unchanged since the last check; job 1053 (compression) not running or due | Every release |
| P11 | Job-duration sampler (`scripts/diagnostics/prod_job_duration_sampler.sql`): `timescaledb_information.job_stats` and `telemetry.pipeline_state` every 30 s for 24 h; jobs found by name (1000, 1001, 1012, 1044, 1083, 1063, 1062, 1060, 1053 on production); catalog reads only. Run with `scripts/diagnostics/run_readonly_job_sampler.sh <host> <dir>`: reconnects after a dropped SSH session with only the samples still due, never past the end time, never retries a segment that did not report read-only, STOP file to end early (staging-tested 2026-10-17 incl. a forced disconnect; no orphaned session) | Before A (baseline), after A, before and after D |
| P12 | Bounded routing read: EXPLAIN plus one timed run of 303's forward read, which touches only uncompressed chunks (`scripts/diagnostics/prod_routing_bounded_read_timing.sql`, added with 303) | D |

**Never run the unbounded routing read on production.** The routing
`window_events` query filtered only on `platform_received_at` scans every
compressed `normalized_points` chunk; on 2026-10-16 it hit the 30 s timeout
six times and added about 3 minutes of IO load.

## 6. Deployment procedure (each release)

1. Get explicit approval for the release, its gate and its prechecks.
2. Run the prechecks (section 5). Stop on any mismatch.
3. Dispatch `deploy-production.yml` from GitHub Actions with
   `release_git_sha` and `confirm_release_git_sha` both set to the full SHA
   from section 2, and `promotion_mode=staging-milestone`. Never use
   `staging-head` for these releases: staging may move ahead.
4. The workflow checks the operator allowlist, the SHA confirmation, the
   staging deploy run, ancestry and forward-only movement. It then pins the
   image digest, checks out the commit on the host, applies the pending
   manifest rows and recreates `admin-portal` and `live-telemetry` only.
5. `verify-production` must pass its three REQUIRED gates: Database
   Structure, Metadata Integrity and Energy Routing Metric-Identity. The
   pipeline and job suites are advisory.

**No out-of-band path.** Do not apply migrations by hand, edit the manifest
or patch the host. If the workflow refuses, stop and investigate.

**A release can stop partway.** Each migration commits on its own. If one
fails (for example a precondition), the earlier migrations of that release
stay applied. `deploy_release.sh` (`set -e`) then stops before step 5, so the
running containers keep the old image while the host checkout is already at
the release commit [V]. That is why the md5 and
job prechecks run before dispatch, not after.

### Stop conditions

Stop and report, without retrying, if any of these happen:

- a precheck mismatch;
- the workflow refuses the dispatch;
- a migration error or checksum mismatch;
- a failed REQUIRED gate;
- new job failures after deploy (other than the known 40P01 pattern before C);
- routing lag that does not return to its pre-deploy range;
- an Energy parity mismatch after B.

### Evidence of success

| Release | Required evidence |
|---|---|
| All | Run succeeded; REQUIRED gates passed; ledger shows exactly the release's migrations as `applied` with checksums equal to staging; no new job failures |
| A | First 1h forward run succeeds (checkpoint no longer NULL) and later runs advance it; no 1h hour missing between Sep 4 and the checkpoint; first nightly reconcile succeeds; routing jobs 1001/1012 show lower runtime; observe ≥ 48 h before B |
| B | Parity comparison passes D3; Grafana Energy panels load; no lock waits from 268 left behind; Analytics API endpoints respond |
| C1 | F1 forward job advancing through history; environment routing succeeds (291) |
| C2′ | Demand job 1062 at :07/:22/:37/:52; demand intervals finalized with the same VALID share as before |
| D | Routing durations within budget (P11); no 40P01 over the following days; five-minute phases only once activation is approved (D9) |

### Release A acceptance (2026-10-18)

All [M], from read-only production sessions
(`default_transaction_read_only=on`) on 2026-10-17 and 2026-10-18.

| Criterion | Evidence | Result |
|---|---|---|
| Run, gates, ledger | `deploy-production.yml` run `39030992116`, dispatched 2026-10-17 12:02:47 UTC. 266 applied 12:05:04 UTC (sha256 `7f8b3863…`), 267 12:05:05 UTC (`7ac3a331…`), both equal to the repository files; ledger 133 rows. REQUIRED gates passed. Advisory failures all pre-existing and fewer than on 2026-10-08 | PASS |
| First forward run | Job 1130, 2026-10-17 12:07 UTC, SUCCESS in 1 min 58 s, 148,140 rows; checkpoint NULL → 12:00 UTC | PASS |
| Forward runs advance | 1130: 70 of 70 runs successful by 2026-10-18 05:22 UTC (every :07/:22/:37/:52 slot, none skipped); checkpoint 2026-10-18 05:00 UTC | PASS |
| No 1h hour missing | Rows in every hour from 2026-09-04 00:00 UTC to the checkpoint, except Sep 21 00:00 – Sep 22 03:00 UTC (source outage, 0 rows in the 15m source too). Oct 14 00:00 → Oct 18 04:00 UTC: 101 of 101 hours, 3,144 rows per hour | PASS |
| Late data | Hour 2026-10-17 11:00 UTC was 3,144 samples short (one per series) after the first run; the 13:07 UTC run re-derived it. Deficit detector over Oct 17 00:00 → checkpoint: 0 rows | PASS (self-healed) |
| First nightly reconcile | Job 1131, 2026-10-17 22:30:00 UTC, SUCCESS in 56 s (limit 30 min). Log run `5a61c4d8…`: outcome HEALTHY, window Sep 12 22:00 → Oct 17 22:00 UTC, 0 mismatching days, 0 rows repaired, 0 errors. The forward lock was held 22:30:00–22:30:56, between the 22:22 and 22:37 forward slots | PASS |
| New 1h jobs | 1128 (retention 1 year, daily) ran 2026-10-17 12:05 UTC; 1129 (compress after 30 days, every 12 h) ran 12:05 UTC and 2026-10-18 00:05 UTC; all succeeded | PASS |
| No new job failures | Failure total (all jobs except 1114) 2840 before and after; no job errors since 2026-10-17 12:00 UTC; no job currently failing | PASS |
| Routing 1001 / 1012 runtime | Spot sample 2026-10-18 05:36–05:45 UTC: 1001 0.33–1.7 s, 1012 0.34–0.91 s per run, starting every minute (2026-10-16: p50 546 s and 504 s, starting every 8–10 min). Energy routing lag about 115 s (297–487 s before deploy). Not the 24-hour P11 measurement | PASS (spot sample) |
| Host | 0 locks, blocked sessions and long transactions; disk 57 %; about 700 MB available memory; containers healthy | PASS |
| Paused jobs | 1053 and 1114–1120 still paused and unscheduled; not changed by A | Unchanged |
| Later checks | 2026-10-18 12:19 and 18:21 UTC: 1128 run 2 and 1129 runs 2–3 succeeded; 1130 121 of 121 runs; checkpoint 18:00 UTC; Oct 14 00:00 → Oct 18 17:00 UTC 114 of 114 hours, 3,144 rows per hour; 0 deficits; failure total 2840; 1001 / 1012 0.31–0.65 s per run | PASS |
| Disk | 54 GB (56 %) on 2026-10-17 → 57 GB (59 %) on 2026-10-18 18:21 UTC; database 26.3 GB, of which `normalized_points` is 10.5 GB (still filling to its 90-day retention) and `raw_messages` 2.4 GB (3 uncompressed daily chunks, bounded by 48 h retention; compression job 1053 paused) | Deferred: disk is reviewed separately, not part of A's acceptance |
| Second nightly reconcile | Job 1131, 2026-10-18 22:30:00 UTC, SUCCESS in 70 s. Log run `e846a813…`: HEALTHY, window Sep 13 22:00 → Oct 18 22:00 UTC, 0 mismatching days, 0 repairs, 0 errors. Lock held 22:30:00–22:31:10, between forward slots; 1130 141 of 141 runs by 23:07 UTC (no slot skipped) | PASS |
| Observe ≥ 48 h before B | Window ended 2026-10-19 12:05 UTC; final checks 14:20 UTC: 1128/1129 12:05 runs Success, 1130 201/201 runs, 50/50 hours at 3,144 rows, 0 deficits, failure total 2840, 0 errors, 0 locks | PASS (2026-10-19) |

## 7. Rollback limits

- `rollback.yml` redeploys an earlier image only. It does **not** reverse
  migrations ([rollback.md](rollback.md)).
- Database changes are forward-only. Reversal means a new forward migration
  or the reverse steps in a migration header (section 3), each with its own
  approval.
- An image rollback leaves the new database functions in place. 280 and
  282 drop `get_portal_analytics_energy_series` (6 arguments) and
  `get_portal_asset_energy_series` (6 arguments). The `9ca461e` app calls
  neither [V], so rolling back to it after B is compatible. For any other
  target image, check its calls against the functions changed since.
- 268's columns and constraints stay after any rollback.
- **298** (C2′): `alter_job(1062, schedule_interval => INTERVAL '1 minute')`,
  keeping its current phase. Verify the ID first.
- **300** (D): `alter_job` each of 1000, 1001, 1012, 1044, 1083, 1063 back to
  `schedule_interval => INTERVAL '1 minute'` with the `fixed_schedule` and
  `initial_start` recorded by precheck P7 immediately before D (300's NOTICEs
  print the values it replaced). The ledger row stays; 302 then falls back to
  the migration-282 formula automatically.
- **302**: forward migration re-applying migration 284's
  `get_portal_asset_energy_series`, then dropping
  `analytics.energy_stale_pipeline_allowance(integer)`.
- **303**: forward migration re-issuing the 267 / 291 loader bodies, dropping
  the late-sweep jobs and their checkpoint rows (header of 303).
- Every rollback above is a schedule or code change on production and needs
  its own approval.

**Release B stale-flag risk [E].** B brings migration 282's stale flag for
`analytics.get_portal_asset_energy_series`. Its threshold is the sum of the
pipeline stage intervals (about 7 minutes with 1-minute jobs). Production
routing currently lags 15–23 minutes [M], so the flag would mark most
production Analytics API series responses `stale = true`. Production has no
Analytics UI (D6), so no customer screen shows it, but any API consumer would.
It clears only once routing lag falls below the threshold (Release A's 267
and then 303). Record it in B's release note. [M 2026-10-18, spot samples
only] After Release A, energy routing lag is about 1–2 minutes and 1001/1012
take under 2 s per run, so the flag would probably not be persistent. Confirm
with P11 and check after B.

## 8. Target dates (all [E])

| Release | Earliest | Depends on |
|---|---|---|
| A | **Deployed 2026-10-17** (run 39030992116; 266 12:05:04 UTC, 267 12:05:05 UTC; first 1h forward run 12:07 UTC SUCCESS, checkpoint 12:00 UTC, no 1h gap, no top-up needed). **Accepted 2026-10-18** (section 6, "Release A acceptance"); 48-hour observation ends 2026-10-19 12:05 UTC | G1 met; D1 decided 2026-10-17 (option a, baseline 2840) |
| B | B1: **deployed 2026-10-19** (run 39293585987). B2: about 2026-10-22 | B1: A + 48 h, D3 (both met). B2: G2 |
| C1 | about 2026-10-24, target no later than 2026-10-27 | B, D2, D5 |
| C2′ | **Deployed 2026-10-23** (run 39905366140, 292–295, 297, 298, `d52b049`). **Accepted 2026-10-25** (section 2, "C2′ acceptance") | C1, D4a |
| D | **Deployed 2026-10-23** (run 39957525916, 299–308, `7e3da57`); 24-hour acceptance due 2026-10-24 13:50 UTC | G3b (amended) |

The product-owner target for F1 (290) is 2026-10-27, with no retention
changes. [P] Evidence from 2026-10-11 shows `energy_measurements` chunks
before 2026-08-04 are empty, so real loss starts about 2026-11-03 (one row)
and becomes multi-device about 2026-11-08. Migration 291's failure point is
about early-to-mid November [E] (about 43,600 compressed rows on 2026-10-08,
growing about 10,000 per week). Re-measure both with P9.

## 9. Product-owner decisions

D1, D4a, D4b, D8 and D9 were decided by the product owner on 2026-10-17, and
D3 (for B1) on 2026-10-19. None of
the others is assumed approved. A decision is not an approval to execute:
each release, precheck and schedule change still needs its own approval.

| # | Decision | Options |
|---|---|---|
| D1 | How to meet G1 | **Decided 2026-10-17: option (a), failure baseline 2840; G1 met at Release A.** (a) Resume the 1h backfill under the proposed baseline policy, then top up and dispatch A in one burst window (recommended). (b) Activate 266 with the gap and rely on the nightly reconcile (section 4: likely never completes at baseline IO). (c) Activate 266 and leave a permanent 1h gap from Sep 24 07:00 UTC to activation − 2 days |
| D2 | F1 deadline and release split | Keep 2026-10-27 or set it from the 2026-11-03 evidence. C1 / C2′ split agreed 2026-10-17 |
| D3 | Release B parity pass criterion | **Decided 2026-10-20 for B2:** exact equality, zero tolerance, `--criterion full --expect-assets 56`, 0 `PARITY_ERROR`; `1d,1h,15m` over the B1 range plus `native` for 2026-09-26 18:30 → 09-27 18:30 UTC; pre1 = pre2 before dispatch, pre2 = post after; 1114–1120 paused throughout; 269 → 270 replacement expected; timing informational (section 2, "B2 preparation"). **Decided 2026-10-19 for B1: exact equality, zero tolerance, `1d` only, exactly 56 assets** (B1 result: PASS 56/56). B2's resolutions follow P5 and are not yet set. Rule as proposed: exact equality, no tolerance. `energy_parity_compare.py BEFORE AFTER --criterion full --expect-assets 56` exits 0: same range and resolutions; both captures complete (CAPTURE_END) with 0 PARITY_ERROR; exactly 56 assets × each resolution in both; for every pair identical row count, import and export kWh totals (exact numeric text), `values_md5` and `full_md5` (every returned column of `get_canonical_energy_read`, whose column list 269 cannot change). Gate before dispatch: b1_pre1 vs b1_pre2 PASS (repeatability). Timing is informational. Any FAIL or INVALID = investigate before B2; it does not by itself trigger a B1 rollback (B1 recovery is forward-only) |
| D4a | 298 on production (C2′) | **Decided 2026-10-17: retain the 15-minute demand schedule (:07/:22/:37/:52 UTC) in C2′.** |
| D4b | 299/300 on production (D) | **Decided 2026-10-17: deferred pending G3b.** 299's 600 s freshness rule and 300's 5-minute batches are not activated before the gates pass |
| D5 | Admin Portal assignment on production | Release C makes "Assign Data Points" Save live |
| D6 | Analytics UI on production | Confirm production stays API-only until a separate frontend rollout |
| D7 | Routing job runtime limits | After A and 303 are measured (P11), whether to restore jobs 1001/1012 `max_runtime` from 30 to 5 minutes (separate approval). **2026-10-23: still 30 min; recommended to align to 5 min by forward migration after the Release D 24-hour acceptance ("Release D execution record"); not yet approved** |
| D8 | Capture policy 5 under 300 | **Decided and condition met 2026-10-17: accept 300's WARNING.** The product owner (owner of the "Avinash Home" organization, site "Vivekanandanagar Home" `49500fb9-0ea9-4496-8eeb-55131c89d0c2`) confirmed on 2026-10-17 that the site's 300-second capture policy (policy 5, 300 + 30 s) is **intentional**, although the staging onboarding requests of 2026-08-02 / 08-06 asked for 60 s. Effect under 300: that site's boundary bucket is finalized one batch later (about 5 minutes more latency). The production policy is not changed. The production lookup (`scripts/diagnostics/prod_d8_capture_policy_lookup.sql`) was not run and is no longer needed for D8 |
| D9 | How 303 reaches production | **Decided 2026-10-17: option (1).** Release D (299–303); restoring the six 300 jobs to 1-minute schedules is a post-deploy step that needs its own explicit approval; five-minute batching is activated only after replica validation (G3b item 4), by separate approval. Rejected: (2) D with 300 active; (3) runner change. **Amended 2026-10-23 (user-approved):** batching validation (item 4) belongs to the batching approval, not to the deploy; the post-deploy restore is prepared in G3b ("Release D post-deploy step") and still needs its own approval. **Superseded 2026-10-23 (user decision after deploy):** the six jobs stay on five-minute schedules; the restore was not run ("Release D execution record") |
