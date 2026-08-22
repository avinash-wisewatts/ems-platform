# EMS CI/CD Delivery Pipeline

This document describes the CI/CD architecture implemented for the EMS
platform: what runs automatically, what a human must still configure on the
GitHub side, and exactly what is (and is not) true about production.

Production has **not** been touched, deployed to, or verified as part of
this implementation. The `deploy-production.yml` and `rollback.yml`
workflows are architecture only until a human explicitly runs them.

## Principle

```
BUILD ONCE  ->  TEST  ->  PROMOTE THE SAME ARTIFACT
```

One application image is built per commit pushed to `staging`, tagged
immutably with its Git commit SHA, pushed to a registry, deployed to
staging, verified, and -- only on separate, manual, approved invocation --
the *exact same image tag* is deployed to production. Production never
rebuilds from source independently.

## Pipeline shape

```
development/feature branch
        |
        v
   Pull Request  ---------------------------> .github/workflows/ci.yml
        |                                     (config validation, docker
        |                                      build validation, app
        |                                      pytest suite, disposable-DB
        |                                      integration + migration
        |                                      suite)
        v
   merge to staging
        |
        v
.github/workflows/deploy-staging.yml
        |
        +--> job: ci                  (calls ci.yml via workflow_call --
        |                              same gates as PRs, must pass)
        |
        +--> job: build-and-push      (docker build ./app, tag
        |                              ghcr.io/<repo>-app:<git-sha>, push)
        |
        +--> job: deploy-staging      (SSH -> scripts/release/deploy_release.sh:
        |                              checkout exact SHA, validate config,
        |                              pull exact image, apply migrations,
        |                              `docker compose up -d --no-build
        |                              admin-portal live-telemetry`,
        |                              wait for Docker healthchecks)
        |
        +--> job: verify-staging      (SSH -> scripts/release/post_deploy_verify.sh)
        v
   staging verified
        |
        v
  deliberate operator dispatch        (production Environment exists as a
        |                              configuration namespace only -- NOT
        |                              a reviewer gate. GitHub Free does
        |                              not support required reviewers for
        |                              a private repository. Authorization
        |                              is procedural: only the repository
        |                              owner can dispatch, and image_tag /
        |                              release_git_sha must be copied from
        |                              a known-good entry in
        |                              .deploy-history/staging.log -- see
        |                              docs/operations/FIRST_PRODUCTION_
        |                              DEPLOYMENT_ROLLBACK_RUNBOOK.md)
        v
.github/workflows/deploy-production.yml   (workflow_dispatch only; takes
        |                                  the exact image_tag proven in
        |                                  staging as input; never builds)
        v
   production verification            (scripts/release/post_deploy_verify.sh
                                        run against production)
```

Rollback (`rollback.yml`) reuses the identical deploy path against an older,
previously-pushed image tag -- a rollback *is* a deployment, just of an
older artifact.

## What each workflow file does

| File | Trigger | What it does |
|---|---|---|
| `.github/workflows/ci.yml` | `pull_request`, `push` (any branch), and `workflow_call` | Runs all automated gates. Never deploys anything. |
| `.github/workflows/deploy-staging.yml` | `push` to `staging` | Calls `ci.yml`, then builds+pushes the immutable image, then deploys it to staging, then runs post-deploy verification. |
| `.github/workflows/deploy-production.yml` | `workflow_dispatch` only | Takes a proven `image_tag` + `release_git_sha` as input. Authorization is procedural, not GitHub-enforced: only the repository owner can dispatch this workflow, and `image_tag`/`release_git_sha` must correspond to a known staging release recorded in `.deploy-history/staging.log`. **Never executed as part of this task.** |
| `.github/workflows/rollback.yml` | `workflow_dispatch` only | Redeploys a chosen previous `image_tag` to `staging` or `production`. **Never executed as part of this task.** |

## CI gates (what actually runs, and why each one uses existing tooling)

No new test framework was introduced. Every gate below wraps an existing,
already-authored script or Makefile target:

1. **Configuration validation** -- `docker compose -f compose.yaml config -q`
   and `docker compose -f compose.test.yaml config -q`. Catches YAML/
   interpolation errors before anything is built.
2. **Docker build validation** -- `docker build --file app/Dockerfile ./app`.
   Confirms the application image still builds cleanly. Not pushed anywhere.
3. **Application test suite** -- builds `app/Dockerfile.test` and runs it,
   exactly matching the existing `make test-app-build` / `make test-app`
   targets. These are the repository's existing pytest unit/contract tests
   (139 files under `app/tests`); `app/tests/conftest.py` explicitly
   documents that no live database connection is opened by these tests.
