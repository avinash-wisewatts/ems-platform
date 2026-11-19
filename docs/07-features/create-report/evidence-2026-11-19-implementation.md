# Create report — implementation evidence (2026-11-19)

Results recorded during implementation of the Create report feature
([planning package](README.md), [ADR-025](../../00-governance/decisions/ADR-025-site-energy-performance-reports.md)).
The planning evidence ([evidence-2026-11-18.md](evidence-2026-11-18.md)) is
unchanged. Staging access was read-only: the same portal-scoped read
functions the worker uses, executed as a WiseWatts staff identity, one asset
per statement, streamed with `COPY ... TO STDOUT`. The recorded readings and
the CSV dataset are customer telemetry and are **not** in the repository.

## T-REG-1 — ported engine reproduces the reference tool

`app/tests/test_report_engine_reference.py` (runs where
`EMS_REPORT_REFERENCE_DATA` points at the reference CSV folder; skipped in
CI): every pinned figure of the reference tool's
`tests/test_reconciliation.py` (`KeyFigureRegressionTests`) is reproduced by
the ported engine. That covers energy totals, daily average, minimum and
maximum per group, subsystem and kitchen meter totals, the measured /
estimated / unresolved counts, the partial days, peak demand (value, time,
complete timestamps) and temperature (mean, deviation, in-band, observed
readings). Result: **6 passed**. The reference PDF generates and validates.

## T-MAP-2 — full-period Power and Temperature reconciliation (EMS vs CSV)

Period: labels 2026-10-11 00:00 to 2026-10-25 00:00 IST. EMS rows were read
with `analytics.get_portal_asset_measurements_1m` (`ACTIVE_POWER`/`TOTAL`,
`TEMPERATURE`) and mapped by the product loader
(`report_engine.ems_loader.asset_from_rows`).

| Series | Assets | CSV minutes found in EMS | Largest absolute difference on common minutes | EMS-only minutes |
|---|---|---|---|---|
| Power (kW) | all 15 HVAC assets | 100 % (e.g. Chiller1 20,122 of 20,122) | ≤ 5.0 × 10⁻⁷ kW (W → kW float rounding) | 1 per asset: the 25-Oct 00:00 closing reading the CSV export did not include |
| Temperature (°C) | Lobby Area AHU-1, Seasons Restaurant AHU-1/-2, Banquet 2 AHU | 100 % (19,764 / 19,795 / 20,028 / 20,111) | 0.0 | 1 per asset (closing reading) |

**Result: PASSED.** EMS holds every CSV Power and Temperature reading of
the period at the same site-local timestamp, with the same value.

## T-WK-1 — engine fed by EMS data vs the CSV reference

The weekly report for 18–24 Oct 2026 (comparison 11–17 Oct) was computed
twice with the same settings: from the CSV dataset, and from the recorded
EMS readings with the CSV-equal window (the closing 25-Oct 00:00 reading
removed). Every asset total, group total, daily statistic, peak demand,
temperature statistic and AHU runtime / out-of-hours figure was compared.

| Differences | Values (CSV → EMS) |
|---|---|
| Kitchen GF Hot Food PickUp Ctr | prev 178.6872 → 178.7131 kWh; curr 174.0519 → 186.1377 kWh |
| Kitchen GF Induction Ctr Tops | prev 77.2471 → 77.3155; curr 74.1608 → 77.7588 |
| Kitchen GF Sandwich Toaster | prev 147.5734 → 148.0376; curr 158.9195 → 162.9136 |
| Kitchen group (derived from the three above) | total prev 1,510.31 → 1,510.87; curr 1,513.60 → 1,533.28 |
| Everything else (HVAC, all subsystems, peak demand, temperature, runtime) | **identical** |

**Result: PASSED.** The only differences are the three kitchen meters
whose CSV export was 15-minute data with missing intervals (planning
evidence E2.3); EMS holds them at 1 minute, so the EMS-fed report is more
complete for those meters. With EMS data the kitchen's final Saturday is no
longer partial, so the current week is complete.

## T-WK-2 — closing midnight reading (A28)

Including the reading labelled 25-Oct 00:00 (it covers Saturday
23:59–24:00) adds that minute to the latest week: HVAC 31,285.0016 →
31,287.9557 kWh; unresolved HVAC intervals 15 → 0.

## PDF

EMS-fed weekly PDF for 18–24 Oct 2026: 9 pages, ~1.3 MB, validated (all
fonts embedded Source Sans 3, every required section and table, 14 charts),
no "Incomplete data" label, no comparison disclosure. Monthly layout
(synthetic October 2026): 9 pages; daily charts show the 31 days of
October as a single series; comparisons are month totals.

## Read cost observed

Recording 23 assets' energy plus 15 HVAC assets' measurements for 14 days
plus 1 minute took **20.7 s** end to end on staging (2026-11-19).
