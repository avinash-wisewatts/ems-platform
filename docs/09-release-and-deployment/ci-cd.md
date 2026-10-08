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
| `.github/workflows/deploy-production.yml` | `workflow_dispatch` only, inputs `release_git_sha` + `confirm_release_git_sha` (double entry) + `promotion_mode` (`staging-head` default, or `staging-milestone`) | Deploys the image built for `release_git_sha` (derived from the SHA, digest-pinned; there is no independent image input) after it was proven on staging. Never auto-triggered. First run: 2026-08-29 (`33239331538`); most recent documented run: 2026-08-30 (`33304784449`, migrations 216–222). See [Promotion modes](#promotion-modes). |
| `.github/workflows/rollback.yml` | `workflow_dispatch` only | Redeploys a previously-built image tag to `staging` or `production` via the identical deploy path. |

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
| `staging-milestone` (added 2026-10-08) | an **earlier commit in staging's history** (GitHub compare `<sha>...staging` is `ahead` or `identical`) that **moves production forward**: the head SHA of the most recent successful `deploy-production.yml` run must be a strict ancestor of it (fails closed if none) | the commit must still be in staging's history |

`staging-milestone` exists for staged release promotion: deploying a
milestone commit that already passed staging, so that operator steps can run
between groups of migrations (first use: the 223–290 release, where the
production `asset_points` parity bridge must run after migration 228 and
before 250, and the 15m/1h backfills between 265 and 266). Deploying a
milestone also deploys that milestone's application image and the
configuration checked out at that commit. It can never redeploy the current
release or move production backwards; that remains `rollback.yml`'s job.

Known limit: "the last promoted release" is the last successful
`deploy-production.yml` run. If `rollback.yml` has since moved production to
an older commit, the forward-only check compares against the last promotion,
which is stricter than necessary, never looser.

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
