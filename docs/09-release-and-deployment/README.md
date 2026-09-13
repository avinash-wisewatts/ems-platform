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
| [rollback.md](rollback.md) | Application rollback (implemented) vs. database rollback (deliberately not implemented). |
