# Test Strategy

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Engineering
Source of truth: CI workflow files (`.github/workflows/ci.yml`), DDS implementation roadmap "Testing strategy" section, commit evidence.

## Layered approach (as implemented)

- **Unit**: calculation logic (e.g. Energy Attention's `evaluateEnergyAttention()`),
  mapping/routing decision logic, quality-propagation logic.
- **Database contract**: constraints, tenant isolation, effective-dating
  correctness, relationship-type compatibility — the `scripts/test/assert_*`
  convention. See [../06-platform/database/README.md](../06-platform/database/README.md).
- **Integration**: `scripts/test/run_integration_environment.sh` against a
  disposable database (CI job `database-integration-tests`).
- **Frontend**: component tests, API contract tests, permission tests,
  empty/error/loading state tests, time-range/resolution tests, quality-
  state rendering tests (`npm test` / vitest).
- **Numerical parity**: old vs. new energy analytics, required before any
  Grafana workflow retires (DDS roadmap Phase 10, Phase 17) — see
  [../04-architecture/system-architecture.md](../04-architecture/system-architecture.md).
- **Regression fixtures for known defect classes**: e.g. the Energy
  Attention floating-point boundary fix (commit `e64c1e3`) added two real,
  non-round fixtures verified via direct computation to reproduce the exact
  failure before the fix, alongside genuine ±14.9%/±16% cases proving the
  fix doesn't loosen the threshold itself — see
  [ADR-010](../00-governance/decisions/ADR-010-mvp3-attention-materiality-policy.md).

## CI gates (from `ci.yml`)

1. `config-validation` — validates `compose.yaml`/`compose.test.yaml` with
   CI-only placeholder env files.
2. `docker-build-validate` — builds `app/Dockerfile`, not pushed.
3. `app-tests` — the pytest suite, built via `app/Dockerfile.test`.
4. `database-integration-tests` — `scripts/test/run_integration_environment.sh`.

Live MQTT smoke tests (`scripts/verify/smoke_mqtt_energy.sh`,
`smoke_mqtt_environment.sh`) publish real synthetic telemetry to a real
broker and are deliberately **opt-in only** (`RUN_LIVE_MQTT_SMOKE=true`),
not run in CI by default.

## Reported evidence, by recent commit (illustrative, not exhaustive)

| Commit | Backend | Frontend | Notes |
|---|---|---|---|
| `c299f27` (Slice C) | 1,277 pytest | 112 vitest | typecheck/lint clean |
| `ddbe5a4` — MVP-1 closeout | 10/10 hierarchy contract | 116/116 | typecheck/lint clean |
| `ddbe5a4` — MVP-3 | 74/74 relevant regression | 146/146 (+30 new) | typecheck/lint clean |
| `e64c1e3` — boundary fix | — | 152/152 (+6 new) | typecheck/lint clean |

See [staging-validation.md](staging-validation.md) for the post-deploy
staging check that follows this pre-merge CI evidence.
