# Release strategy: staging-only features and production fixes

Status: PROPOSED (decision needed) · Last reviewed: 2026-10-24
Owner: Product Owner + Engineering · Verification basis: Repository, Staging (read-only), Production (read-only)

## The problem

The Reports export (ADR-014 Amendment 2: PR #145 `4f01764`, PR #146
`257b503`, migration 309) is a temporary data-export tool. It passed staging
acceptance but is **not approved for production**. It is already on the
`staging` branch, which is the only source of production releases.

How releases work today (verified 2026-10-24):

- `deploy-production.yml` releases only a commit on `staging`'s history:
  `staging-head`, or an earlier `staging-milestone`. That commit must have a
  successful `deploy-staging.yml` run, and its image
  `ghcr.io/<repo>-app:<sha>` is what production runs.
- `scripts/release/deploy_release.sh` checks out that commit and runs
  `scripts/apply_migrations.sh`. The runner applies every migration in that
  commit's `postgres/restructure_manifest.csv` that the ledger lacks, in
  manifest order. There is no exclude, target or environment option.
- The application image from `4f01764` onward starts the Reports export worker
  at boot (`EMS_REPORT_EXPORT_WORKER_ENABLED`, default true), which calls
  migration 309's functions.

Consequence: production (`7e3da57`, migration 308) can take **no** later
`staging` commit without also receiving migration 309 and the Reports app.
That covers migration 310 (AirSense backfill), migration 311 (the job 1061
fix) and every future fix. History must not be rewritten, and the workflow
must not be bypassed.

## Options

| | Option | What changes | Pros | Cons / risks |
|---|---|---|---|---|
| A | **Environment-scoped migrations + feature flag** (recommended) | Manifest gains an environment scope column (e.g. `all` / `staging-only`); `apply_migrations.sh` takes `DEPLOY_ENVIRONMENT` and records skipped staging-only migrations in the ledger (`application_mode = 'SKIPPED_ENVIRONMENT'`) so the history stays complete and auditable; 309 marked `staging-only`; production `.env` sets `EMS_REPORT_EXPORT_WORKER_ENABLED=false` and the web hides Reports when the API reports the feature disabled | Keeps the single linear release model; future fixes flow normally; explicit and tested; reversible (flip the scope later) | Changes deployment semantics (CI/CD rule 15): needs review, runner tests, a production precheck that 309-dependent code is disabled; production image still contains dormant Reports code |
| B | **Accept 309's database objects dormant on production** | Release normally; 309 creates its two tables and functions (unused); worker disabled by `.env`; Reports UI hidden | No tooling change; smallest engineering effort | Deploys migration 309 to production, which the Product Owner has not approved; dormant objects and code on production |
| C | **Remove Reports from the main line** | Forward commits remove the Reports app code; a new migration drops 309's objects; staging loses Reports | Production never runs Reports code | 309 itself still executes on production (create, then drop), which is not approved; staging loses a tool in use |
| D | **Production release line** | A release branch cut from `7e3da57` with selected changes, deployed by a new workflow path | Exact control of production content | Bypasses the "released commit was deployed to staging" guarantee unless a second pre-production environment is added; divergence and double maintenance |
| E | **Session-only operator procedures** | Reviewed, generated SQL run in one guarded session (as for the AirSense recovery) | No release at all; works today | Only for data operations; cannot deliver code or procedure changes such as migration 311 |

## Recommendation

- **Now:** use E for the AirSense recovery (session script generated from
  migration 310, PR #151, rehearsed on staging, production dry run done). Keep
  job 1061 paused: its fix (migration 311, PR #152) needs a release.
- **Next:** decide between A and B. A is the supported long-term route if
  Reports must stay off production; it needs a reviewed change to
  `apply_migrations.sh`, the manifest, the release prechecks and the web
  feature gate, with runner tests. B is the shortest path if the Product
  Owner accepts dormant 309 objects on production. C and D are not
  recommended.

Until a decision is made, no production release is possible without
migration 309.

## Related

- [airsense-preserved-payload-recovery.md](airsense-preserved-payload-recovery.md)
- [ADR-014](../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md) (Amendment 2), [07-features/export](../07-features/export/README.md)
- `.github/workflows/deploy-production.yml`, `scripts/release/deploy_release.sh`, `scripts/apply_migrations.sh`
