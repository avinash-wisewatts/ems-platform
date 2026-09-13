# 08 — Verification

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Engineering

Canonical source for **how we know it works.** Evidence, not aspiration —
every claim here is either a specific test-suite result, a specific staging
observation, or an explicitly stated limitation.

| Document | Purpose |
|---|---|
| [test-strategy.md](test-strategy.md) | The layered testing approach used across the platform and the frontend. |
| [requirements-validation.md](requirements-validation.md) | Where to find the live-verified build status of every requirement. |
| [staging-validation.md](staging-validation.md) | The MVP-3 staging validation record: what was checked, the verdict, and its explicitly-scoped limitations. |
| [release-validation.md](release-validation.md) | What CI/CD and post-deploy gates check before and after a release. |

## Principle

A screen or capability is not "validated" because its code merged — it's
validated when there's a specific, dated record of what was checked, by
what method, with what result, including what was **not** checked. See
[staging-validation.md](staging-validation.md) for the standing example of
this discipline: it explicitly separates what was verified from what was
not (browser behavior, historical Healthy/Attention behavior over time),
rather than implying full coverage.
