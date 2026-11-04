# 09 — Release and Deployment

Status: CURRENT · Last reviewed: 2026-08-30 · Owner: Engineering

Canonical source for **how the platform gets released.** Consolidated from
platform manual chapters 17–18 (archived) and `docs/operations/CICD_PIPELINE.md`
(kept in place — see [ci-cd.md](ci-cd.md)).

| Document | Purpose |
|---|---|
| [environments.md](environments.md) | The six env-file boundaries and why they're split. |
| [ci-cd.md](ci-cd.md) | The build-once/promote-the-same-artifact pipeline. |
| [release-process.md](release-process.md) | The staging → production promotion procedure and authorization model. |
| [deployment-process.md](deployment-process.md) | What `deploy_release.sh` actually does, service by service. |
| [production-release-plan-266-301.md](production-release-plan-266-301.md) | Proposed production releases A/B/C for migrations 266–301: gates, prechecks, stop conditions, open product-owner decisions. |
| [production-release-311-315.md](production-release-311-315.md) | Prepared production release of migrations 311 and 315: expected migrations, exposure query, pre/post checks, 311 risks, image-only rollback with 315 retained. |
| [rollback.md](rollback.md) | Application rollback (implemented) vs. database rollback (deliberately not implemented). |