4. **Database / migration / repository integration tests** --
   `./scripts/test/run_integration_environment.sh`, exactly matching
   `make test-db`. This already: builds a disposable Postgres/TimescaleDB
   container from `compose.test.yaml`, deploys the canonical schema,
   baselines historical migrations and applies forward migrations via the
   same checksum-verified `scripts/apply_migrations.sh` mechanism used in
   production, and runs 13 `scripts/test/assert_*.sh` suites plus a
   migration-ledger existence check. This is simultaneously the
   "database/integration tests," "repository verification tests," and
   "migration validation" requirement -- one existing tool already covers
   all three.

Live MQTT smoke tests (`scripts/verify/smoke_mqtt_energy.sh`,
`smoke_mqtt_environment.sh`) are **not** run in CI. They publish real
synthetic telemetry to a real broker and are intentionally opt-in
(`RUN_LIVE_MQTT_SMOKE=true`) -- wiring them into an unattended pipeline
without a dedicated, explicitly-authorized broker/credential context would
violate their own documented safety design.

## Post-deployment verification -- required vs. advisory

`scripts/release/post_deploy_verify.sh` runs after every deployment (staging
and, when it is eventually run, production). It splits the existing
`scripts/verify/*.sh` suites into two tiers:

**Required (fails the pipeline):**
- `verify_database.sh` -- schema/hypertable/extension structure. Currently
  passes cleanly.
- `verify_metadata.sh` -- referential integrity of commissioning tables
  (foreign keys, orphan detection). Currently passes cleanly; zero
  sites/devices is reported there as a WARN, not a FAIL, since integrity and
  commissioning-completeness are different questions.

**Advisory (reported in full, never blocks the pipeline):**
- `verify_pipeline.sh` -- currently reports real, expected FAILs for
  `normalized_points`/`energy_measurements`/`environment_measurements` being
  empty, because staging has zero commissioned sites/gateways/devices
  (organizations exist; nothing below them does). This is an environment
  commissioning gap, explicitly out of scope for this task, not a deployment
  defect -- raw MQTT ingestion itself (`telemetry.raw_messages`) passes.
- `verify_jobs.sh` -- currently reports 4 real FAILs: see "Known findings"
  below.

This split exists so that a real, currently-known, out-of-scope condition
does not make every future staging deployment look broken, while still
surfacing it in full on every run so nobody has to rediscover it.

Verified locally (read-only, no changes made to the database) at the time
of this implementation:

```
$ ./scripts/release/post_deploy_verify.sh
...
POST-DEPLOY VERIFICATION: REQUIRED GATES PASSED
$ echo $?
0
```

## Known findings surfaced (not fixed) by this work

### 1. `verify_pipeline.sh` had a stale config key -- FIXED

The script read `get_config_value MQTT_STAGING_TABLE`, but
`scripts/verify/config/pipeline.conf` only ever defined
`MQTT_ADAPTER_VIEW`. `MQTT_STAGING_TABLE` appears nowhere else in the
repository; `MQTT_ADAPTER_VIEW` is the only key ever defined and is the
semantically correct name (`public.mqtt_staging` is documented repository-
wide, including `postgres/init/README.md`, as an INSERT-only *adapter view*,
never a table). This was a genuine stale reference, not intended
architecture, and has been corrected.

A second, related bug was found and fixed in the same script: several row-
count/"latest message" checks queried `public.mqtt_staging` directly for
evidence of receipt. That view's actual definition is:

```sql
SELECT NULL::timestamptz AS received_at, NULL::jsonb AS tags, NULL::jsonb AS fields
WHERE false;
```

