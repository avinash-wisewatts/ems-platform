# CI/CD Pipeline

Status: CURRENT · Last reviewed: 2026-08-30
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
| `.github/workflows/deploy-production.yml` | `workflow_dispatch` only, inputs `image_tag` + `release_git_sha` | Deploys a pre-built image tag already proven in staging. Never auto-triggered. First run: 2026-08-29 (`33239331538`); most recent documented run: 2026-08-30 (`33304784449`, migrations 216–222). |
| `.github/workflows/rollback.yml` | `workflow_dispatch` only | Redeploys a previously-built image tag to `staging` or `production` via the identical deploy path. |

## CI gates

See [../08-verification/test-strategy.md](../08-verification/test-strategy.md).

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
