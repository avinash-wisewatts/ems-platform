# Non-Functional Requirements

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product
Source of truth: `ems-customer-requirements.md` v0.1 §12 "Cross-cutting experience" (archived), consolidated here.

Cross-cutting requirements that apply across every feature screen, not to
one analytical domain. See [README.md](README.md) for conventions.

| ID | Title / description | Customer question | Priority | Source | Phase | Status | Dependencies | Notes |
|---|---|---|---|---|---|---|---|---|
| EMS-REQ-100 | **Shared time-range / resolution control.** One component; presets Today/7D/30D/3M/1Y + custom; resolution clamped to API support. | "Change the period once, everywhere." | MUST | PRODUCT_OWNER, ARCHITECTURE | 8 | READY-FOR-DESIGN | — | Measurements 3M/1Y unsupported by the Phase 7 first slice — disabled with a reason. |
| EMS-REQ-101 | **One charting foundation.** A single chart library/component used consistently. | — | MUST | ARCHITECTURE | 8 | READY-FOR-DESIGN | — | No mixed chart libraries. Landed — see [../05-applications/ems-web/README.md](../05-applications/ems-web/README.md). |
| EMS-REQ-102 | **Role-appropriate views.** Different users see role-appropriate information & navigation. | "Show me what matters to my job." | MUST | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | 8–9 | PO-REVIEW | Which roles exist — still an implementation-mapping task (Workshop Q65) | Enforcement server-side. |
| EMS-REQ-103 | **Fast page loads.** Performance is a product requirement with budgets. | "Why is this slow?" (never) | MUST | ZEROWATT_TECHNICAL_REFERENCE, PRODUCT_OWNER | 8, 16 | PO-REVIEW | budgets not yet set numerically (Workshop Q92 sets no concrete budget) | First-paint usable; progressive fill (Workshop Q92). |
| EMS-REQ-104 | **Responsive to phone width.** Usable at ~400px; no horizontal body scroll. | "Check it on my phone." | MUST | PRODUCT_OWNER | 8 | READY-FOR-DESIGN | — | Confirmed by Workshop Q91: one responsive EMS experience, not a separate mobile product. |
| EMS-REQ-105 | **Consistent empty/error states.** Distinct empty vs. no-data vs. error; never leak SQL/identifiers/stack traces. | "What do I do now?" | MUST | ARCHITECTURE | 8 | READY-FOR-DESIGN | EMS-REQ-071 | See Workshop Q93 for the customer-friendly error framing. |
| EMS-REQ-106 | **Saved views / bookmarks.** Persist a customer's chosen context + range. | "Take me back to my usual view." | COULD | INFERENCE | 9+ | DRAFT | per-viewer storage; possibly a customer-write (PA-4) | Start per-browser; server-side later. |
| EMS-REQ-107 | **Existing sensor/PLC reuse (product framing).** Presents data from existing meters without re-instrumentation. | "Do I need new hardware?" (no) | SHOULD | ZEROWATT_TECHNICAL_REFERENCE | — | READY-FOR-DESIGN | onboarding in the Administration App | A positioning/onboarding fact, mostly not a UI feature. |
| EMS-REQ-108 | **Modular expansion (product framing).** New sensors/parameters appear in the same experience without a bespoke screen each. | "Will new sensors just show up?" | SHOULD | ZEROWATT_TECHNICAL_REFERENCE | 9+ | DRAFT | generic parameter handling; `generic_point_measurements` | |
| EMS-REQ-109 | **Context-aware system (product framing).** Understands relationships between measurements, assets, spaces, systems, utilities. | "Why does this measurement matter?" | MUST | ZEROWATT_TECHNICAL_REFERENCE, ARCHITECTURE | 9+ | READY-FOR-DESIGN | asset/space relationships; parameter registry | This is the semantic model, exposed. |

## MVP performance/usability decisions (Workshop Q88–Q93)

These sharpen EMS-REQ-100/103/104/105 with decided MVP behavior, not just
aspiration:

- **First-time experience** (Q88): Login → Select Portfolio/Site → Site
  Overview → Start analysing. No setup wizard — configuration is owned by
  the Administration Portal.
- **Returning-user experience** (Q89): resume last Portfolio/Site/time
  range/analytical view where appropriate; current context always visible.
- **Search/quick navigation** (Q90): search across the customer hierarchy
  (site/space/asset by name) — never a generic search across raw telemetry,
  gateways, or internal structures.
- **Performance** (Q92): "Initial useful information → progressively
  deeper information" — Site Overview becomes available quickly, core
  status/key metrics appear, deeper charts load progressively, long
  operations get a clear loading state rather than appearing frozen. No
  numeric budget is set.
- **Error handling** (Q93): errors explain what couldn't load, whether it's
  site-wide or isolated to one analysis, what else remains available, and
  what the customer can do next — never a bare `Error 500`.