It is a write-only `INSTEAD OF INSERT` adapter with no underlying storage --
it always returns zero rows by design (this is explicitly documented:
"Never query `public.mqtt_staging` to confirm receipt; it intentionally
returns no retained rows"). The config file already defined
`RAW_MESSAGES_TABLE=telemetry.raw_messages` for exactly this purpose, but
the script never read that key. `verify_pipeline.sh` now loads
`RAW_MESSAGES_TABLE` and uses it for every row-level receipt/freshness/
checkpoint-lag check; `MQTT_ADAPTER_VIEW` remains used only for the
column-type/schema contract check, which is what it was always correct for.

Confirmed after the fix, against live staging data (read-only):
`raw_messages contains 5,887 messages`, `Latest MQTT ingestion age: 8
seconds` -- both now PASS correctly instead of the previous, wrong,
permanent FAIL.

### 2. `verify_jobs.sh` vs. the running TimescaleDB job schedule -- NOT fixed (real drift, requires separate remediation)

Investigated per instructions: does not guess, traced to the authoritative
source.

The canonical job-registration files that `scripts/deploy_database.sh`
treats as the authoritative "jobs" category for a clean install --
`postgres/jobs/42_normalization_background_job.sql`,
`48_energy_background_job.sql`, `69_environment_routing_job.sql` -- each
explicitly register their job with `schedule_interval => INTERVAL '1
minute'`, `config => {"overlap": "15 minutes"}`, `max_runtime => INTERVAL
'5 minutes'`, `max_retries => 3`, `retry_period => INTERVAL '1 minute'`.
This exactly matches every hardcoded expectation in `verify_jobs.sh`.

The **currently running** jobs on staging do not match this:

| Job | Canonical (intended) | Currently running |
|---|---|---|
| `run_normalization_job` | 1 min / 15 min overlap | **5 min / 20 min overlap** |
| `run_energy_routing_job` | 1 min / 15 min overlap | 1 min / **1 min overlap** |
| `run_environment_routing_job` | 1 min / 15 min overlap | 1 min / **1 min overlap** |

**Conclusion: `verify_jobs.sh` is correct. The running staging database's
job configuration has drifted from the repository's own canonical
definition.** This is a real, evidenced defect -- not a stale test. Per this
task's explicit scope (no PostgreSQL modification, no fixing unrelated
issues discovered during CI/CD work), it has **not** been corrected here.
`verify_jobs.sh` has been left unchanged (it needs no change), and this
finding is surfaced as an advisory (non-blocking) check on every deployment
so it stays visible until it is remediated as its own piece of work --
likely by re-running the relevant `alter_job` calls from the three
`postgres/jobs/*.sql` files against staging, under its own change control.

## Artifact / image strategy

| Component | Strategy |
|---|---|
| `admin-portal`, `live-telemetry` | **One** application image, built from `app/Dockerfile` (identical for both services; they differ only in the `command:` compose runs). Built once in `build-and-push`, tagged `ghcr.io/<owner>/<repo>-app:<git-sha>`, pushed to GHCR, and that exact tag is what staging (and later, production) deploys. `compose.yaml` still keeps a `build:` block on both services purely so local `docker compose build` continues to work for development -- deployment scripts always pass `--no-build` and set `APP_IMAGE` explicitly. |
| `timescale/timescaledb` | Was `latest-pg16` (floating). **Pinned by digest** to `sha256:289d55704b1b3ee8263cd3805c6930f9cd54506835a8f19f9b85dad17d5c5a8a` -- the exact image already running and verified healthy on staging (PostgreSQL 16.15, TimescaleDB extension 2.29.2, confirmed via `docker inspect` / `verify_database.sh`). This is a pin to the known-good running image, not an upgrade; changing it now requires a deliberate repository change and re-verification instead of silently floating on the next `docker pull`. |
| `grafana/grafana-oss` | Already explicitly pinned to `11.6.0`. Left untouched. |
| `telegraf` | Already pinned to `1.36`. Left untouched (explicitly out of scope -- "do not revert the working Telegraf configuration"). |

No image registry existed before this work. **GitHub Container Registry
(`ghcr.io`)** was chosen because it requires zero new secrets to push from
CI (the built-in `GITHUB_TOKEN` is sufficient with `permissions:
packages: write`), and needs only a read-scoped credential on the deploy
host to pull. See "Secrets required" below for the pull-side credential.

## Migration integration

`scripts/apply_migrations.sh` is unchanged and remains authoritative. It is
now an explicit, ordered stage in `scripts/release/deploy_release.sh`,
invoked **after** pulling the new image and **before** deploying it, so
schema changes are always in place before new application code that might
depend on them starts. It execs into the already-running `timescaledb`
container -- it never restarts or recreates it.

Migrations are forward-only (this is by the existing system's own design --
checksum-verified, `ON_ERROR_STOP`, one transaction per migration). No
reverse-migration tooling has been invented. See "Rollback strategy" below
for what this means honestly.

## Compose design changes

