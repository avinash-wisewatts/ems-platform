# Release Process

Status: CURRENT · Last reviewed: 2026-08-30 · Owner: Engineering
Full detail: [ci-cd.md](ci-cd.md), `docs/operations/CICD_PIPELINE.md` (kept in place)

## Staging → production promotion

1. A commit is pushed to `staging`; `deploy-staging.yml` builds, tags
   (`ghcr.io/<owner>/<repo>-app:<sha>`), and deploys it to staging
   automatically.
2. Post-deploy verification runs on staging — see
   [../08-verification/release-validation.md](../08-verification/release-validation.md).
3. Once staging is validated (numerical parity where applicable, contract
   tests, manual review), the repository owner manually dispatches
   `deploy-production.yml` with the **exact** `image_tag`/`release_git_sha`
   pair already proven on staging — never a rebuild, never a different
   commit.
4. `verify-production`'s REQUIRED gates must pass before the promotion is
   considered complete.

## Recent example (migrations 216–222, 2026-08-30)

`deploy-production.yml` run `33304784449` promoted the batch:
`validate-promotion`, deploy-over-SSH (1m21s), and the downstream
`verify-production` REQUIRED gates all passed. All seven migrations are
recorded `application_mode=applied` in `admin.schema_migrations` with
checksums byte-identical to the staging-validated values. See
[../10-operations/incident-history.md](../10-operations/incident-history.md)
for the full production-promotion and Job 1000 recovery record.

## Current plan (migrations 266–301, proposed 2026-10-14)

Production is at migration 265 (`9ca461e`). The proposed path to staging's
301 is three `staging-milestone` releases (A `f06683d`, B `ba2cb4b`,
C `b1c8b09`), all blocked first on the 1h backfill required by migration 266.
See [production-release-plan-266-301.md](production-release-plan-266-301.md).
Nothing in it is approved yet.

## Every phase requires its own explicit approval

Per project instructions and the DDS implementation roadmap: no phase of
platform work is authorized to touch staging or production merely because
a prior phase was approved. Each requires its own explicit approval before
any staging or production change.
