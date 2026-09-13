# 99 — Archive

Status: HISTORICAL · Last reviewed: 2026-09-13 · Owner: Engineering

This directory preserves documentation that has been **superseded by the
canonical structure** in [../](../) but is kept intact — never deleted —
per [../00-governance/documentation-governance.md](../00-governance/documentation-governance.md).
Nothing in this directory is retroactively edited to fit the new structure;
each document retains its original character, including its own dates,
version numbers, and evidence-labelling conventions.

**Do not treat anything here as current.** Cross-check against the
canonical directories (00–10) and, where relevant, live repository/staging
state before relying on any claim in an archived document — see
[../00-governance/source-of-truth.md](../00-governance/source-of-truth.md).

| Directory | Contents |
|---|---|
| [superseded-product/](superseded-product/README.md) | The original `docs/product/` v0.1/v0.2 document set — product definition, requirements, information architecture, product architecture, roadmap, traceability, and the Product Owner Workshop baseline (Q1–Q101). |
| [historical-implementation/](historical-implementation/README.md) | The original `docs/platform-manual/` (29 chapters + reference catalogs), the full `Audit/` investigation collection (46 documents), and one resolved documentation duplicate. |
| [historical-decisions/](historical-decisions/README.md) | The frozen DDS architecture's own red-team review and ten-scenario stress test — the evidentiary record of *why* the frozen model looks the way it does. |

## Where things moved

| Old location | New canonical location | Archived at |
|---|---|---|
| `docs/product/ems-product-definition.md` | [../01-product/product-definition.md](../01-product/product-definition.md) | [superseded-product/ems-product-definition.md](superseded-product/ems-product-definition.md) |
| `docs/product/ems-customer-requirements.md` | [../02-requirements/functional-requirements.md](../02-requirements/functional-requirements.md), [non-functional-requirements.md](../02-requirements/non-functional-requirements.md), [scope-and-deferred-functionality.md](../02-requirements/scope-and-deferred-functionality.md) | [superseded-product/ems-customer-requirements.md](superseded-product/ems-customer-requirements.md) |
| `docs/product/ems-information-architecture.md` | [../03-ux-and-design/](../03-ux-and-design/) (4 documents) | [superseded-product/ems-information-architecture.md](superseded-product/ems-information-architecture.md) |
| `docs/product/ems-product-architecture.md` | [../04-architecture/application-architecture.md](../04-architecture/application-architecture.md), [api-architecture.md](../04-architecture/api-architecture.md) | [superseded-product/ems-product-architecture.md](superseded-product/ems-product-architecture.md) |
| `docs/product/ems-product-roadmap.md` | [../01-product/roadmap.md](../01-product/roadmap.md) | [superseded-product/ems-product-roadmap.md](superseded-product/ems-product-roadmap.md) |
| `docs/product/ems-requirements-traceability.md` | [../02-requirements/requirements-traceability.md](../02-requirements/requirements-traceability.md) | [superseded-product/ems-requirements-traceability.md](superseded-product/ems-requirements-traceability.md) |
| `docs/product/ems-product-owner-workshop-baseline.md` | Extracted into [../00-governance/decisions/](../00-governance/decisions/) ADR-001–005, 009–013 | [superseded-product/ems-product-owner-workshop-baseline.md](superseded-product/ems-product-owner-workshop-baseline.md) (preserved verbatim, unedited — the primary decision-evidence source) |
| `docs/product/README.md` | [../01-product/README.md](../01-product/README.md) | [superseded-product/README.md](superseded-product/README.md) |
| `docs/platform-manual/*` (29 chapters) | [../06-platform/](../06-platform/), [../09-release-and-deployment/](../09-release-and-deployment/), [../10-operations/](../10-operations/), [../04-architecture/security-and-tenancy.md](../04-architecture/security-and-tenancy.md) | [historical-implementation/platform-manual/](historical-implementation/platform-manual/) |
| `Audit/*` (46 files) | Summarized/cited throughout [../06-platform/](../06-platform/), [../10-operations/incident-history.md](../10-operations/incident-history.md); not individually re-triaged by this reorganization | [historical-implementation/audit/](historical-implementation/audit/) |
| `docs/DDS/*-review.md`, `*-stress-test.md` | Conclusions already folded into `docs/DDS/analytics-platform-future-state-architecture.md` (kept in place — see [../00-governance/source-of-truth.md](../00-governance/source-of-truth.md)) | [historical-decisions/](historical-decisions/) |
| `docs/operations/LOCAL_DEVELOPMENT_BOUNDARIES.md` | [../00-governance/local-development-boundaries.md](../00-governance/local-development-boundaries.md) | [historical-implementation/operations/LOCAL_DEVELOPMENT_BOUNDARIES.md](historical-implementation/operations/LOCAL_DEVELOPMENT_BOUNDARIES.md) |
| `docs/database-validation/README.md` | Not superseded — genuinely still-relevant verification evidence, **moved** (not archived) to [../08-verification/database-bootstrap-validation.md](../08-verification/database-bootstrap-validation.md) |

## What was deliberately left where it was

`docs/DDS/analytics-platform-future-state-architecture.md` and its
companion implementation roadmap stay at `docs/DDS/` — referenced by exact
path from migration comments and `postgres/restructure_manifest.csv`. Most
of `docs/operations/` (CI/CD pipeline detail, the production rollback
runbook, the telemetry-pipeline document, and per-migration `README-NNN.md`
operational notes) was evaluated but left in place — this reorganization's
scope was `docs/product/`, `docs/platform-manual/`, `Audit/`, and the two
DDS evidentiary documents, per the original custody commit's inventory, not
a general audit of every pre-existing file under `docs/operations/`. See
[../00-governance/change-history.md](../00-governance/change-history.md).
