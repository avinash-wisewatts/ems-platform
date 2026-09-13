# Customer Requirements — Summary

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product

The full, detailed requirements catalogue lives in
[../02-requirements/](../02-requirements/) — this page is a product-level
summary and entry point, not a duplicate.

## What the customer EMS must deliver, by priority

- **MUST (near-term):** a separate customer application reading exclusively
  through the Analytics API; organisation/site/breadcrumb navigation; the
  Site Overview MVP screen; energy consumption + comparison; environmental
  measurements per space; consistent quality indicators and no-data
  handling; one shared time-range control and one charting foundation;
  responsive layout. Full list:
  [../02-requirements/functional-requirements.md](../02-requirements/functional-requirements.md)
  §Priority summary.
- **SHOULD:** asset component tree, demand-peak investigation, power-quality
  analysis, cross-asset comparison, basic alerts, basic reporting.
- **LATER (deferred, real future capability):** insights, anomaly detection,
  recommendations, AI assistant, carbon accounting — see
  [../02-requirements/scope-and-deferred-functionality.md](../02-requirements/scope-and-deferred-functionality.md)
  and [ADR-012](../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md).
- **NOT IN SCOPE:** customer administration of organisations/sites/users/
  devices, a generic query builder, customer access to Grafana, a raw-tag
  browser, a generalised billing engine — see
  [../02-requirements/scope-and-deferred-functionality.md](../02-requirements/scope-and-deferred-functionality.md)
  §NOT IN SCOPE.

## Where a requirement comes from

Every requirement traces to one of: the product owner directly
(`PRODUCT_OWNER`), the frozen architecture (`ARCHITECTURE`), the technical
roadmap (`ROADMAP`), a reference-product demonstration or technical overview
(`ZEROWATT_DEMO`/`ZEROWATT_TECHNICAL_REFERENCE` — reference/inspiration
only, never automatically a WiseWatts requirement), or a documented
inference (`INFERENCE`, needing confirmation).

## Reference-product cross-check

Of a reference competitive product's 25 observed capabilities, WiseWatts
classifies roughly 4 as MUST-adjacent, ~9 as SHOULD, and ~12 as `LATER` —
see [../02-requirements/functional-requirements.md](../02-requirements/functional-requirements.md)
§"Reference-product cross-check" for the full mapping. Observing a
capability in a reference product does not make it a WiseWatts requirement.

## Full detail

- [../02-requirements/functional-requirements.md](../02-requirements/functional-requirements.md) — the `EMS-REQ-NNN` catalogue.
- [../02-requirements/non-functional-requirements.md](../02-requirements/non-functional-requirements.md) — performance, responsiveness, error handling.
- [../02-requirements/requirements-traceability.md](../02-requirements/requirements-traceability.md) — live-verified build status.
