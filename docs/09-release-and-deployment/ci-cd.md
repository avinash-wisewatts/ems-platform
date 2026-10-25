# CI/CD Pipeline

Status: CURRENT · Last reviewed: 2026-10-08
Verification basis: Repository, Staging, Audit evidence, Production (2026-08-30: `deploy-production.yml` run `33304784449`)

This summarizes and cross-checks `docs/operations/CICD_PIPELINE.md` (kept
in place — the repository's own detailed, authoritative writeup) against
live findings. Read that document directly for full narrative detail and
the GitHub-side configuration checklist.

## Principle

```text
BUILD ONCE -> TEST -> PROMOTE THE SAME ARTIFACT
```

One application image is built per commit pushed to `staging`
(`.github/workflows/deploy-staging.yml`), tagged immutably with its Git
commit SHA (`ghcr.io/<owner>/<repo>-app:<sha>`), pushed to GHCR, deployed to
staging, verified, and only deployed to production on a separate, manual
`workflow_dispatch` of `deploy-production.yml`, using the *exact same image
tag*. Production never rebuilds from source.

## Pipeline shape

| Workflow | Trigger | What it does |
|---|---|---|
| `.github/workflows/ci.yml` | `pull_request`, `push` (any branch), `workflow_call` | Config validation, Docker build validation, pytest suite, database/migration integration suite. Never deploys. |
| `.github/workflows/deploy-staging.yml` | `push` to `staging` | Calls `ci.yml`, builds+pushes the immutable image, deploys via SSH, runs post-deploy verification. |
| `.github/workflows/deploy-production.yml` | `workflow_dispatch` only, inputs `release_git_sha` + `confirm_release_git_sha` (double entry) + `promotion_mode` (`staging-head` default, or `staging-milestone`) + `expected_migrations` (see [Environment-scoped migrations](#environment-scoped-migrations)) | Deploys the image built for `release_git_sha` (derived from the SHA, digest-pinned; there is no independent image input) after it was proven on staging. Never auto-triggered. First run: 2026-08-29 (`33239331538`); most recent documented run: 2026-08-30 (`33304784449`, migrations 216–222). See [Promotion modes](#promotion-modes). |
| `.github/workflows/rollback.yml` | `workflow_dispatch` only, inputs include `expected_migrations` (default `none`) | Redeploys a previously-built image tag to `staging` or `production` via the identical deploy path, after the same pending-migration precheck. |

## CI gates

See [../08-verification/test-strategy.md](../08-verification/test-strategy.md).

## Promotion modes

`deploy-production.yml` always enforces, in every mode: the
`PRODUCTION_APPROVED_OPERATORS` allowlist, double-entry SHA confirmation, a
successful `deploy-staging.yml` run for that exact commit (looked up by
commit, not by a recent-runs window), the SHA-derived GHCR image resolved and
digest-pinned again just before SSH, and post-deployment verification.

| Mode | `release_git_sha` may be | Pre-deploy recheck |
|---|---|---|
| `staging-head` (default; original behaviour) | only staging's **current HEAD** | staging HEAD must not have moved |
| `staging-milestone` (added 2026-10-08) | an **earlier commit in staging's history** (GitHub compare `<sha>...staging` is `ahead` or `identical`) that **moves production forward**: the release **deployed** by the most recent `deploy-production.yml` run whose deploy job succeeded must be a strict ancestor of it (fails closed if it cannot be established) | the commit must still be in staging's history |

`staging-milestone` exists for staged release promotion: deploying a
milestone commit that already passed staging, so that operator steps can run
between groups of migrations (first use: the 223–290 release, where the
production `asset_points` parity bridge must run after migration 228 and
before 250, and the 15m/1h backfills between 265 and 266). Deploying a
milestone also deploys that milestone's application image and the
configuration checked out at that commit. It can never redeploy the current
release or move production backwards; that remains `rollback.yml`'s job.

**How "the last promoted release" is established (fixed 2026-10-08).** It is
the `release_git_sha` deployed by the most recent `deploy-production.yml` run
whose deploy job succeeded (a run whose post-deployment verification failed
still changed production). It is read from the run title, which `run-name`
sets to `Deploy <release_git_sha> (<promotion_mode>)`, and/or from the deploy
job's `[1/6] Checking out release commit <sha>` log line (the only source for
runs before `run-name` existed); when both exist they must agree. It is
**never** the run's `headSha`: for a `workflow_dispatch` run that is the
branch tip the workflow ran from (staging's HEAD at dispatch), not the commit
it deployed. The first version of this check used `headSha` and refused
release Stage 3 (`9ca461e`, run `37740385524`) because Stage 2's run deployed
`f1df32f` but recorded `headSha` `aaccb0b`; it failed closed, so nothing was
deployed. Anything missing or ambiguous still fails closed.

Known limit: if `rollback.yml` has since moved production to an older commit,
the forward-only check compares against the last promotion, which is stricter
than necessary, never looser.

Tests: `scripts/test/assert_deploy_production_promotion_gate.sh` (live
against the real repository, Actions history and compare API; Tests 4c/4d
and 19–23 cover the milestone mode). Not run by `ci.yml`; run it locally
when changing the workflow, together with `actionlint`.

**Post-deployment verification timeout.** The `verify-production` SSH step
sets `command_timeout: 45m` (the `appleboy/ssh-action` default is 10m). On
2026-10-08 (run `37732791343`, release Stage 1) the advisory suites in
`post_deploy_verify.sh` scanned production-scale tables past the 10-minute
default, so the step was killed with `Run Command Timeout` after all three
REQUIRED gates had already passed and the run reported failure. Test 24 in the
gate script asserts the explicit timeout.

## Environment-scoped migrations

Some migrations exist only on staging. Today these are 309 and 312 (the
Reports export, not approved for production) and 310 (the one-time AirSense
recovery; production was recovered by a reviewed session script on
2026-10-24). They are listed in `postgres/migration_environment_scope.csv`
(`migration_id,environments,reason`, environments `staging` / `production` /
`test`, `|`-separated). Unlisted migrations apply everywhere.

- **Runner.** `scripts/apply_migrations.sh` requires `DEPLOY_ENVIRONMENT`
  (`deploy_release.sh` passes `ENVIRONMENT_NAME`; the test runner passes
  `test`). A scoped-out migration prints `SKIP-ENV` and gets **no ledger
  row**. A scoped-out migration that is already in the ledger stops the
  runner. The scope file is validated before any database work.
- **Precheck (before any change).** `deploy-production.yml` and `rollback.yml`
  require `expected_migrations`: the migrations the release applies (ids or
  numeric prefixes, e.g. `311`, or `none`). On the host, before
  `deploy_release.sh`, `scripts/release/precheck_release_migrations.sh`
  (always origin/staging's copy) computes what the **target commit's own
  runner** would apply and refuses unless it is exactly the declared set and
  contains no migration scoped away from the environment. A rollback target
  whose runner predates the scope file is judged by origin/staging's scope
  file, so it cannot apply 309 / 310 / 312 to production either.
- **Post-deploy gate (REQUIRED).** With `DEPLOY_ENVIRONMENT=production`,
  `scripts/verify/verify_environment_scope.sh` fails unless no ledger row and
  no object of a scoped-out migration exists
  (`postgres/migration_environment_scope_objects.csv`) and the running admin
  portal exposes no Reports export route.
- **Application.** `EMS_REPORTS_ENABLED` (default **false**) gates the
  Reports export routes and its worker. Production never sets it; staging's
  `app/.env` sets it to `true`.

## Production authorization model

The `production` GitHub Environment exists as a secrets/variables namespace
only, **not** a required-reviewer approval gate (required reviewers on a
private repo require GitHub Enterprise, which this project does not have).
Authorization is procedural: only the repository owner has dispatch access,
and the operator must only ever dispatch an `image_tag`/`release_git_sha`
pair matching a known-good entry in `.deploy-history/staging.log`. Full
procedure: `docs/operations/FIRST_PRODUCTION_DEPLOYMENT_ROLLBACK_RUNBOOK.md`
(kept in place).

## Historical finding, and what has changed since

At an early baseline, staging had zero commissioned sites/gateways/devices,
so `verify_pipeline.sh` reported real FAILs for empty domain tables —
documented at the time as "an environment commissioning gap... not a
deployment defect." As of 2026-08-24, staging has a fully commissioned
organization producing live telemetry end-to-end, confirmed flowing through
raw ingestion, normalization, and aggregation with sub-2-minute freshness.
This does **not** confirm a separately-reported job schedule/overlap drift
finding — treat that as unresolved until independently re-checked. See
[../10-operations/troubleshooting.md](../10-operations/troubleshooting.md).

## What is not independently verified

The current state of GitHub-side configuration (environments, secrets,
branch protection) — none of this is inspectable from repository files or
database access alone.
