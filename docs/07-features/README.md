# 07 — Features

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering

Canonical, per-feature documents connecting **purpose → requirements → UX →
architecture → validation → release status** for each significant EMS
capability, so a reader doesn't have to reassemble that chain from six
different directories. Each feature document links out to
[02-requirements/](../02-requirements/), [03-ux-and-design/](../03-ux-and-design/),
[04-architecture/](../04-architecture/), and
[08-verification/](../08-verification/) rather than duplicating their
content.

| Feature | MVP stage | Status (2026-09-13, commit `ddbe5a4`, unless noted) |
|---|---|---|
| [hierarchy/](hierarchy/README.md) | MVP-1 | **DONE** |
| [energy/](energy/README.md) | MVP-2 | **DONE** |
| [demand/](demand/README.md) | MVP-2 | **DONE** |
| [power-quality/](power-quality/README.md) | MVP-2 | **DONE** |
| [site-overview/](site-overview/README.md) | MVP-3 | **DONE** |
| [attention/](attention/README.md) | MVP-3 | **DONE** (Energy only; Demand/PQ informational, by decision) |
| [site-performance-report/](site-performance-report/README.md) | MVP-6 | **IMPLEMENTED, not deployed** (2026-09-14, ADR-015) — the one decided Q76 report type; broader Reporting scope remains undecided |

Evaluated but not given a dedicated document here because it would only
duplicate [02-requirements/](../02-requirements/) and
[03-ux-and-design/](../03-ux-and-design/) without adding a distinct
architecture/validation chain yet: Portfolio (MVP-8, lowest priority),
Alerts (MVP-7, decided in full detail per [ADR-016](../00-governance/decisions/ADR-016-q77-mvp7-basic-alerts.md)
but not implemented — 2 architecture questions open), Export (MVP-6,
decided per ADR-014 but not implemented). These get their own feature
document once their underlying capability exists to document. Reporting
(Q76) beyond the Site Performance Report above remains in the same
position.
