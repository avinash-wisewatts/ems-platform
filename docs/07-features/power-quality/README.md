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

## Future scope

Harmonic spectrum view, alerting on PF/imbalance (MVP-7), tie to equipment
start-ups (Post-MVP).
