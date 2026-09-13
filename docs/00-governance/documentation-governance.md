# Documentation Governance

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering

Lightweight rules for keeping `docs/` accurate as the system changes. The
goal is a documentation set someone can trust, not enterprise bureaucracy —
skip a rule below if applying it would only produce a meaningless edit.

| When this happens | Update this |
|---|---|
| **Product change** (vision, users, principles, goals) | [01-product/](../01-product/) |
| **Requirement change** (new/changed/dropped requirement) | [02-requirements/](../02-requirements/) traceability and the affected [03-ux-and-design/](../03-ux-and-design/) or [07-features/](../07-features/) document |
| **Architecture change** | Create or update a [decision record](decisions/) first, then [04-architecture/](../04-architecture/). A change to the frozen DDS model itself follows the DDS's own five-criteria change-control rule (see [04-architecture/system-architecture.md](../04-architecture/system-architecture.md)) — this documentation set does not loosen that bar. |
| **Implementation change** (code, refactor) | Documentation review only where the change alters something a canonical doc claims about *current behavior* — most implementation changes need no doc update. |
| **API contract change** | [04-architecture/api-architecture.md](../04-architecture/api-architecture.md) and the relevant [05-applications/](../05-applications/) or [07-features/](../07-features/) document. |
| **Database/schema change** (migration) | Review [04-architecture/data-architecture.md](../04-architecture/data-architecture.md) and [06-platform/database/](../06-platform/database/) for anything the change makes stale. Migration files themselves remain the authoritative record of *what* changed — see [source-of-truth.md](source-of-truth.md). |
| **Release / deployment** | [08-verification/release-validation.md](../08-verification/release-validation.md) (evidence) and, if the process itself changed, [09-release-and-deployment/](../09-release-and-deployment/). |
| **Document becomes superseded** | Move it to [99-archive/](../99-archive/) with a one-line reason in [change-history.md](change-history.md). **Never silently delete.** |
| **Material decision made** (product, architecture, or a binding scope call) | Add a [decision record](decisions/) — see below for what counts as "material." |

## What counts as a decision record vs. a routine documentation update

Create an ADR (see [decisions/README.md](decisions/README.md)) when a
decision:

- fixes a product or architecture direction other work will depend on
  (e.g., "Site is the primary MVP context," "the Analytics API is the only
  customer read path"),
- resolves a previously `OPEN` question in the product/requirements
  documents,
- would be expensive or disruptive to reverse once other work builds on it.

Do **not** create an ADR for:

- a UI copy change, a screen layout tweak, or any choice reversible without
  consequence to other work,
- an implementation detail with no product/architecture consequence,
- something already fully captured by a specific, cited requirement or
  workshop question — link to that instead of duplicating it in ADR form.

## Metadata

Canonical documents may carry a short status block (`Status`, `Owner`, `Last
reviewed`, `Source of truth`). Historical documents under
[99-archive/](../99-archive/) keep their original character and are **not**
retrofitted with this metadata — adding it would misrepresent them as
current.

## Keeping this practical

A change in one area often implies a review elsewhere: a requirement change
should make someone check the traceability matrix; an architecture change
that touches the frozen DDS model needs the DDS's own explicit change-control
process, not just a documentation edit. Use judgment — this page names the
common triggers, not an exhaustive checklist.
