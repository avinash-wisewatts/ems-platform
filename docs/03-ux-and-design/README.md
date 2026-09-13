# 03 — UX and Design

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product

Canonical source for **what screens exist, what each shows, and how they
connect.** This is a **product-design hypothesis**, not a UI specification —
navigation, screen inventory, and layout stay a hypothesis until the
product owner reviews them; nothing here authorises implementation.
Consolidated from `docs/product/ems-information-architecture.md` v0.1.1
(archived at [../99-archive/superseded-product/](../99-archive/superseded-product/)).

| Document | Purpose |
|---|---|
| [information-architecture.md](information-architecture.md) | The screen catalogue: purpose, customer question, primary/secondary info, filters, states, API-dependency status, per screen. |
| [navigation.md](navigation.md) | The navigation hypothesis and its open questions. |
| [user-journeys.md](user-journeys.md) | The core customer journey and the MONITOR/INVESTIGATE/IMPROVE/MEASURE → screen mapping. |
| [interaction-patterns.md](interaction-patterns.md) | Cross-cutting UX rules that apply to every screen: breadcrumb, time-range control, quality indicator, loading/empty/no-data/error states. |

## Evidence labelling

Every non-trivial statement in the archived source carries a provenance
tag: `[ZEROWATT-OBSERVED]` (reference-product inspiration only, never
automatically a requirement) · `[INFERRED]` (a deduction, needs
confirmation) · `[WISEWATTS-DECISION]` (a deliberate product choice) ·
`[ARCH-CONSTRAINT]` (imposed by the frozen DDS/platform, not negotiable at
the product layer) · `[OPEN]` (no answer yet). This documentation set
preserves that discipline where it still adds information; resolved `[OPEN]`
items are stated as decided, with their Workshop Q-number citation.
