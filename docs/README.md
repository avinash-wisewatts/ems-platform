# WiseWatts EMS — Documentation

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering

`docs/` is the canonical, version-controlled source of truth for WiseWatts EMS
documentation. It is organized around the software development lifecycle
(SDLC) — from *why* the product exists, through *what* is being built, *how*
it is architected and implemented, *how it is verified*, *how it is
released*, and *how it is operated* — so that someone joining the project can
trace a straight line from product intent to running system, and find the
rationale behind a decision without having to ask.

This structure was established 2026-09-13 by a documentation reorganization
that consolidated material previously scattered across `docs/platform-manual/`,
`docs/product/`, `Audit/`, and several standalone files. **No product,
architecture, or historical decision was altered, reinterpreted, or silently
resolved during that reorganization** — see
[00-governance/change-history.md](00-governance/change-history.md) for
exactly what moved where, and [99-archive/](99-archive/) for every original
document, preserved intact.

## How the SDLC structure works

| # | Directory | Answers | Canonical for |
|---|---|---|---|
| 00 | [governance/](00-governance/) | Why was this decided? What are the documentation rules? | Decision records (ADRs), source-of-truth rules, documentation governance, change history |
| 01 | [product/](01-product/) | What is EMS? Who is it for? Why does it exist? | Product vision, definition, roadmap, terminology |
| 02 | [requirements/](02-requirements/) | What capabilities are required, at what priority? | Functional/non-functional requirements, traceability, deferred scope |
| 03 | [ux-and-design/](03-ux-and-design/) | What screens exist? How does the customer experience it? | Information architecture, navigation, user journeys |
| 04 | [architecture/](04-architecture/) | How is the system architected? | System/application/data/API architecture, security & tenancy |
| 05 | [applications/](05-applications/) | What applications exist? | EMS Web App, Admin Portal, Analytics API — purpose and boundaries |
| 06 | [platform/](06-platform/) | How does telemetry flow? How is the platform built? | Telemetry pipeline, database, Grafana, MQTT/Telegraf, deployment topology |
| 07 | [features/](07-features/) | How does a specific capability work end-to-end? | Hierarchy, Energy, Demand, Power Quality, Site Overview, Attention |
| 08 | [verification/](08-verification/) | How do we know it works? | Test strategy, requirements validation, staging/release validation evidence |
| 09 | [release-and-deployment/](09-release-and-deployment/) | How does it get released? | Environments, CI/CD, release process, rollback |
| 10 | [operations/](10-operations/) | How is it operated day to day? | Diagnostics, backup/recovery, troubleshooting, incident history |
| 99 | [archive/](99-archive/) | What is historical, not current? | Superseded documents, preserved verbatim |

Implementation detail (exact schema, exact query, exact config value) is
**not** duplicated into Markdown here — source code, `postgres/migrations/`,
`postgres/ddl/`, Grafana provisioning, and CI/CD workflow files remain
authoritative for those facts. Documentation explains and links to them; it
does not repeat them and risk drifting from them. See
[00-governance/source-of-truth.md](00-governance/source-of-truth.md).

## Where to start

- **New to the project?** Read [01-product/product-definition.md](01-product/product-definition.md), then this table.
- **Product owner / business stakeholder?** [01-product/](01-product/) → [02-requirements/](02-requirements/) → [00-governance/decisions/](00-governance/decisions/) for why things were decided.
- **Engineer / architect?** [04-architecture/](04-architecture/) → [06-platform/](06-platform/) → [02-requirements/requirements-traceability.md](02-requirements/requirements-traceability.md).
- **Working on a specific feature (Energy, Demand, Site Overview, ...)?** [07-features/](07-features/) links purpose → requirements → UX → architecture → validation → release status for that feature.
- **Deploying or operating the platform?** [09-release-and-deployment/](09-release-and-deployment/) and [10-operations/](10-operations/).
- **Looking for something that used to be under `docs/platform-manual/` or `docs/product/`?** Those directories were consolidated into the structure above; their original content is preserved at [99-archive/](99-archive/), and [00-governance/change-history.md](00-governance/change-history.md) maps old file → new location.

## Source-of-truth rules (summary)

1. **Code, schema, and configuration are authoritative for implementation
   behavior.** Documentation explains and references them; it is never
   treated as more current than the thing it describes.
2. **`docs/DDS/analytics-platform-future-state-architecture.md`** is the
   CONCEPTUALLY FROZEN platform architecture — the single authoritative
   statement of the target data model. It stays at its current path
   (referenced by exact path from migration comments and other tooling);
   [04-architecture/](04-architecture/) summarizes and links to it rather
   than duplicating it.
3. **The Product Owner Workshop baseline** (archived at
   [99-archive/superseded-product/ems-product-owner-workshop-baseline.md](99-archive/superseded-product/ems-product-owner-workshop-baseline.md))
   is the source evidence for binding MVP product decisions (Q1–Q101). It is
   never edited to fit a new structure — decisions extracted from it into
   [00-governance/decisions/](00-governance/decisions/) cite it by question
   number.
4. **When two sources conflict**, the conflict is recorded, not silently
   resolved — see [00-governance/source-of-truth.md](00-governance/source-of-truth.md)
   for the full priority order and the required format for documenting a
   contradiction.
5. **Historical material is archived, never deleted.** See
   [99-archive/README.md](99-archive/README.md).

## How to update this documentation

See [00-governance/documentation-governance.md](00-governance/documentation-governance.md)
for the lightweight rule set (what kind of change updates what kind of
document) and [00-governance/decisions/README.md](00-governance/decisions/README.md)
for when a change warrants a new decision record.
