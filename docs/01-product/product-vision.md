# Product Vision

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: Product Owner Workshop baseline + `ems-product-definition.md` v0.1.1
Related decisions: [ADR-001](../00-governance/decisions/ADR-001-product-vision-and-principles.md)

## What WiseWatts EMS is

**WiseWatts EMS is an Energy Management System that happens to contain
dashboards** — not a collection of dashboards and charts, not a Grafana-style
analytics tool, and not a generic charting product. It is a facility
intelligence system that starts with **"How are we doing?"**, lets the
customer investigate **"Why?"**, and eventually helps answer **"What should
we do?"**

## Who it's for

The primary near-term customer is the **Facility / Energy Manager** — single-
or multi-site. Other B2B personas (Portfolio Lead, Operations Engineer,
Sustainability, Executive) use the same underlying analytics without
separate role-specific products (Workshop Q65). Homeowners are a possible
future segment; whether they share the same experience or need a distinct
one is explicitly undecided (Workshop §8).

## Why it exists — the customer job

**"Provide visibility into their energy use and performance that helps drive
optimisation and ultimately enables WiseWatts to provide recommendations."**
Visibility is the immediate job — it is the foundation for understanding,
optimisation, recommendations, and eventually AI-assisted optimisation. It is
**not** the final destination, and the product must never be positioned as
already delivering automated optimisation or guaranteed savings (Workshop
§9).

The customer outcome progresses through three stages (Workshop Q2):

```text
SEE & UNDERSTAND  →  IDENTIFY & PRIORITISE  →  IMPROVE & OPTIMISE
```

with continuous improvement of energy performance as the primary long-term
outcome — not visibility alone.

## The four-stage digital experience

```text
MONITOR      How are we doing?
    ↓
INVESTIGATE  Why is this happening?
    ↓
IMPROVE      What should we do?
    ↓
MEASURE      Did the action improve performance?
```

MONITOR and INVESTIGATE are the near-term product. IMPROVE and MEASURE are
later capabilities — no AI, recommendation, or anomaly-scoring functionality
ships ahead of its designated phase (see
[ADR-012](../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md)).

## Initial product promise

**Visibility + Basic Alerting + Reporting** (Workshop §9) — an initial scope,
not a ceiling. Business outcomes: track, manage, and optimise energy use;
reduce cost; progress toward sustainability goals — sustainability is
secondary to the core energy-management/optimisation objective.

## Long-term direction (not committed roadmap)

3–5 year ambition: an **Energy Intelligence Platform with AI** (Workshop
§10). The maturity path is directional, not phase-scoped:

```text
SEE → UNDERSTAND → IDENTIFY → INFORM → RECOMMEND → ACT → VERIFY → OPTIMISE → AUTOMATE
```

See [customer-requirements.md](customer-requirements.md) §13 for exactly
which of these later capabilities are `LATER` vs. explicitly out of scope,
and [ADR-012](../00-governance/decisions/ADR-012-deferred-ai-recommendation-functionality.md).

## What EMS is not (non-goals)

Not a rebuild of the Administration App; not a Grafana replacement for ops/
engineering; not a generic query builder / metric explorer for customers; not
a place that exposes telemetry structure or internal identifiers; not an AI
product in the near term; not a billing engine; not a driver of schema
change; not a clone of any reference product's navigation, terminology, or
layout. Full list: [product-definition.md](product-definition.md) §10.
