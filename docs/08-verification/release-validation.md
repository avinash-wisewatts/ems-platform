# Release Validation

Status: CURRENT · Last reviewed: 2026-08-30 · Owner: Engineering
Full process detail: [../09-release-and-deployment/ci-cd.md](../09-release-and-deployment/ci-cd.md)

## Post-deploy verification (staging)

`scripts/release/post_deploy_verify.sh` runs after every staging deploy,
including `scripts/verify/verify_database.sh` (asserts effective
`max_connections >= 50` and non-superuser usable slots `>= 45` — a gate
that specifically fails until a required one-time container recreate is
done, then passes) and the advisory-tier `scripts/verify/verify_pipeline.sh`/
`verify_jobs.sh`.

## Post-deploy verification (production)

`deploy-production.yml`'s downstream `verify-production` job runs the
equivalent REQUIRED gates before a promotion is considered complete. Recent
example: run `33304784449` (2026-08-30) promoting migrations 216–222 —
`validate-promotion`, deploy-over-SSH, and REQUIRED post-deployment gates
all passed; see
[../10-operations/incident-history.md](../10-operations/incident-history.md).

## Numerical parity gates (energy-specific)

Any change touching energy routing or semantics requires a numerical-parity
and performance gate before cutover (DDS roadmap Phase 4's energy
sub-phase, Phase 10, Phase 17) — see
[../04-architecture/system-architecture.md](../04-architecture/system-architecture.md).
Recent example: migration 221's staging bounded-window (1m/5m/15m/2h)
performance/equivalence gate — executed, PASSED, with an exact-digest
equivalence re-run (zero added/removed/changed keys). See
[../06-platform/telemetry/pipeline.md](../06-platform/telemetry/pipeline.md).

## What "released" does not mean

A migration or feature landing on `origin/staging` is not, by itself, a
release-validation record — see [staging-validation.md](staging-validation.md)
for what a specific, dated validation pass actually checked (and did not
check) for the MVP-3 deployment, as the standing example of the discipline
this document expects for every future release.