- `timescaledb` image pinned by digest (see above). Storage path is
  environment-specific, controlled by `TIMESCALEDB_DATA_PATH`:
  `volumes: - ${TIMESCALEDB_DATA_PATH:-./postgres/data/pgdata}:/var/lib/postgresql/data`.
  Staging uses the default (`./postgres/data/pgdata`); production overrides it
  via its host-local, untracked `.env` (`TIMESCALEDB_DATA_PATH=./postgres/data`)
  to match its existing on-disk data layout exactly, since production's
  TimescaleDB predates this pipeline and already had live data at that path.
  Application deployment (`deploy_release.sh`) never names `timescaledb` as a
  target service and therefore never recreates it -- this parameterization
  only matters if the service is ever explicitly (re)created, where it
  prevents accidentally pointing at the wrong data directory.
- `admin-portal` and `live-telemetry` now declare
  `image: ${APP_IMAGE:-ems-platform-prod-app:local}` alongside their
  existing `build:` block, so the same file supports both "build locally
  for dev" and "run an exact pulled tag for staging/production" without
  duplication.
- No other service, volume, network, or healthcheck definition was changed.
  `docker compose -f compose.yaml config -q` and
  `docker compose -f compose.test.yaml config -q` both validate cleanly
  after these edits.
- `admin-portal` and `grafana` host bind addresses are environment-specific,
  following the same pattern as `TIMESCALEDB_DATA_PATH` above:
  `ports: - "${ADMIN_PORTAL_BIND_HOST:-127.0.0.1}:8080:8080"` and
  `ports: - "${GRAFANA_BIND_HOST:-127.0.0.1}:3000:3000"`. Since `compose.yaml`
  is the single shared file promoted unchanged from staging to production,
  both default safely to `127.0.0.1` -- a host that never sets these
  variables stays localhost-only. Staging may explicitly set
  `ADMIN_PORTAL_BIND_HOST=0.0.0.0` and `GRAFANA_BIND_HOST=0.0.0.0` in its
  own host-local, untracked root `.env` when direct host access is
  intentionally required; production should retain the safe localhost
  defaults unless a deliberate production exposure architecture (e.g. a
  reverse proxy with TLS and authentication) is introduced. As with
  `TIMESCALEDB_DATA_PATH`, this does not affect the immutable-artifact
  promotion model: the bind-address values are host-local configuration,
  never embedded in the application image or in the Git-promoted artifact.

## Rollback strategy

**Application rollback** (implemented): `rollback.yml` redeploys a
previously-built, previously-pushed immutable image tag via the same
`deploy_release.sh` path used for forward deployment. Any past commit SHA
that CI built for the deployed branch is a valid target -- GHCR never
overwrites a SHA-tagged image. Every deployment also appends one line
(timestamp, environment, git SHA, image) to
`<PROJECT_PATH>/.deploy-history/<environment>.log` on the target host for
local operator reference, and the GitHub Actions run history for every
deploy/rollback workflow run records exactly which `image_tag` was used.

**Database rollback (honest limitation, by design, not an oversight):** the
existing migration system is forward-only. There is no reverse-migration
mechanism in this repository, and this task deliberately does not invent
one -- an incorrectly-written reverse migration is more dangerous than no
rollback at all. If a deployed migration needs to be undone, that requires
a new forward migration that reverses its effect, written and reviewed like
any other schema change, or a database restore from backup. Application
rollback should therefore be aimed at a **schema-compatible** previous
image tag -- i.e., roll back to the most recent tag that was deployed
*before* the migration you need to undo was applied, not an arbitrarily old
one, since a very old application version may not tolerate the current
(newer) schema.

## GitHub-side configuration still required

This cannot be completed from repository files; it requires GitHub
repository/organization admin access.

1. **Create two GitHub Environments**: `staging` and `production`
   (Settings -> Environments). **Done** -- both exist.
2. On the **`production`** environment: **Required reviewers are not
   available.** This repository is private, on a personal GitHub Free
   account. GitHub's own documentation states required reviewers (and wait
   timers) are only available for public repositories on Free, Pro, and
   Team plans -- required reviewers on a private repository require GitHub
   Enterprise, which is disproportionate for this project's current
   single-owner scale. The `production` environment therefore exists as a
   configuration namespace (secrets, variables) only, not an approval gate.
   Authorization is instead procedural: (a) only the repository owner has
   write/dispatch access to trigger `deploy-production.yml` or
   `rollback.yml` at all, and (b) the operator must only ever dispatch an
   `image_tag`/`release_git_sha` pair matching a known-good entry in
   `.deploy-history/staging.log`. See
   `docs/operations/FIRST_PRODUCTION_DEPLOYMENT_ROLLBACK_RUNBOOK.md` for
   the full procedure, the release-pairing convention, and the manual
   rollback plan for the first deployment. Revisit this decision if the
   team or budget grows to where GitHub Enterprise becomes proportionate.
