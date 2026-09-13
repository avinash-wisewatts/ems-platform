# CI/CD and Deployment

Status: CURRENT
Last verified: 2026-08-30
Verification basis: Repository, Staging (this session's own migration and verification work), Audit evidence, Production (2026-08-30: `deploy-production.yml` run `33304784449` promoting migrations 216–222)

This document summarizes and cross-checks `docs/operations/CICD_PIPELINE.md`
(the repository's own authoritative CI/CD writeup) against this session's
live findings. For full narrative detail and the GitHub-side configuration
checklist, read that document directly — it is detailed and current as of
its own writing; this page adds only what has changed or been verified
since.

## Principle

```
BUILD ONCE -> TEST -> PROMOTE THE SAME ARTIFACT
```

One application image is built per commit pushed to `staging`
(`.github/workflows/deploy-staging.yml`), tagged immutably with its Git
commit SHA (`ghcr.io/<owner>/<repo>-app:<sha>`), pushed to GitHub Container
Registry, deployed to staging, verified, and only deployed to production on
a separate, manual `workflow_dispatch` of `deploy-production.yml`, using
the *exact same image tag*. Production never rebuilds from source.

## Pipeline shape (verified against the actual workflow files)

| Workflow file | Trigger | What it does |
|---|---|---|
| `.github/workflows/ci.yml` | `pull_request`, `push` (any branch), `workflow_call` | Config validation (`docker compose config -q` for both `compose.yaml` and `compose.test.yaml`), Docker build validation, application pytest suite, database/migration integration suite. Never deploys anything. |
| `.github/workflows/deploy-staging.yml` | `push` to `staging` | Calls `ci.yml`, builds+pushes the immutable image, deploys via SSH (`scripts/release/deploy_release.sh`), runs post-deploy verification (`scripts/release/post_deploy_verify.sh`). |
| `.github/workflows/deploy-production.yml` | `workflow_dispatch` only, inputs `image_tag` + `release_git_sha` | Deploys a pre-built image tag already proven in staging. Its file comment still reads *"NEVER automatically triggered"* (accurate) *"and has NOT been executed"* — the latter is now **out of date**: it was first run 2026-08-29 (run `33239331538`, promoting `49df53f`; see [25-change-history.md](25-change-history.md)) and again 2026-08-30 (run `33304784449`, promoting migrations 216–222). Still never auto-triggered. |
| `.github/workflows/rollback.yml` | `workflow_dispatch` only | Redeploys a previously-built image tag to `staging` or `production` via the identical deploy path. |

## CI gates (from `ci.yml`, verified against the file)

1. `config-validation` — validates `compose.yaml` and `compose.test.yaml`
   using CI-only placeholder env files (never real credentials; the job's
   own comment explains why placeholders are required even though the
   values aren't used at validation time).
2. `docker-build-validate` — builds `app/Dockerfile`, not pushed.
3. `app-tests` — builds `app/Dockerfile.test`, runs the existing pytest suite.
4. `database-integration-tests` — `scripts/test/run_integration_environment.sh`
   against a disposable database.

Live MQTT smoke tests (`scripts/verify/smoke_mqtt_energy.sh`,
`smoke_mqtt_environment.sh`) are intentionally **not** run in CI — they
publish real synthetic telemetry to a real broker and are opt-in only
(`RUN_LIVE_MQTT_SMOKE=true`).

## Production authorization model

Per `docs/operations/CICD_PIPELINE.md`: the `production` GitHub Environment
exists as a secrets/variables namespace only, **not** a required-reviewer
approval gate — required reviewers on a private repository require GitHub
Enterprise, which this project does not have. Authorization is procedural:
only the repository owner has dispatch access, and the operator must only
ever dispatch an `image_tag`/`release_git_sha` pair matching a known-good
entry in `.deploy-history/staging.log`. Full procedure:
`docs/operations/FIRST_PRODUCTION_DEPLOYMENT_ROLLBACK_RUNBOOK.md`.

## Rollback

Application rollback is implemented (`rollback.yml` — redeploys an older,
previously-pushed image tag via the same deploy path). **Database rollback
is an explicit, by-design limitation**: the migration system
(`scripts/apply_migrations.sh`) is forward-only, checksum-verified, with no
reverse-migration mechanism. Undoing a migration requires writing a new
forward migration that reverses its effect, or a database restore. This is
stated as a deliberate choice (an incorrect reverse migration is considered
more dangerous than no rollback mechanism), not an oversight.

## Historical finding, and what has changed since

**Historical finding** (`docs/operations/CICD_PIPELINE.md`, written when
staging had zero commissioned sites/gateways/devices): the post-deploy
verification script's advisory (non-blocking) tier,
`scripts/verify/verify_pipeline.sh`, reported real FAILs for
`normalized_points`/`energy_measurements`/`environment_measurements` being
empty — documented at the time as "an environment commissioning gap...
not a deployment defect."

**Current state** (this session, verified 2026-08-24): staging now has a
fully commissioned organization (Meenaxy Pharma, 22 devices/22 assets)
producing live telemetry, confirmed flowing through raw ingestion,
normalization, 1-minute/15-minute/hourly aggregation, and the
Grafana-facing semantic views, with sub-2-minute freshness at verification
time.

**Resolution**: the commissioning gap that caused those specific advisory
FAILs is resolved for at least this one organization — `verify_pipeline.sh`
would be expected to now show real data for Meenaxy Pharma's rows.
This does **not** confirm the underlying `verify_jobs.sh` finding in the
same document (job schedule/overlap drift: `run_normalization_job`
canonically configured for 1min/15min-overlap but observed running at
5min/20min-overlap, per that document) has been fixed — this session did
not inspect `timescaledb_information.jobs` schedule configuration directly,
only confirmed that aggregation data is, in fact, current and flowing.
Treat the job-schedule-drift finding as **unresolved** until independently
re-checked — see [23-known-issues-and-drift.md](23-known-issues-and-drift.md).

## What this manual did not verify

Whether `deploy-production.yml` or `rollback.yml` have ever actually been
executed against a real host (per the CI/CD document itself: "created but
never executed"), and the current state of GitHub-side configuration
(environments, secrets, branch protection) — none of this is inspectable
from repository files or database access alone.
