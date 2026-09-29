# Feature: Power Quality

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering
MVP stage: MVP-2 · Related requirements: [EMS-REQ-043](../../02-requirements/functional-requirements.md)

## Purpose

Answer "how is our power quality — is PF/THD within limits, and has it
changed materially?" (Workshop Q96). Scope is Power Factor (PF) and Total
Harmonic Distortion (THD) — not the full electrical-engineering harmonic
spectrum.

## Requirements

[EMS-REQ-043](../../02-requirements/functional-requirements.md) (voltage/
current/PF/harmonics, imbalance highlighting).

## User experience

[../../03-ux-and-design/information-architecture.md](../../03-ux-and-design/information-architecture.md)
§"Energy — Power Quality": current/relevant PF and THD values, trends,
applicable threshold/status where configured, plain-language explanation
of PF and THD (Workshop Q96) — never presented as a bare electrical-
engineering metric without business meaning where that meaning can be
substantiated (Workshop §21, B2B India principle).

## Business rules

Does **not** attempt to diagnose electrical causes or recommend corrective
action (Workshop Q96) — analytical exposure monitoring only, same posture
as Demand. Phase labels shown as friendly `L1/L2/L3`, never raw `qualifier`
values.

## Data / API dependencies

- **LIVE at the telemetry, API, and UI layer**: `telemetry.energy_measurements`
  carries `power_factor_total/l1/l2/l3` and `*_thd_*_percent`;
  `GET /api/v1/sites/{site_id}/power-quality` (Slice B, PR #48);
  `PowerQualityOverview.tsx` is a real screen.

## Architecture

[../../06-platform/telemetry/data-model.md](../../06-platform/telemetry/data-model.md)
(telemetry field catalog — 50 logical points per Eniscope profile, including
`POWER_FACTOR_L1/L2/L3/TOTAL`, `CURRENT_THD_L1/L2/L3/TOTAL`).

## Validation

Underlying telemetry columns confirmed live and populated. Slice B (PR #48)
landed with its own frontend/backend test suite.

## Release status

**DONE** (2026-09-13, PR #48, Slice B).

## Known limitations

The exact financial/operational significance framing for PF (Workshop
§20–§22, "instead of merely showing PF=0.92, communicate the relevant
financial implication") requires formulas and tariff/DISCOM scope that
remain **OPEN** — not to be assumed universal across Indian DISCOMs.

**1 Year across 29 February — backend follow-up.** The 1 Year preset is
the same date one year back through today (D61/D62), so it spans 366
calendar days, or **367** when the interval contains 29 February. The API's
1-day serving limit is 366 days (`POWER_QUALITY_RESOLUTION_MAX_WINDOW["1d"]` in `app/src/analytics_api_service.py`,
mirrored in `web/src/time/ranges.ts`). Product Owner decision (2026-09-29):
keep the calendar semantics — no shortened range and no special 365/366-day
rule — and **extend the backend/API limit to the maximum calendar span the 1
Year preset produces (367 days)**. That backend change is a follow-up,
required before 29 February 2028. Until then, for every "today" from
29 Feb 2028 to 28 Feb 2029 the 1 Year preset reports the range as not
served, rather than being shortened.

## Future scope

Harmonic spectrum view, alerting on PF/imbalance (MVP-7), tie to equipment
start-ups (Post-MVP).