3. On the **`staging`** environment: no required reviewers are strictly
   necessary (staging deploys automatically on push, matching the existing
   trigger) -- and, per the same plan limitation, none are available here
   either. **Deployment branch rules** restricting it to the `staging`
   branch are visible as an option in the environment UI even on GitHub
   Free, though GitHub's documentation describes this as a Pro/Team feature
   for private repositories -- this was not empirically confirmed to
   actually enforce on the current plan, so verify its real effect before
   relying on it.
4. Confirm (or enable) **branch protection** on `staging` requiring the
   `CI gates` check (from `ci.yml`, called via `deploy-staging.yml`'s `ci`
   job) to pass before merge, if pushes to `staging` normally arrive via PR
   merge rather than direct push. This was not previously configured or
   verifiable from repository files alone.
5. Confirm the repository's **Packages** visibility/permissions allow the
   deploy host to pull `ghcr.io/<owner>/<repo>-app` images (public package,
   or a PAT with `read:packages` -- see secrets below).

## Secrets required

Reusing the existing naming convention from the current
`deploy-staging.yml` (`STAGING_HOST`, `STAGING_USER`, `STAGING_SSH_KEY`,
`STAGING_PROJECT_PATH`), which already exist and are unchanged:

| Secret | Environment | Status | Purpose |
|---|---|---|---|
| `STAGING_HOST` | staging | Already exists | SSH target for staging deploys |
| `STAGING_USER` | staging | Already exists | SSH user |
| `STAGING_SSH_KEY` | staging | Already exists | SSH private key |
| `STAGING_PROJECT_PATH` | staging | Already exists | Repository checkout path on the staging host |
| `PRODUCTION_HOST` | production | **New -- required before `deploy-production.yml` can ever run** | SSH target for production |
| `PRODUCTION_USER` | production | **New** | SSH user |
| `PRODUCTION_SSH_KEY` | production | **New** | SSH private key |
| `PRODUCTION_PROJECT_PATH` | production | **New** | Repository checkout path on the production host |
| `REGISTRY_USERNAME` | staging, production (optional) | **New, optional** | Overrides the default GHCR pull credential (`github.actor` / `GITHUB_TOKEN`) on the deploy host, e.g. with a long-lived PAT if that is preferred |
| `REGISTRY_PASSWORD` | staging, production (optional) | **New, optional** | Paired with `REGISTRY_USERNAME` |

None of these were set, viewed, or guessed as part of this task. No secret
value has been printed to any log.

## Production access still required

The following remain genuinely unknown/unverifiable without explicit,
separately-authorized production access, and nothing in this
implementation assumes an answer to any of them:

- Whether a production host, matching the `PRODUCTION_*` secret shape
  above, exists at all yet.
- Production's current Git commit/version, container image versions,
  PostgreSQL/TimescaleDB version, migration ledger state, and Grafana
  version/configuration.
- Whether production's `compose.yaml` (if one is deployed there) matches
  this repository's `compose.yaml` at all.
- Network reachability from a GitHub Actions runner (or a self-hosted
  runner, if one is required) to the production host.

**Staging/production parity remains explicitly UNVERIFIED.** That
comparison is a separate, controlled phase requiring read-only production
access, as stated in the task scope for this work.

## Known limitations

- `deploy-production.yml` and `rollback.yml` have been created but never
  executed. Their correctness is verified so far only by YAML validation
  and manual review against the same patterns proven in
  `deploy-staging.yml` -- they have not been exercised end-to-end against a
  real host.
- The GHCR pull-credential default (`github.actor` / `GITHUB_TOKEN`) works
  for a workflow-triggered SSH session but has not been tested against an
  actual deploy host's `docker login`; if the target host cannot reach
  `ghcr.io` or the package visibility blocks it, `REGISTRY_USERNAME`/
  `REGISTRY_PASSWORD` secrets should be set explicitly.
- `verify_jobs.sh`'s 4 known FAILs (job schedule/overlap drift) remain
  unresolved by design -- see "Known findings" above.
- `verify_pipeline.sh`'s normalization/energy/environment FAILs remain
  expected and unresolved by design until staging is commissioned (a
  separate task).
- No GitHub branch protection or required-status-check configuration could
  be inspected or changed from repository files; see "GitHub-side
  configuration still required" above.
