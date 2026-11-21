# Reports → Create report — Requirements and Technical Planning Package

| | |
|---|---|
| Status | **Revision 4.2 — approved specification** (4.1 amended by the product owner, 2026-11-21: retrospective AHU baseline, customer-portal on-demand generation, Reports UI; A112–A117, §2.6). **Revision 4.1 IMPLEMENTED for staging (2026-11-19)** on `feature/reports-create-report`: migrations 328–329, report engine and worker, Administration App pages, customer-portal tab ([ADR-025](../../00-governance/decisions/ADR-025-site-energy-performance-reports.md), [implementation evidence](evidence-2026-11-19-implementation.md), [runbook](../../10-operations/create-report-runbook.md)). The automation account (A93) is not created; production is not approved (A106). |
| Worktree / branch | `C:\Users\avina\Documents\WiseWatts\ems-create-report`, `feature/reports-create-report` (from `origin/staging` 587de69) |
| Scope | Radisson Blu Coimbatore only; staging only; no production changes (A105, A106) |
| Evidence | [evidence-2026-11-18.md](evidence-2026-11-18.md) (unchanged in revision 3) |
| Reference implementation | `C:\Users\avina\Documents\WiseWatts\RadissonBlu\Analytics\weekly_ems_report_tool` |

Identifiers and labels:
- **D1–D30**: the original decisions.
- **F1–F51**: the revision 2 final decisions.
- **TC1–TC7**: the revision 3 resolutions of the seven technical questions.
- **A1–A106**: the revision 3 authoritative decision set (numbered as in your brief).
- **A107–A110**: the product owner's revision 4 approvals closing OQ1–OQ4.
- **A111**: manual permanent deletion from the recycle bin (approved 2026-11-19).
- **A112–A117**: the product owner's revision 4.2 amendment (2026-11-21): retrospective AHU baseline, on-demand generation in the customer portal, historical generation on explicit request only, Reports UI.
- **S**: the status set.
- **[FACT]**: verified (evidence file).
- **[ASSUMPTION]**: to verify during implementation.
- **[DESIGN]**: a technical choice made within the approved decisions.
- **OQn**: a historical open-question reference (all are closed; section 13).

## Revision history

| Rev | Date | Change |
|---|---|---|
| 1 | 2026-11-18 | Initial package: D1–D30, questions Q1–Q20, proposed rule changes R1–R7 |
| 2 | 2026-11-18 | F1–F51 and the status set; Q1–Q20 and R1–R7 resolved; remaining TQ1–TQ7 |
| 3 | 2026-11-18 | Revision 3 decision set A1–A106 applied; TQ1–TQ7 resolved as TC1–TC7. **Superseded:** Radisson Admins configuring or managing reporting (F1/F4/F8/F9/F12 → A1–A12); the proposed ADR-023 amendment and the customer-host settings screen (→ A12); GLOBAL-scope run-as account (→ A88–A90); effective-from-midnight for today (→ A19); the "Admin" web actions (generate, regenerate, retry, delete, restore, pause) in the customer portal (→ the Administration App, [DESIGN] §7). New: effective-at-save timestamps, Source Sans 3, explicit gap-filled handling, per-version purge tests. Open: OQ1–OQ4. |
| 4 | 2026-11-19 | **Product owner approved all four remaining recommendations**, recorded as A107 (OQ1: only WiseWatts Admins manage reports; Radisson Admin/Operator/Viewer view and download only), A108 (OQ2: Option A automation identity), A109 (OQ3: † + note under affected tables + "Comparison incomplete" in history; no overall label for comparison-only incompleteness) and A110 (OQ4: future-dated settings at 00:00 site time). OQ1–OQ4 closed. New A111: WiseWatts Admins can permanently delete a report (named as a report-management action in the revision 4 direction); placement in the recycle bin is [DESIGN]. Management placement in the Administration App moves from [DESIGN] to approved architecture (A107 and the revision 4 direction §13). The switch-state tests and the automation-account checks are made explicit. Counts recalculated (§2.1). The evidence file is unchanged. |
| 4.2 | 2026-11-21 | **Product owner amendment (A112–A117), superseding parts of 4.1.** (1) A WiseWatts-approved **retrospective AHU reporting baseline** for Radisson Blu Coimbatore from **1 Oct 2026** (A112): the approved AHU setpoints, operating schedules and OFF/ON thresholds (no STANDBY) are treated as in force from that date. It **supersedes A17/A18 for this baseline only**; every other setting stays today-or-later (A17–A19, A110 unchanged), and A23's "settings cannot be retrospective" now reads "only through an approved baseline". It is recorded, audited and labelled as a reporting baseline, **not** verified historical hotel operating practice. (2) **On-demand generation moves into the customer portal** for Site Admins and WiseWatts Admins; Operators and Viewers stay view/download only (A113, refining A107/A63). (3) Applying the baseline or migration 330 **generates nothing** (A114); historical reports are generated **only on an explicit request** on the Create report page, distinct from the ongoing weekly/monthly schedule (A115, A61–A70 unchanged). (4) Labelling (A116) and Reports UI (A117: Create report is the default tab; site from the sidebar; no site selector). Migration 330, engine 1.2.0. New AC-11–AC-16 and test areas T-RB, T-OD, T-UI-7–9. Counts recalculated (§2.1). |
| 4.1 | 2026-11-19 | **Product owner approved A111 as proposed; closed.** Permanent deletion is available only for reports already in the seven-day recycle bin, with explicit confirmation and audit logging; never directly from report history. A111 moves from [DESIGN] to an approved decision. Added T-DEL-11 and AC-6c. The review item in §13 is closed. Counts unchanged. |

## Contents

1. Product Requirements Document
2. Decision register and traceability
3. Technical architecture and data flow
4. EMS API and field-mapping specification
5. Reporting configuration specification (Administration App)
6. Report-generation and scheduling specification
7. UI specification (Administration App and customer portal)
8. Storage, retention and deletion specification
9. Security, permissions and audit specification
10. Testing and acceptance criteria
11. Implementation sequence
12. Risk, assumption and dependency register
13. Open questions requiring your review
14. Change inventory

---

## 1. Product Requirements Document

### 1.1 Problem

WiseWatts produces the Radisson Blu Coimbatore weekly EMS performance report
with a local Streamlit tool that reads 23 per-asset CSV files exported from
Eniscope and builds a Word document. This is manual, depends on an external data
export, and sits outside EMS access control. EMS already holds the same
telemetry: 20 of 23 assets reconcile to 0.0001 kWh over 14 days; the other 3
were 15-minute CSV exports and EMS holds them at 1 minute (evidence E2.3).

### 1.2 Goal (A1 brief §1)

Generate weekly and monthly energy-performance **PDF** reports for Radisson Blu
Coimbatore from data already stored in EMS. No manual CSV or Excel
export/upload. Existing EMS functionality and telemetry pipelines are
preserved.

### 1.3 Users and capabilities (A1–A12, A88)

| User | Where | Can |
|---|---|---|
| **WiseWatts Admin**: role ADMIN, scope GLOBAL (WiseWatts staff) | **Administration App** (staff-only per ADR-023), and the customer portal for viewing | Enrol the site; manage the reporting asset list and groups; designate the automation account; enter and edit per-asset setpoints, operating schedules and operating thresholds; pause/resume schedules; generate (incl. historical), regenerate, retry, delete and restore reports; recycle bin; attempt history |
| **Radisson Admin**: role ADMIN, scope ORGANIZATION/SELECTED_SITES | Customer portal only. **No Administration App access** (A2, A3, A12) | View and download reports for authorised sites (A5). No configuration or report-management actions (A6, A7, **A107**) |
| **Operator, Viewer** | Customer portal | View and download reports for authorised sites (A5) |
| **Automation account**: dedicated WiseWatts-controlled automation Admin identity, associated with the Radisson organization and restricted to Coimbatore, with no usable password (A88, A89, **A108**, Option A) | Never signs in; used only by the worker as the read identity | Nothing interactive (§4.6) |
| Anyone without access to the site / another organization | — | Nothing; the reports' existence is not revealed |

### 1.4 Functional requirements

| ID | Requirement | Decisions |
|---|---|---|
| FR-1 | Customer portal: Reports → **Create report** tab (view and download), shown for enrolled sites to all profiles with site access | A5, D9, D12 |
| FR-2 | Administration App: site reporting configuration, asset reporting settings, report management and recycle bin, WiseWatts Admins only | A2–A4, A6, A12 |
| FR-3 | Weekly period: Sun 00:00 – Sat 23:59:59 Asia/Kolkata, compared with the preceding week | A24, A26 |
| FR-4 | Monthly period: calendar month, compared with the preceding calendar month on monthly totals | A25, A27, A34 |
| FR-5 | Closing midnight reading belongs to the preceding period; `bucket_start` → Asia/Kolkata with no shift | A28, A29 |
| FR-6 | Weekly content retained; monthly uses the same sections and metrics; layout may improve | A31–A33, A99 |
| FR-7 | Absolute and % changes; % = NA when the comparison is zero or unavailable; incomplete comparisons flagged | A35, A40, A41 |
| FR-8 | Monthly: no day-to-day comparison, current-month daily charts only, no month-length references, no day-of-month pairing | A36–A39 |
| FR-9 | Kitchen attention: weekly > 10 % and > 25 kWh; monthly > 10 % and > 100 kWh | A42, A43 |
| FR-10 | Data-quality rules preserved; minimum current-period publication rules; measured / estimated (reconstructed and gap-filled) / missing classification; never invent values | A44–A57 |
| FR-11 | Coverage detail in report history and version details; PDF "Data completeness" note only when incomplete; no coverage page | A58–A60 |
| FR-12 | Automatic weekly and monthly generation on by default; independent pause/resume; manual generation; no back-fill on resume; historical generation | A61–A63, A70, A71 |
| FR-13 | First completeness check at +6 h, re-check every 30 min, deadline +12 h | A64–A67 |
| FR-14 | Up to 3 automatic retries (15/30/60 min) for temporary failures; manual retry | A68, A69 |
| FR-15 | Every attempt recorded; no duplicates per site, type and period | A72, A73 |
| FR-16 | Regeneration: Processing shown, previous PDF downloadable, new version published only after validation, previous kept on failure | A74–A76, A79 |
| FR-17 | Statuses Pending, Processing, Generated, Failed; "Incomplete data" label on Generated only | S |
| FR-18 | DB file storage; 60-day retention per version; SHA-256 and settings snapshot; immutable | A77–A80 |
| FR-19 | Delete = whole report, with confirmation and audit; recycle bin; restore within 7 days; per-version permanent deletion at the earlier of deletion + 7 d or generation + 60 d; restore never extends retention; WiseWatts Admins may also permanently delete a report from the recycle bin | A81–A87, A111 |
| FR-19a | Incomplete comparison period: never fails; † on affected figures, a note under affected tables, "Comparison incomplete" in history; no overall "Incomplete data" label for that alone | A41, A57, A109 |
| FR-19b | Customer-facing report APIs are read-only; all management is WiseWatts Admin only, enforced whether the staff-only switch is on or off | A6, A107 |
| FR-20 | Per-asset settings (setpoints, schedules, operating thresholds); today or future only; effective at save time; DB rejects past dates; audit; per-reading setpoint; range when setpoints differ; immutable PDFs | A13–A23 |
| FR-21 | Sensor-less assets: energy included, temperature excluded, "Not temperature-monitored"; temperature never estimated | A15, A16, A50 |
| FR-22 | Automation via a dedicated WiseWatts automation Admin account restricted to the site; clear failure if deactivated or losing access | A88–A90 |
| FR-23 | PDF only; WiseWatts logo and colours; "Radisson Blu Coimbatore"; no Radisson logo without an approved file; Source Sans 3 embedded; validated before Generated | A94–A100 |

### 1.5 Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-1 | Generation runs in a dedicated worker process, never in interactive requests |
| NFR-2 | Bounded resources on the 1.9 GB staging host: memory cap, one job at a time, per-call reads ≤ 14 days and one asset |
| NFR-3 | Tenant and site isolation enforced in the database on every read, write and download |
| NFR-4 | PDFs immutable, with SHA-256 and settings snapshot per version |
| NFR-5 | Attempts, outcomes and errors logged (DB attempt record plus application log, no secrets) |
| NFR-6 | No secrets in code, docs or browser |
| NFR-7 | Existing EMS functionality and telemetry pipeline unaffected |
| NFR-8 | Consistent with ADR-023: the Administration App stays staff-only; the customer API gains read-only report functions only |

### 1.6 Out of scope (A101–A106)

Notifications; configurable customer branding; Word output; editing generated
PDFs; sites other than Radisson Blu Coimbatore; production deployment until
separately approved.

### 1.7 Acceptance criterion

An authorized user can obtain the Radisson weekly or monthly PDF entirely from
data already in EMS, without downloading or uploading reporting data manually.

---

## 2. Decision register and traceability

### 2.1 Revision 3 decision set A1–A106 and status set (authoritative)

| A | Decision (summary) | Implementation | § | Tests |
|---|---|---|---|---|
| A1 | WiseWatts and Radisson Admins have reporting-management permissions for authorised sites, subject to the Administration App restriction | Read for both in the customer portal; management for WiseWatts Admins only (refined by A107) | 9.1 | T-SEC-1/3 |
| A2 | Only WiseWatts Admins access the Administration App | Reporting pages require active ADMIN + GLOBAL in the route and the DB function, independent of `EMS_ADMIN_STAFF_ONLY` | 9.2 | T-ADM-3 |
| A3 | Radisson Admins get no Administration App access, including reporting pages | As A2; no customer-host settings screen | 9.2 | T-ADM-3 |
| A4 | WiseWatts Admins manage all reporting configuration in the Administration App beside site and asset information | Site → Reporting; Asset → Reporting settings | 5.4, 7.1 | T-ADM-1 |
| A5 | All profiles view and download in the customer portal, subject to site access | Read-only Create report tab; `report.view` for every role | 7.2, 9.1 | T-SEC-1 |
| A6 | Only WiseWatts Admins change configuration and perform administrative report management | Management functions callable only by `ems_app` and only for GLOBAL ADMIN | 9.1 | T-SEC-3/4 |
| A7 | Radisson Admins cannot add, remove or reassign reporting assets or groups | No customer path; DB requires GLOBAL ADMIN | 9.1 | T-SEC-4 |
| A8 | WiseWatts manages the asset list and groups | Roster in the Administration App | 5.4 | T-ADM-2 |
| A9 | WiseWatts enters asset information, initial setpoints, schedules and initial AHU operating thresholds | Asset Reporting settings page | 5.1 | T-ADM-2 |
| A10 | WiseWatts Admins edit operating thresholds afterwards | Versioned per-asset setting | 5.1 | T-SET-6 |
| A11 | Report data-quality thresholds fixed and WiseWatts-controlled | Engine constants; shown read-only | 5.1 | T-SET-6 |
| A12 | Preserve the ADR-023 staff-only model; no amendment | No ADR-023 change; design consistent | 9.2 | T-ADM-3 |
| A13 | Configuration per asset | Settings keyed by `asset_id` | 5.1 | T-SET-1 |
| A14 | Settings: setpoints, schedules, operating thresholds | Setting keys | 5.1 | T-SET-1/6 |
| A15 | Sensor-less assets: energy included, temperature excluded, "Not temperature-monitored" | Sensor presence from the EMS catalogue | 4.2, 6.6 | T-MAP-4, T-RPT-4 |
| A16 | Temperature never invented or estimated | Loader and engine never fill | 6.6 | T-DQ-8 |
| A17 | Changes take effect today or later only (**except the one approved retrospective AHU baseline, A112**) | DB write function | 5.2 | T-SET-2 |
| A18 | DB rejects past effective dates (normal path; unchanged by A112) | `RAISE` in the write function | 5.2 | T-SET-2, T-RB-2 |
| A19 | Effective at the actual save time (not midnight) | `effective_from = clock_timestamp()` for today | 5.2 | T-SET-8 |
| A20 | Setpoint in force at each temperature reading | Per-reading resolution by timestamp | 5.2 | T-SET-1 |
| A21 | Different setpoints in an area → show the range | Area label "23.0–24.0 °C" | 5.2, 6.3 | T-RPT-5 |
| A22 | Configuration changes audited | `admin.audit_events` | 9.4 | T-SET-3 |
| A23 | PDFs immutable; settings changes affect new reports only; existing PDFs change only by explicit regeneration | Version model; snapshot | 8.2 | T-SET-5 |
| A24 | Weekly Sun 00:00 – Sat 23:59:59 IST | Period calculator | 6.1 | T-TS-1 |
| A25 | Monthly first to last day | Period calculator | 6.1 | T-TS-2/4 |
| A26 | Weekly vs preceding week | Period calculator | 6.1 | T-WK-3 |
| A27 | Monthly vs preceding calendar month | Period calculator | 6.1 | T-TS-3 |
| A28 | Closing midnight reading in the preceding period | Load range + interval-end attribution | 4.3, 6.1 | T-TS-1, T-WK-2 |
| A29 | `bucket_start` → Asia/Kolkata, no shift | Loader | 4.2 | T-MAP-1 |
| A30 | Keep the evidence-backed mapping; full-period Power/Temperature reconciliation as a test | Recorded fixtures | 10 | T-MAP-2 |
| A31 | Weekly sections, metrics, charts, tables retained | Engine port | 6.3 | T-RPT-1, T-REG-1 |
| A32 | Layout may improve without removing coverage | ReportLab layout | 3.4 | T-RPT-1 |
| A33 | Monthly = same sections and metrics over the month | Parameterised engine | 6.3 | T-MO-1 |
| A34 | Monthly totals vs previous month | Comparison tables | 6.5 | T-MO-2 |
| A35 | Absolute and % changes | Δ and % columns | 6.5 | T-MO-2, T-WK-3 |
| A36 | No day-to-day comparison between months | Monthly charts single-series | 6.3 | T-MO-3 |
| A37 | Monthly daily charts = current month only | As above | 6.3 | T-MO-3 |
| A38 | No month-length references | No day-count text | 6.3 | T-MO-4 |
| A39 | No day-of-month pairing or previous-month daily comparisons | As above | 6.3 | T-MO-3 |
| A40 | % = NA when the comparison is zero or unavailable | `pct_change` NA rule | 6.5 | T-WK-3 |
| A41 | Incomplete comparisons flagged | † marking + disclosure | 6.5, 6.8 | T-DQ-11 |
| A42 | Weekly kitchen attention > 10 % and > 25 kWh | Existing constant | 6.6 | T-MO-5 |
| A43 | Monthly kitchen attention > 10 % and > 100 kWh | Period constant | 6.6 | T-MO-5 |
| A44 | Existing rules preserved unless approved here | §6.6 | 6.6 | T-REG-1 |
| A45 | Current period: HVAC ≥ 80 %, Kitchen ≥ 80 % available; ≥ 1 valid peak timestamp | Quality gate | 6.8 | T-DQ-6/9 |
| A46 | An individual asset's missing data does not fail the report | Gate | 6.8 | T-DQ-7 |
| A47 | Include available data; identify affected assets | Coverage + PDF note | 6.8 | T-DQ-7 |
| A48 | Below minimum → Failed with a clear explanation | `insufficient_data` | 6.8 | T-DQ-6 |
| A49 | Minimum met but incomplete → Generated + "Incomplete data" | Label | 6.8 | T-DQ-5 |
| A50 | Never invent energy or temperature | Engine rules | 6.6 | T-DQ-8 |
| A51 | GOOD = measured | Loader flag | 4.2 | T-MAP-6 |
| A52 | Valid EMS-reconstructed readings included, identified as estimated | Loader flag | 4.2 | T-MAP-6 |
| A53 | Valid internally gap-filled readings count toward 80 % and are estimated | Engine flag | 6.6, 6.8 | T-DQ-10 |
| A54 | Reconstructed and gap-filled = estimated, not measured, in coverage and reporting | Coverage model | 6.8 | T-DQ-10 |
| A55 | Invalid or unavailable = missing | Loader flag | 4.2 | T-MAP-6 |
| A56 | 80 % applies to the current period | Gate | 6.8 | T-DQ-6 |
| A57 | Comparison-period incompleteness does not fail; disclosed | Gate + disclosure (presentation A109) | 6.8 | T-DQ-11 |
| A58 | Coverage detail in history and version details | Coverage JSON; UI | 7 | T-UI-3 |
| A59 | PDF "Data completeness" note only when incomplete | Renderer | 6.8 | T-RPT-6 |
| A60 | No coverage page | Renderer | 6.8 | T-RPT-6 |
| A61 | Automatic weekly and monthly on by default | Profile defaults | 3.5 | T-RT-5 |
| A62 | Independent pause/resume | Profile flags (Administration App) | 3.5, 7.1 | T-RT-5 |
| A63 | Manual generation available | Administration App | 7.1 | T-ADM-4 |
| A64 | First completeness check at +6 h | Scheduler | 6.7 | T-DQ-3 |
| A65 | Re-check every 30 min while data arrives | Scheduler | 6.7 | T-DQ-3/4 |
| A66 | Maximum wait 12 h | Scheduler | 6.7 | T-DQ-5 |
| A67 | At the deadline: incomplete report or failure per the minimum rules | Gate | 6.7 | T-DQ-5/6 |
| A68 | ≤ 3 automatic retries at 15/30/60 min for temporary failures | Attempt policy | 6.10 | T-RT-1/7 |
| A69 | Admins manually retry | Administration App | 7.1 | T-ADM-4 |
| A70 | Resume does not back-fill | Scheduler `resumed_at` | 3.5 | T-RT-5 |
| A71 | Manual historical generation where data is sufficient | Availability check | 4.4 | T-HIS |
| A72 | Every attempt recorded (user, trigger, status, reason, version) | Attempts table | 8.1 | T-RT-6 |
| A73 | No duplicates per site, type and period | Unique key + one active attempt | 6.10 | T-RT-3/4 |
| A74 | Regeneration shows Processing; previous PDF downloadable | Status + latest pointer | 8.2 | T-VER-2 |
| A75 | Publish only after validation | Atomic publication | 8.2 | T-PDF-3 |
| A76 | Failed regeneration keeps the previous version as latest | Atomic publication | 8.2 | T-VER-2 |
| A77 | Existing EMS DB file-storage pattern | BYTEA (migration 309 pattern), confirmed by E5 | 8.1 | T-DEL |
| A78 | 60-day retention per version from its generation | `expires_at` | 8.3 | T-DEL-4, T-VER-3 |
| A79 | Regeneration creates a version; previous remain until their own expiry or deletion | Version model | 8.2 | T-VER-1 |
| A80 | Immutable; SHA-256; settings snapshot | Version columns | 8.1 | T-VER-4 |
| A81 | Delete = whole report | Report-level delete | 8.4 | T-DEL-1 |
| A82 | Confirmation + audit | Dialog + audit | 8.4, 9.4 | T-DEL-1 |
| A83 | Recycle bin | Administration App | 7.1 | T-DEL-1 |
| A84 | Restore within 7 days | Restore function | 8.4 | T-DEL-2 |
| A85 | Per-version permanent deletion at the earlier of deletion + 7 d or that version's generation + 60 d | Purge rule | 8.4 | T-DEL-3/7/8 |
| A86 | Restore never extends retention | `expires_at` immutable | 8.4 | T-DEL-2 |
| A87 | Delete, restore, permanent deletion audited | Audit events | 9.4 | T-DEL-1/2/3 |
| A88 | Automatic generation uses a dedicated WiseWatts automation Admin account | Profile `automation_portal_user_id` | 4.6 | T-SEC-5 |
| A89 | Restricted to Radisson Blu Coimbatore; independent of personal accounts | Run-as checks (representation A108) | 4.6 | T-SEC-9/10 |
| A90 | Deactivated or losing access → generation stops with a clear failure | `automation_not_authorized` | 4.6 | T-SEC-5 |
| A91 | `ems_app` on staging | Worker env | 9.3 | — |
| A92 | Dedicated `ems_report_worker` role before production | Release prerequisite | 9.3, 12 | — |
| A93 | Do not create the account or credentials now | Not done; P10 dependency | 11 | — |
| A94 | PDF only | ReportLab | 3.4 | T-PDF-4 |
| A95 | WiseWatts logo and colours | Branding module | 6.11 | T-RPT-7 |
| A96 | Site identified as Radisson Blu Coimbatore | Branding module | 6.11 | T-RPT-7 |
| A97 | No Radisson logo without an approved file | Branding module | 6.11 | T-RPT-7 |
| A98 | Source Sans 3, embedded | Fonts vendored with OFL licence | 3.4, 6.11 | T-PDF-5 |
| A99 | Clean, professional, readable layout | Renderer + visual sign-off (P4) | 3.4 | P4 gate |
| A100 | Validate before Generated | `validate_pdf` | 6.9 | T-PDF-1/2 |
| A101 | No notifications | — | 1.6 | — |
| A102 | No configurable customer branding | — | 1.6 | — |
| A103 | No Word output | — | 1.6 | T-PDF-4 |
| A104 | No editing of generated PDFs | No edit path | 1.6 | T-VER-4 |
| A105 | Only Radisson Blu Coimbatore initially | Enrolment | 5.1 | T-SEC-2 |
| A106 | No production deployment until approved | — | 11 | AC-9 |
| A107 | (OQ1, approved; **generation refined by A113**) Only WiseWatts Admins generate, generate historical, regenerate, retry, delete, restore and permanently delete; Radisson Admin, Operator and Viewer view and download only, in the customer portal; customer-facing report APIs read-only | Administration App management; customer API GET only; management functions `ems_app` + GLOBAL ADMIN only | 7.1, 9.1, 9.2 | T-SEC-3, T-ADM-3/4, T-SEC-8 |
| A108 | (OQ2, approved, Option A) Automation identity: WiseWatts-controlled Admin associated with the Radisson organization, restricted to Coimbatore, no usable customer-facing password; checked every attempt; access failure stops the attempt with no automatic retry; trade-off documented; not created now | Profile designation + per-attempt checks | 4.6, 9.3 | T-SEC-5/9/10, T-RT-7 |
| A109 | (OQ3, approved) Incomplete comparison: † on affected figures, a concise note beneath affected tables, "Comparison incomplete" in report history; no overall "Incomplete data" label for comparison-only incompleteness | Renderer + `comparison_incomplete` flag + UI indicator | 6.5, 6.8, 7.2 | T-DQ-11, T-UI-3 |
| A110 | (OQ4, approved) A future-dated setting takes effect at 00:00 site time on the selected date | DB write function | 5.2 | T-SET-9 |
| A111 | (approved 2026-11-19, closed) WiseWatts Admins can permanently delete a report **only while it is in the seven-day recycle bin**, with explicit confirmation and audit logging; **no** permanent deletion directly from report history | Recycle-bin action only; DB function refuses reports not in state DELETED; confirmation step; audit event naming the user | 7.1, 8.4 | T-DEL-9, T-DEL-11, AC-6c |
| A112 | (rev 4.2, PO 2026-11-21) Retrospective AHU reporting baseline for Coimbatore from 1 Oct 2026: the approved AHU setpoints, operating schedules and OFF/ON thresholds (no STANDBY; Banquet 1 STANDBY absent) are copied unchanged as versions effective 00:00 site time on that date, under one recorded, audited baseline (approval reference, approver, statement, actor, effective date, affected settings). **Supersedes A17/A18 for this baseline only**; normal settings are still never back-dated; recorded history is never overridden | `apply_site_report_retrospective_baseline` (WiseWatts Admin; once per site; exact in-force AHU versions; earliest-version check; ≤ 180 days back); `site_report_retrospective_baselines`; `retrospective_baseline_id` | 5.2, 5.5 | T-RB-1–T-RB-6 |
| A113 | (rev 4.2) On-demand generation in the customer portal (Reports → Create report) for **Site Admins and WiseWatts Admins** (active ADMIN with site access, never the automation account): a new report for an ended period, or a **new version** of an existing one. Operators and Viewers view and download only. Refines A107 and A63. Retry, delete, restore, permanent deletion and configuration stay WiseWatts Admin actions in the Administration App | `report.generate` (ADMIN); `POST /api/v1/sites/{id}/site-reports` (same-origin JSON); `request_portal_site_report` (ems_customer_api); `get_portal_site_report_schedule.can_generate` (same DB rule, so the automation account is never offered the control); read identity accepts the requester while still allowed; ≤ 3 queued user requests per site | 7.2, 9.1, 9.2 | T-OD-1–T-OD-7 |
| A114 | (rev 4.2) Applying migration 330 or the retrospective baseline creates no report or attempt and changes no schedule or resume time (configuration-history backfill only) | Function writes settings and audit only; tests | 5.5 | T-RB-1 |
| A115 | (rev 4.2) Historical reports are generated only on an explicit request by an authorised user on the Create report page; the ongoing automatic weekly/monthly schedule (A61–A70, no back-fill on resume) is unchanged and separate | No scheduler change; only ended periods offered; nothing is requested without the user's click | 3.5, 7.2 | T-OD-2, T-UI-8 |
| A116 | (rev 4.2) A report that used baseline settings is labelled: a settings-snapshot `retrospective_baseline` block and per-setting `retrospective` flags; a PDF "Reporting settings basis" note (approved baseline, not verified hotel practice, readings unchanged); a "Retrospective baseline" label in history and version details. Existing PDF versions are never modified; new versions are generated. Readings are never invented | Engine 1.2.0 (`settings_snapshot`, `baseline_note`, renderer); `list_portal_site_reports.retrospective_baseline`; UI | 6.5, 7.2, 8.2 | T-RB-7, T-RB-8, T-UI-9 |
| A117 | (rev 4.2) Reports opens on **Create report** (Export data at `?tab=export`; old `?tab=create` links still work). The Create report tab has **no site selector** and uses the site selected in the application sidebar | `ReportsTabs`, `CreateReportTab` | 7.2 | T-UI-7 |
| S | Exactly Pending, Processing, Generated, Failed; "Incomplete data" label on Generated | Status mapping | 6.10 | T-UI-2 |

### 2.2 Original decisions D1–D30 → revision 3

| D | Decision | Revision 3 refinement |
|---|---|---|
| D1 | Timestamp verification | Done (E2); A28–A30 |
| D2 | Settings in EMS Admin | A4 (Administration App, WiseWatts Admins only) |
| D3 | Individual asset configuration | A13, A14 |
| D4 | Assets without temperature sensors | A15, A16 |
| D5 | Data-quality rules | A44–A57 |
| D6 | Failure handling | A68, A69, S |
| D7 | Six-hour buffer | A64 |
| D8 | EMS-managed storage | A77, A78 |
| D9 | Role-based access | A1–A7 |
| D10 | Manual deletion | A81, A82, A107 (WiseWatts Admins only) |
| D11 | Seven-day recycle bin | A83–A87, A111 |
| D12 | Combined history | A5 (customer portal), §7 (both UIs) |
| D13 | Historical generation | A71 |
| D14 | Insufficient historical data | A45–A49, A58–A60 |
| D15 | Automatic and manual | A61, A63 |
| D16 | Pause and resume | A62, A70 |
| D17 | No notifications | A101 |
| D18 | PDF only | A94, A103 |
| D19 | Branding | A95–A98 |
| D20 | Content and presentation | A31–A39 |
| D21 | Attempt history | A72 |
| D22 | Regeneration | A79 |
| D23 | Comparison periods | A26, A27, A34, A35, A40, A41 |
| D24 | Reporting calendar | A24, A25, A28 |
| D25 | Previous report during regeneration | A74–A76 |
| D26 | PDF quality validation | A100 |
| D27 | Delayed data | A64, A65 |
| D28 | Maximum wait 12 h | A66, A67 |
| D29 | Settings permission | A6, A9–A11 |
| D30 | Historical configuration, immutable reports | A17–A23, A80 |

### 2.3 Revision 2 decisions F1–F51 → revision 3

| F | Revision 2 decision | Rev 3 status | Rev 3 |
|---|---|---|---|
| F1 | WiseWatts and Radisson Admins manage reporting | **Refined**: management limited by A2/A6; Radisson Admins view/download only (A107) | A1, A6, A107 |
| F2 | Settings in the Administration App | Retained (WiseWatts only) | A4 |
| F3 | All profiles view/download | Retained | A5 |
| F4 | Only Admins change settings/manage | **Refined**: only WiseWatts Admins | A6 |
| F5 | Per-asset configuration | Retained | A13 |
| F6 | Sensor-less assets | Retained | A15 |
| F7 | WiseWatts manages the asset list and groups | Retained | A7, A8 |
| F8 | Radisson Admins configure setpoints/schedules | **Superseded**: WiseWatts Admins configure | A9 |
| F9 | Admins edit operating thresholds; DQ thresholds fixed | **Refined**: WiseWatts Admins | A10, A11 |
| F10 | Today or future only; audit | Retained + effective at save | A17–A19, A22 |
| F11 | Setpoint per reading; range | Retained | A20, A21 |
| F12 | WiseWatts enrols; Radisson enters initial setpoints/schedules | **Superseded**: WiseWatts enters everything | A8, A9 |
| F13 | Weekly period | Retained | A24 |
| F14 | Monthly period | Retained | A25, A27 |
| F15 | Closing midnight reading | Retained | A28 |
| F16 | Weekly content retained | Retained | A31, A32 |
| F17 | Monthly same sections/metrics | Retained | A33 |
| F18 | Monthly totals, absolute and % | Retained | A34, A35 |
| F19 | No day comparison; current-month daily charts | Retained | A36, A37, A39 |
| F20 | No day-count call-outs | Retained | A38 |
| F21 | Monthly kitchen > 10 % and > 100 kWh | Retained | A43 |
| F22 | Comparisons; NA | Retained | A26, A27, A40 |
| F23 | Rules preserved | Retained | A44 |
| F24 | 80 % HVAC/Kitchen; asset gaps don't fail; peak timestamp | Retained | A45–A47 |
| F25 | Fail with explanation | Retained | A48 |
| F26 | Incomplete label | Retained | A49 |
| F27 | GOOD = measured | Retained | A51 |
| F28 | Reconstructed = estimated; invalid = missing | Retained + gap-filled clarified | A52–A55 |
| F29 | Coverage in history/details; PDF note | Retained | A58–A60 |
| F30 | Never estimate temperature | Retained | A16, A50 |
| F31 | Auto on by default; pause/resume; manual | Retained | A61–A63 |
| F32 | +6 h, every 30 min | Retained | A64, A65 |
| F33 | +12 h deadline | Retained | A66, A67 |
| F34 | 3 retries 15/30/60; manual retry | Retained | A68, A69 |
| F35 | No back-fill | Retained | A70 |
| F36 | Historical generation | Retained | A71 |
| F37 | Attempts recorded | Retained | A72 |
| F38 | Processing; previous downloadable | Retained | A74–A76 |
| F39 | Versions; independent retention; immutable | Retained | A79, A80 |
| F40 | Validation | Retained | A100 |
| F41 | Existing storage | Retained | A77 |
| F42 | 60 days per version | Retained | A78 |
| F43 | Delete whole report | Retained | A81, A82 |
| F44 | Recycle bin 7 days | Retained | A83, A84 |
| F45 | Earlier of 7 d / 60 d; no extension | Retained, per version | A85, A86 |
| F46 | Designated WiseWatts Admin automation account | **Refined**: dedicated, restricted to the site, Option A representation | A88–A90, A108 |
| F47 | `ems_app` staging; dedicated role before production | Retained | A91, A92 |
| F48 | No notifications | Retained | A101 |
| F49 | PDF only | Retained | A94 |
| F50 | Branding | Retained | A95–A97 |
| F51 | Existing functionality unaffected | Retained | brief §1, NFR-7 |

### 2.4 Technical clarifications TC1–TC7 (resolving revision 2 TQ1–TQ7)

| TC | Revision 2 question | Resolution | Rev 3 |
|---|---|---|---|
| TC1 | ADR-023 conflict | ADR-023 preserved; Radisson Admins get no Administration App access; the proposed amendment and the customer-host settings screen are withdrawn | A2, A3, A12 |
| TC2 | Initial operating thresholds | WiseWatts enters them, then may edit | A9, A10 |
| TC3 | Purge with multiple versions | Per version: earlier of deletion + 7 d or that version's generation + 60 d | A85 |
| TC4 | Font | Source Sans 3, embedded | A98 |
| TC5 | Automation account | Dedicated WiseWatts automation Admin account restricted to the site; not created in this task | A88, A89, A93 |
| TC6 | "Effective today" | At the actual save time | A19 |
| TC7 | 80 % definition | Measured + reconstructed + gap-filled count as available (the latter two as estimated); current period only; comparison incompleteness disclosed, not failed | A53, A54, A56, A57 |

### 2.5 Revision 3 open questions, closed by product-owner approval (revision 4)

| OQ | Question (revision 3) | Approved resolution | Decision | Effect on earlier decisions |
|---|---|---|---|---|
| OQ1 | Who can manage reports? | Only WiseWatts Admins generate, regenerate, retry, delete and restore (and permanently delete, A111). Radisson Admin, Operator and Viewer view and download only | **A107** | Refines A1: Radisson Admins' reporting permissions are view and download; confirms A6 |
| OQ2 | Automation account model? | Option A: a WiseWatts-controlled automation Admin associated with the Radisson organization and restricted to Coimbatore, with no usable password | **A108** | Refines A88/A89 (representation); trade-off recorded in §4.6 and RK-4 |
| OQ3 | Incomplete comparison presentation? | † markers and explanatory notes under affected tables; "Comparison incomplete" in report history; no overall "Incomplete data" label for comparison-period incompleteness alone | **A109** | Refines A41/A57; A49/A59 apply to current-period incompleteness only |
| OQ4 | When do future settings take effect? | 00:00 site time on the selected future date | **A110** | Complements A19 (today = save time) |

**Counts:** 30 original decisions (D), 51 revision 2 decisions (F: 41
retained unchanged, 4 retained with clarification [F2, F10, F28, F45],
4 refined [F1, F4, F9, F46], 2 superseded [F8, F12]), 7 technical
clarifications (TC), 106 revision 3 decisions (A1–A106), 4 revision 4
approvals closing the open questions (A107–A110), 1 revision 4 action decision
(A111), 6 revision 4.2 amendment decisions (A112–A117) and 1 status set (S).
That is **117 numbered A decisions + S = 118 authoritative decisions**.

The traceability matrix (§2.1) has **118 rows**, one per A decision plus S:
- **113** rows map to tests or a review gate.
- **5** rows are process or scope decisions with nothing to execute, so they
  trace to a process approval instead of a test:
  - A91: staging uses `ems_app`.
  - A92: `ems_report_worker` before production (a production release
    prerequisite).
  - A93: no account or credentials in this task (the P10 authorisation).
  - A101: no notifications.
  - A102: no configurable customer branding.

The D (30), F (51) and TC (7) entries are **not** extra traceability rows. They
are historical registers that map onto A rows (§2.2–§2.4), so the
decision-history total (30 + 51 + 7 + 118 = 206 entries) intentionally differs
from the 118 traceability rows.

### 2.6 Revision 4.2 product-owner amendment (2026-11-21, A112–A117)

The product owner approved a change to the Create report historical
configuration rules and then corrected the implementation plan the same day.

| Topic | Revision 4.1 rule | Revision 4.2 (superseding) | Decision |
|---|---|---|---|
| Back-dated settings | Never (A17, A18, A23) | One WiseWatts-approved retrospective **AHU** baseline per site; Coimbatore from 1 Oct 2026; every other setting still today-or-later | A112 |
| What the baseline means | — | A reporting baseline approved by WiseWatts; **not** independently verified historical hotel operating practice; stated in the PDF, history and audit | A112, A116 |
| Generation on demand | WiseWatts Admins, Administration App only (A63, A107) | Also in the customer portal, for Site Admins and WiseWatts Admins; Operators and Viewers view/download only | A113 |
| Historical reports | WiseWatts Admin request (A71) | Only on an explicit request on the Create report page; the baseline approval is **not** an approval to generate historical reports | A114, A115 |
| Automatic schedule | A61–A70 | Unchanged and separate from any historical generation | A115 |
| Reports UI | Export data is the default tab; site selector in the tab | Create report is the default tab; site from the sidebar | A117 |

**Not changed:** the publication gate, data-quality rules and thresholds
(A11), the treatment of measured / EMS-reconstructed / gap-filled / missing
readings (A51–A55), temperature never filled (A16), immutable versions and
retention (A78–A87), configuration and the other management actions
(WiseWatts Admins only, Administration App), ADR-023, and production (A106).

**Data-availability check (read-only, staging, 2026-11-21 11:07 IST).**
- **Settings and reports.** The Coimbatore AHU settings in force equal the
  approved baseline exactly (18 versions, effective 19 Nov 2026 08:13). There
  are 0 reports and 0 attempts.
- **Energy (23 roster assets).** October: 99.8–99.9 % for HVAC and 94.7 % for
  kitchen. 1–20 Nov: 99.8–100 %.
- **Temperature.** October: Banquet 2 744/744 h. Lobby AHU-1 and Seasons
  Zones 1/2 have no data from 1 Oct 00:00 to 2 Oct 12:30 IST (~95 % of
  October).
- **September (October's comparison month)** is weaker: energy ~85 % (HVAC) /
  ~78 % (kitchen), AirSense only from 9 Sep, and no settings in force, because
  the baseline starts on 1 Oct. An October monthly report is therefore
  publishable, with **"Comparison incomplete"** (A109; engine 1.1.0
  disclosure).
- **Retention.** The 1-minute power and temperature floor (90 days) passes
  1 Sep on about 30 Nov 2026, so an October report generated after that date
  has less comparison data.

These are disclosures, not blockers.

---

## 3. Technical architecture and data flow

### 3.1 Existing EMS components reused

| Component | Reuse |
|---|---|
| `analytics.get_portal_asset_energy_series` (1m) / `fetch_analytics_energy_series` | Energy input |
| `analytics.get_portal_asset_measurements_1m` (migration 312) / `fetch_asset_measurements_1m` | Power and Temperature input |
| `analytics.get_portal_analytics_catalog` / `fetch_analytics_catalog` | Temperature-sensor presence (A15) |
| `fetch_analytics_site` / `metadata.sites.timezone` | Site name and timezone |
| `admin.portal_user_can_access_site`, `admin.list_accessible_assets` | Authorization in every function |
| Migration 309 pattern (SECURITY DEFINER, lease claim with `FOR UPDATE SKIP LOCKED`, BYTEA files, purge) | Reports, versions, files, attempts (A77) |
| `admin.audit_events` | Audit (A22, A82, A87) |
| Administration App (admin-portal, Jinja, staff session) | All configuration and report management (A4, A6) |
| Customer API (`customer_main`, role `ems_customer_api`) and admin-portal `/api/v1` router pattern | Read-only report routes (A5) |
| `ReportsPage.tsx`, the report-export polling provider, table styles | Customer portal tab |
| One `APP_IMAGE` with per-service `command:` | Worker from the same immutable image |

### 3.2 New components

C1 report engine · C2 EMS loader · C3 settings model · C4 report store ·
C5 worker and scheduler · C6 read-only report API · C7 Administration App
reporting pages · C8 customer-portal Create report tab · C9 permissions ·
C10 tests · C11 compose service · C12 documentation.

### 3.3 Data flow

```
ems-report-worker  (new container, same APP_IMAGE, compose profile "reports", memory cap)
  every 5 min: scheduler
    1. due periods per enrolled profile (schedule on, period_end + 6 h reached, first-attempt time after resumed_at)
         -> site_reports + PENDING attempt
    2. claim attempt (lease 10 min)                                -> PROCESSING
    3. authorize read identity:
         automatic -> dedicated automation account (active, restricted to the site, has access)
         manual    -> requesting WiseWatts Admin
    4. completeness probe (until period_end + 12 h)                -> PENDING again (+30 min) if late
    5. EMS loader, per asset, <= 14-day chunks:
         get_portal_asset_energy_series('1m')   Energy + quality / reconstruction flags
         get_portal_asset_measurements_1m       Power (15 HVAC), Temperature (4 sensors)
         get_portal_analytics_catalog           temperature-monitored assets
    6. effective settings per asset, resolved by timestamp (effective-at-save versions)
    7. engine: prepare -> gap-fill (<= 30 min, flagged estimated) -> metrics -> quality gate -> charts -> PDF -> validate
    8. publish atomically: version + file + latest pointer + attempt SUCCEEDED
  every 10 min: purge (per-version 60-day expiry; recycle-bin 7-day rule)

Administration App (admin-portal, WiseWatts Admins)  -> management + settings functions (EXECUTE: ems_app only)
Customer portal -> customer API /api/v1/sites/{site}/reports... (read-only) -> read functions (EXECUTE: ems_customer_api, ems_app)
```

The browser never reaches the database or receives credentials.

### 3.4 PDF generation (A94–A100)

- Metrics: the existing tool logic.
- Charts: the existing matplotlib functions, 200 dpi PNG, using Source Sans 3
  registered with matplotlib's font manager, each checked non-blank before
  embedding.
- Layout: ReportLab Platypus. Cover, KPI tiles in status colours, headings,
  `KeepTogether` for heading + chart + table, repeated table headers, footer
  with page numbers, clean and readable spacing (A99).
- **Typography (A98):** Source Sans 3 (Regular, Semibold, Bold, Italic), SIL
  Open Font License 1.1, which permits embedding. The TTF files are vendored
  with their licence under `app/src/report_engine/fonts/` and embedded
  (subset) in every PDF. Aptos is not used.
- Output: in-memory bytes → validation → publication.
- No DOCX; no LibreOffice (≈500 MB image, 150–250 MB RAM per conversion).

### 3.5 Scheduling (A61–A70)

- Every 5 min, the worker computes in site local time the latest closed week and
  month per enrolled profile.
- It creates a report and an AUTOMATIC attempt only when all of these hold:
  - the schedule is on;
  - no report exists for (site, type, period);
  - `period_end + 6 h` is later than the schedule's latest `resumed_at`, or the
    enrolment time.
- A pause does not cancel running attempts. A resume never back-fills (A70);
  missed periods are generated manually (A71).
- Unique constraints and `FOR UPDATE SKIP LOCKED` make concurrent workers safe.
  Reports due the same morning queue sequentially.

### 3.6 Storage

PDF bytes live in `analytics.site_report_files` (BYTEA, one row per version).
This is the existing EMS file-storage pattern [FACT E5: no object store in the
app]. Expected volume is about 1–2 MB per PDF and about 6 per month, under
50 MB retained [ASSUMPTION: confirm at first render].

---

## 4. EMS API and field-mapping specification

### 4.1 Site and asset identification

- Site by `site_id` (staging `870af241-abb4-4501-95dd-5c7508b72588`).
- Assets by `asset_id` through the WiseWatts-managed roster
  (`analytics.site_report_assets`: asset, group, area, order). Names are
  display-only.
- Roster WiseWatts will enter at enrolment (matches the tool, E1):

| Group | Assets |
|---|---|
| HVAC · Chillers | Chiller1, Chiller2 |
| HVAC · Pumps | Primary Pump-1, Primary Pump-2, Condenser Pump-1, Condenser Pump 2 |
| HVAC · Cooling towers | CoolingTower1, CoolingTower2 |
| HVAC · Air handling units (area) | Lobby Area AHU-1/-2 (Lobby); Seasons Restaurant AHU-1/-2 (Restaurant); Banquet 1 AHU (Banquet 1); Banquet 2 AHU (Banquet 2); Pre Function Area AHU (Banquet & pre-function) |
| Kitchen | the 8 "Kitchen GF …" meters |

### 4.2 Field mapping (A29, A51–A55)

| Engine input | Type | EMS source | Rule |
|---|---|---|---|
| `Timestamp (Site Local)` | naive local datetime | `bucket_start` of both reads | Convert to `metadata.sites.timezone`; **no shift** [FACT E2.4] |
| `Energy (kWh)` | float | `get_portal_asset_energy_series(uid, site, ARRAY[asset], from, to, '1m', as_of)` → `import_kwh` | Value kept when the bucket is MEASURED or RECONSTRUCTED; otherwise NaN |
| Energy source class (new engine input) | MEASURED / RECONSTRUCTED / MISSING | same row: `import_status`, `import_valid_intervals`, `import_reconstructed_intervals`, `import_invalid_intervals`, `import_data_state` | GOOD and not reconstructed → **MEASURED** (A51). Valid reconstructed → **RECONSTRUCTED**: included in energy, counted as **estimated** (A52, A54). Invalid / unavailable / NULL → **MISSING** (A55). [ASSUMPTION: the exact column combination identifying a valid reconstructed bucket is pinned by a DB test in P2 (RK-14)] |
| Engine estimated class (existing, internal) | GAP_FILLED | the engine's ≤ 30-min linear gap estimation | Included in energy, counted toward the 80 % availability, identified as **estimated** (A53, A54) |
| `Power (kW)` | float | `get_portal_asset_measurements_1m(uid, site, asset, ARRAY['ACTIVE_POWER'], ARRAY['TOTAL'], …)` | Already kW; read for the 15 HVAC assets |
| `Temperature (degC)` | float, optional | the same call, `('TEMPERATURE', NULL)`, only where the catalogue has `TEMPERATURE` | Never filled (A16); absent → "Not temperature-monitored" (A15) |
| Interval | int | inferred | 1 min for all 23 assets |

There are no missing EMS data fields [FACT E1–E2].

### 4.3 Read windows and chunking (A28)

- Label range `[comparison_start 00:00, period_end_date + 1 day 00:00]`
  inclusive. This covers both periods and each period's closing midnight
  reading.
- One asset per call, ≤ 14 days per call, de-duplicated on `bucket_start`.
- Power for the 15 HVAC assets only, Temperature for the 4 sensor assets only,
  Energy for all 23.
- Estimated staging read time (E4): weekly ≈ 8 min, monthly ≈ 35 min. The lease
  is extended after each asset.

### 4.4 Historical data (A71)

- Accepted when the current period is inside the retention floors (1-minute
  measurements 90 days; 1-minute energy 180 days; from
  `get_analytics_point_resolution_floors` / `get_analytics_energy_resolution_floors`)
  and after the site's first data.
- A comparison period partly outside the floor → generated, comparison disclosed
  as incomplete (A57).
- Otherwise refused: "EMS no longer holds the 1-minute data needed for this
  period." There is no 15-minute substitute.

### 4.5 Missing data

Missing slots follow the engine's existing rules (§6.6). EMS-reconstructed
values are handled per A52. Temperature is never filled.

### 4.6 Read identity (A88–A90, A108)

- **Manual** (generate, historical, regenerate, retry): reads run as the
  requesting WiseWatts Admin.
- **Automatic:** reads run as the profile's `automation_portal_user_id`.

**Approved representation (A108, Option A):**
- A dedicated, WiseWatts-controlled portal identity with role ADMIN, scope
  SELECTED_SITES, organization Radisson Blu, sites = {Coimbatore} only.
- No usable customer-facing password: it never signs in, and no credential is
  issued to anyone.
- It is designated on the site report profile by a WiseWatts Admin.
- It is not anyone's personal account.

**Checks on every attempt.** Failing any check stops the attempt with
`automation_not_authorized`, with no automatic retry (A90, A108):
- the account is active;
- it is the account designated on the profile;
- its scope is SELECTED_SITES, its organization is the site's organization, and
  its only site is Coimbatore (A89);
- `admin.portal_user_can_access_site` is true for the site.

**Use:** the account never signs in. Only its `portal_user_id` is passed to the
portal-scoped read functions; no new read functions are added. It never
performs management actions: those require a GLOBAL WiseWatts Admin (§9.1), and
this account is not GLOBAL.

**Documented trade-off (A108):**
- Because it has an organization, EMS (ADR-023 decision 4) classifies it as a
  customer-organization identity, and it may appear in the Radisson user list
  (e.g. the Administration App's user list filtered by organization).
- ADR-023 is not amended. The account's purpose is recorded in ADR-025 and the
  operations runbook.
- Holding the ADMIN role in the Radisson organization is mitigated by having no
  usable password and by the GLOBAL requirement for every reporting-management
  function (RK-4).

**Creation:** not part of this task (A93). It needs your separate, explicit
authorisation (P10).

---

## 5. Reporting configuration specification (Administration App)

### 5.1 Settings model (migration 328)

All writes are by **WiseWatts Admins only** (A6, A9, A10).

| Setting | Level | Type / validation | Initial value |
|---|---|---|---|
| Site enrolment (Create report enabled) | site | `analytics.site_report_profiles` | Radisson Blu Coimbatore, entered by WiseWatts |
| Automation account | site | the dedicated account (A88, A89) | designated by WiseWatts when it exists (A93) |
| Reporting asset list and groups | site | `analytics.site_report_assets` | entered by WiseWatts (§4.1) |
| Automatic weekly / monthly | site | on/off + paused/resumed by and at | on / on (A61) |
| Temperature setpoint (°C) | asset (temperature-monitored only) | 10.0–35.0, step 0.5 | entered by WiseWatts (A9) |
| Operating schedule | asset (AHUs) | weekly intervals per day, overnight allowed, `00:00–24:00` full day; validated with the existing `validate_schedule`; optional "confirmed by hotel"; "calculate out-of-hours energy" | entered by WiseWatts (A9) |
| Operating thresholds OFF / STANDBY / ON (kW), runtime enabled | asset (AHUs) | numeric ≥ 0, OFF < STANDBY < ON, STANDBY optional | entered by WiseWatts from the tool's evidence-based values (A9), editable later (A10) |
| Report data-quality thresholds | engine | **fixed constants, WiseWatts-controlled in code** (A11): 30-min gap, 90 % full day, 0.5 % unmeasured, 95 % peak coverage, 50 % in band, ±1 °C band, 10 % duty swing, kitchen weekly > 10 % & > 25 kWh / monthly > 10 % & > 100 kWh, publication 80 % | shown read-only |

"Temperature-monitored" is shown read-only per asset. It is derived from the EMS
catalogue, never edited (A15).

### 5.2 Effective-at-save persistence and validation (A17–A23)

- Storage is append-only: `analytics.asset_report_setting_versions(id,
  asset_id, setting_key, value JSONB, effective_from TIMESTAMPTZ, created_by,
  created_at, state ACTIVE|WITHDRAWN, supersedes_id)`.
- The client never supplies a timestamp. The write function computes
  `effective_from`:
  - **effective today** → `effective_from = clock_timestamp()`, the actual save
    instant (A19);
  - **a future date** → `effective_from` = 00:00 of that date in the site
    timezone (A110). The form offers only a date, never a time, and any
    client-supplied time is ignored;
  - **a date before today** (site local) → rejected with SQLSTATE `22023` and
    message `report_setting_past_effective_date` (A17, A18).
- Past or effective rows are never updated or deleted. A future-dated change can
  be withdrawn before its `effective_from`; the withdrawal is itself a new
  audited row.
- **Resolution** is by timestamp:
  - setpoint: the version in force at each temperature reading's timestamp
    (A20);
  - schedule and operating thresholds: the version in force at each energy
    interval's start;
  - on a tie, the latest created wins.
  - A change saved at 10:42 today therefore applies from 10:42; earlier readings
    keep the previous value.
- **Area display (A21):** a single setpoint, or the range (e.g.
  "23.0–24.0 °C") when the area's sensors, or a change during the period, give
  different values.
- **Audit (A22):** every write and withdrawal adds an `admin.audit_events` row
  with previous and new values, `effective_from`, actor, role and time.
- **Immutability (A23):** each PDF version stores the settings snapshot it used.
  Settings changes affect only new versions. Settings cannot be
  retrospective through this path, so regenerating a past period reproduces the
  settings in force then. The only exception is an approved retrospective
  baseline (A112, §5.5), which adds versions for an earlier date. It never
  changes an existing PDF version: a version generated before the baseline
  keeps its snapshot, and only a newly generated version uses the baseline.

### 5.5 Retrospective AHU reporting baseline (A112, A114; migration 330)

- **Scope.** AHU roster assets only (`HVAC_AHU`), and only the three AHU
  settings: temperature setpoint, operating schedule and operating thresholds.
  One baseline per site.
- **Who.** A WiseWatts Admin (active ADMIN, GLOBAL scope, with site access).
  The customer API cannot call it.
- **What it does.**
  - The caller names **exactly** the AHU setting versions currently in force.
    Each must be its asset's and key's **earliest** active version, so no
    recorded history is overridden.
  - Values are copied **unchanged** as new versions effective 00:00 site time
    on the baseline date, and each is linked to the baseline record
    (`retrospective_baseline_id`).
  - The baseline record keeps the approval reference, approver, statement,
    actor and time.
- **Audit.** One `REPORT_SETTING_RETROSPECTIVE` event per inserted version and
  one `SITE_REPORT_RETROSPECTIVE_BASELINE` event (with `reports_generated: 0`).
- **Refusals.**
  - A date today or in the future, or more than 180 days back.
  - A missing approval reference, approver or statement.
  - Any other version set.
  - A second baseline.
- **Generates nothing.** No report, no attempt, and no schedule or resume-time
  change (A114). Historical reports follow §7.2 / A115.
- **Coimbatore.** Baseline date 1 Oct 2026, applied with
  `postgres/maintenance/330_coimbatore_retrospective_baseline_apply.sql`. The
  script is a dry run by default and refuses unless the 18 in-force versions
  equal the approved values. Applying it is a separate staging write that
  needs its own authorization.
- **Effect.** From 1 Oct 2026 until 19 Nov 2026 08:13, the baseline versions
  are in force. From then on, the identical normally saved versions are in
  force. The values are the same, so no figure changes at that boundary
  (T-RB-7).

### 5.3 Missing configuration

| Missing | Behaviour |
|---|---|
| Setpoint for a temperature-monitored asset | Average temperature shown; deviation and in-band NA, "setpoint not configured"; neutral tile |
| Schedule for an AHU | No out-of-hours split ("No schedule"); the out-of-hours tile appears only if at least one AHU has one |
| Operating thresholds | Runtime "not reported" for that AHU |
| No enrolment | Create report tab hidden |
| No valid automation account | Automatic attempts fail `automation_not_authorized`; warning on Site → Reporting |

### 5.4 Administration App pages (A4, C7)

All pages are WiseWatts Admin only (§9.2):
- **Site detail → Reporting**: enrolment, automation account, asset list and
  groups, weekly/monthly schedule pause/resume (A62), read-only data-quality
  thresholds, and the configuration change log.
- **Site detail → Reports**: report management (§7.1).
- **Asset detail → Reporting settings** (roster assets): temperature-monitored
  indicator; current setpoint, schedule and operating thresholds; "Change
  setting" form (value + "effective now" or a future date); pending future
  changes with Withdraw; version history (previous → new, effective from, user,
  time).

---

## 6. Report-generation and scheduling specification

### 6.1 Periods (A24–A28)

All times are site local (`Asia/Kolkata`).

| | Weekly | Monthly |
|---|---|---|
| Period | `[Sun 00:00, next Sun 00:00)`, displayed "Sun dd-mmm-yyyy – Sat dd-mmm-yyyy" (through 23:59:59) | `[1st 00:00, next 1st 00:00)` |
| Comparison | The preceding Sun–Sat week | The preceding calendar month (December for January) |
| Closing reading | The reading labelled next Sun 00:00 belongs to the week ending Saturday | The reading labelled the next 1st 00:00 belongs to the month |
| Identity | `(site_id, WEEKLY, period_start_date)` | `(site_id, MONTHLY, period_start_date)` |

### 6.2 Engine refactor

- Fixed calendar periods replace the tool's data-driven week search. Missing days
  become coverage findings.
- Wording is parameterised by period type.
- `ems_runtime.analyse_week` already works over any range [FACT].

### 6.3 Content (A31–A39, A42, A43)

| Section | Weekly (content unchanged, layout improved) | Monthly (same sections and metrics) |
|---|---|---|
| 1 Executive summary: KPI tiles, key observations, areas for attention | vs preceding week | vs preceding month on monthly totals; kitchen attention > 10 % and > 100 kWh |
| 2.1 HVAC energy by subsystem | Daily chart (weekday pairs, existing); subsystem chart; table | Daily chart: current month only; stacked subsystem daily chart: current month; table: monthly totals, Δ, %, current-month daily average/min/max |
| 2.2 Peak HVAC demand | Latest-week trace; previous peak as reference line | Current-month trace; previous month's peak as a reference value |
| 2.3 Temperature vs setpoint | Per area: setpoint or range, averages, deviation, in-band, change | Same, month vs month |
| 2.4–2.6 Area AHUs | Hourly temperature (latest week); daily temperature weekday comparison (existing); energy chart and table | Hourly temperature: current month; daily temperature: current month only; energy chart: current month; tables: monthly totals vs previous month |
| 3 Main kitchen | Daily chart (weekday pairs), meter chart, table | Daily chart: current month; meter chart: current vs previous month **totals** per meter; table |
| 4 AHU operating profile and out-of-hours energy | Runtime previous/latest week; out-of-hours chart and table | Runtime previous/current month; same |
| Data completeness note | Only when labelled incomplete (A59) | Same |

Monthly reports contain no day-of-month pairing, no previous-month daily series,
and no text about the number of days in either month (A36–A39). Weekly daily
comparisons are unchanged (A31).

### 6.4 Pipeline per attempt

1. Claim.
2. Authorize the read identity (§4.6).
3. Completeness probe.
4. Load.
5. Resolve settings.
6. Prepare and gap-fill.
7. Compute.
8. Quality gate.
9. Charts.
10. Render the PDF.
11. Validate.
12. Publish atomically.
13. Log.

### 6.5 Comparisons (A26, A27, A34, A35, A40, A41)

- Tables show previous, current, **Δ (absolute)** and **% change**.
- % is **NA** when the comparison value is zero, missing or not computable. Δ is
  shown when both values exist. No ±∞.
- **Incomplete comparison period (A41, A57, A109):** this never fails the
  report.
  - Every affected comparison figure is marked **†**.
  - A concise note sits beneath each affected table, e.g. "† Comparison period
    data incomplete (Kitchen: 71.4 % of expected readings available); these
    changes are indicative."
  - Report history and version details show **"Comparison incomplete"**.
  - The overall **"Incomplete data"** label and the PDF "Data completeness" note
    are **not** applied for comparison-only incompleteness. They depend on the
    current period only (A49, A59).
- The existing † "indicative" rules for the current period stay as they are
  (`is_fully_comparable`, peak coverage < 95 %, temperature coverage < 90 %),
  and use the same † marker.
- **Settings not in force throughout the comparison period** (Product Owner,
  2026-11-19; engine 1.1.0). Settings are never back-dated through the normal
  path (A17, A23). The approved retrospective baseline (A112) moves the start
  of Coimbatore's AHU configuration to 1 Oct 2026, so comparisons from October
  on are fully configured, and October's comparison month (September) is
  disclosed.
  - **Trigger:** a setpoint, operating schedule or operating threshold is in
    force at the end of the latest period but not from the start of the
    comparison period. A change between two configured values is not a gap.
  - **Disclosure:** the A109 comparison disclosure is applied.
    - Comparison temperature deviation and in-band share, AHU runtime and
      out-of-hours figures are marked †.
    - The note names the settings and when they took effect, e.g. "In the
      previous week, reporting settings were in force only from 19 Nov 2026
      08:13 (…)".
    - History shows "Comparison incomplete".
  - **No change to calculations:** nothing is recalculated or estimated, the
    report remains publishable, and the "Incomplete data" label is not applied.

### 6.6 Data-quality rules

**Preserved (A44):**
- Energy is summed, never derived from Power.
- Grid alignment within min(40 % of interval, 1 min).
- Linear gap estimation for internal energy gaps ≤ 30 min.
- Negative energy is treated as missing.
- Full day = ≥ 90 % **measured** readings.
- Group days are comparable only when all assets are full.
- Unavailable days are never shown as zero.
- Peak demand requires all 15 HVAC assets observed.
- Peak comparison is indicative below 95 % coverage.
- Totals are directly comparable only with no partial/missing asset-days and
  ≤ 0.5 % unmeasured.
- Temperature is never estimated; statistics use every recorded reading.
- Duplicates are averaged and flagged.

**Approved in the revision 3 set:**
- A28 closing reading.
- A20/A21 per-reading setpoint and range.
- A43 monthly kitchen threshold.
- A45–A49 publication minimum.
- Reading classes A51–A55:

| Class | In energy totals | Counts toward 80 % availability | Coverage class | Full-day (90 %) and runtime classification |
|---|---|---|---|---|
| MEASURED (GOOD) | yes | yes | measured | counts / classified |
| RECONSTRUCTED (valid EMS) | yes | yes | **estimated** | does not count / NO DATA (existing treatment of estimated energy) |
| GAP_FILLED (engine ≤ 30 min) | yes | yes | **estimated** | does not count / NO DATA |
| MISSING (invalid, unavailable, > 30-min gap) | no | no | missing | does not count / NO DATA |

- A15: "Not temperature-monitored" labelling.

### 6.7 Delayed data (A64–A67)

- `T_end` = period end. The first check runs at `T_end + 6 h`.
- **Probe** (last 60 min of the period, per roster asset): energy
  `import_last_data_at ≥ T_end` or an explicit GAP state; HVAC measurement rows
  present; pipeline not stale.
- If incomplete and before `T_end + 12 h`: **Pending**, re-checked every 30 min,
  shown as "Waiting for EMS data (n of 23 meters complete)".
- At `T_end + 12 h`: generate with the available data, then apply the gate.

### 6.8 Publication gate and disclosure (A45–A49, A53–A60)

Evaluated on the **current period** (A56):

| Rule | Outcome |
|---|---|
| HVAC: (measured + reconstructed + gap-filled) < 80 % of expected energy readings | **Failed** `insufficient_data` |
| Kitchen: the same < 80 % | **Failed** `insufficient_data` |
| No timestamp with all 15 HVAC assets observed | **Failed** `insufficient_data` |
| An individual asset missing data | Not a failure: its available data is included; the asset is identified (A46, A47) |
| Minimum met, but any current-period incompleteness rule fires (partial/missing asset-days, > 0.5 % unmeasured, peak coverage < 95 %, temperature coverage < 90 %) | **Generated + "Incomplete data"** (A49) |
| Comparison period incomplete | **Not** a failure (A57). Presentation per A109: † + note beneath affected tables + "Comparison incomplete" in history; no "Incomplete data" label from this alone |
| Otherwise | **Generated** |

- Failure message example: "HVAC energy readings available: 71.3 % of expected
  (minimum 80 %). No values were estimated or invented beyond the approved
  ≤ 30-minute gap rule."
- **Coverage record per version (A58):** JSON with:
  - per group and per asset: measured %, estimated % (reconstructed and
    gap-filled shown separately), missing %;
  - incomplete days;
  - peak coverage;
  - temperature coverage;
  - comparison-period summary.

  Shown as a summary in history and in full in version details.
- **PDF (A59, A60):** a short "Data completeness" paragraph only when labelled
  incomplete, naming the affected groups and assets. No coverage page.

### 6.9 PDF validation (A100)

All must pass before Generated:
1. Opens with pypdf; page count in range; no empty page.
2. 50 KB – 20 MB; structure intact; pypdfium2 renders every page, none blank.
3. Text contains every required section heading for the type, "Radisson Blu
   Coimbatore", the exact reporting and comparison period strings, and the title.
4. Embedded image count ≥ the charts produced; each chart passed a non-blank
   check.
5. Every expected table header is present.
6. Fonts embedded and all Source Sans 3 (no unembedded or substituted font).
7. SHA-256 and size recorded.

Failure → Failed `pdf_validation_failed:<check>`; no version is created.

### 6.10 Statuses, retries, idempotency (S, A68–A76)

| Status | Meaning |
|---|---|
| **Pending** | Waiting: the 6 h buffer, a data re-check or a retry backoff |
| **Processing** | An attempt is running; the previous version, if any, stays downloadable |
| **Generated** | The latest attempt published a validated version; optional **"Incomplete data"** label |
| **Failed** | The latest attempt failed; the reason is shown; earlier versions stay downloadable |

- There are exactly four statuses. Expired versions and deleted reports are views
  (version details, recycle bin), not statuses.
- **Attempts (A72):** trigger AUTOMATIC / MANUAL / HISTORICAL / RETRY_AUTO /
  RETRY_MANUAL / REGENERATE; status; retry number; user (NULL for automatic,
  with the automation account recorded); reason; times; resulting version.
- **Automatic retry (A68):** temporary failures only (database error, worker
  interruption, lease loss, unexpected error). Up to 3 retries at +15, +30 and
  +60 min. `insufficient_data`, `automation_not_authorized`,
  `retention_exceeded` and `pdf_validation_failed` caused by data are not
  retried automatically. Manual retry by a WiseWatts Admin (A69).
- **Duplicate prevention (A73):**
  - `UNIQUE (site_id, report_type, period_start_date)`.
  - One PENDING/PROCESSING attempt per report (partial unique index).
  - Generate on an existing period → "already exists; regenerate?".
  - The scheduler creates only missing reports and never back-fills.

### 6.11 Branding (A95–A98)

- WiseWatts logo (`web/public/branding/logo.svg`) on the cover and in the
  header.
- WiseWatts palette: navy `#05245B`, teal `#03A9A0`, orange `#FF9966`, slate
  `#8C96A8`, and the existing status colours.
- **"Radisson Blu Coimbatore"** on the cover, in the footer and in the file
  name.
- Cover "Prepared for: Radisson Blu Coimbatore Engineering & Facilities
  Management / Prepared by: WiseWatts Solutions".
- Source Sans 3 throughout (text and charts).
- No Radisson logo unless an approved file is supplied.

### 6.12 Logging

Each attempt row records start, end, duration, trigger, user/automation account,
status, error code and message (≤ 500 chars), retry number and version. The
application log records claim, probe, per-asset read timings, gate and
validation results and publication. No secrets or PDF content.

---

## 7. UI specification

### 7.1 Administration App: WiseWatts Admins only (A2–A4, A6, A62, A63, A69, A71, A81–A84, A107, A111; generation also in the customer portal, A113)

Report configuration and all report-management actions sit in the
Administration App, beside site and asset information. This is approved
architecture (A107 and the revision 4 direction §13; it was [DESIGN] in revision
3). It keeps the customer portal and customer-facing APIs read-only for reports,
consistent with A6 and ADR-023.

- **Site → Reporting:** see §5.4.
- **Site → Reports:**
  - Combined history (Type and Status filters) with the columns listed in §7.2,
    plus Actions: Download, Versions, Attempt history, Regenerate, Retry (when
    Failed) and Delete.
  - **Generate report:** type; week picker (snaps to Sun–Sat) or month picker; an
    availability panel (data floor, expected coverage, comparison period); a
    duplicate check offering Regenerate.
  - **Regenerate:** confirmation stating that a new version will be made with
    the settings in force for the period, and that the current version stays
    available until its own expiry.
  - **Delete:** confirmation: "This report and all its versions move to the
    recycle bin. You can restore it until *date*; each version is permanently
    deleted on that date or at its 60-day expiry, whichever is earlier."
  - **Recycle bin:** deleted by/at, per-version permanent deletion dates,
    **Restore**, and **Delete permanently** (A111, approved). Delete permanently
    requires explicit confirmation ("This permanently removes the report and all
    its versions. This cannot be undone.") and is audited. It is offered **only**
    in the recycle bin, for reports already deleted. The report history has no
    permanent-deletion action; its Delete moves the report to the recycle bin.
  - **Attempt history:** time, trigger, status, retry number, reason, user /
    automation account, version.
- **Asset → Reporting settings:** see §5.4.
- Server-rendered forms with the Administration App's existing session and CSRF
  protections. Every write is followed by a confirmation message and an audit
  entry.

### 7.2 Customer portal: Reports → Create report, all profiles (A5, A58, A113, A117)

- **Tabs and site (A117).**
  - Reports opens on **Create report**. **Export data** (existing, unchanged)
    is the second tab, at `?tab=export`; old `?tab=create` links still work.
  - The tab has **no site selector**: it uses the site selected in the
    application sidebar and names it in the header.
  - The tab is visible for enrolled sites to every profile with site access.
    "All times Asia/Kolkata".
- **Generate (A113, A115): Site Admins and WiseWatts Admins only.**
  - The API's `can_generate` decides whether the control is shown. It comes
    from the database's own rule (the schedule read), so the automation account
    is never offered it, and the database decides again on every request.
  - The history loads all types once and filters Type and Status in the
    browser, so the button always knows whether the period has a report.
  - Controls: Type (Weekly / Monthly) and Period (the last 12 ended Sun–Sat
    weeks or the last 3 ended months, in site time), then **Generate report**.
    When the period already has a report, the button is **Generate new
    version**: the earlier versions stay. It is disabled while one is pending.
  - Nothing is requested without this explicit click. This is how a
    historical report is produced.
  - The database's reason is shown when a request is refused: period not
    ended, report in the recycle bin, already pending, or three requests
    already queued.
  - Operators and Viewers see no Generate control.
- **Retrospective baseline (A116):** a "Retrospective baseline" label on
  history rows and in version details, which name the approved baseline and
  state that it is not verified historical operating practice. Settings used
  that came from the baseline are marked.
- **Automatic generation status** (read-only): Weekly and Monthly On/Paused and
  the next first-attempt time.
- **History** (combined):
  - Filters: Type (All/Weekly/Monthly) and Status (All/Pending/Processing/
    Generated/Failed).
  - Columns: Type · Reporting period · Comparison period · Generated · Status
    (+ "Incomplete data" label) · Coverage summary (e.g. "HVAC 99.2 % · Kitchen
    97.8 %") · Version · Expires · **Download**, **Version details**.
  - Polling every 10 s while any row is Pending or Processing.
- **Version details:** generated at, trigger, label, coverage breakdown (A58),
  settings snapshot summary, expiry, Download.
- **"Comparison incomplete"** indicator on rows and in version details when the
  comparison period was incomplete (A109). This is separate from the
  "Incomplete data" label.
- **Failed rows:** the reason text (§7.3). There is no Retry, Delete, Restore
  or permanent deletion in the customer portal (A6, A107). Generation and new
  versions are described above (A113).
- Deleted reports are not shown in the customer portal.

### 7.3 Failure texts

| Code | Text |
|---|---|
| `insufficient_data` | "Not enough EMS data for a reliable report: {details}. No values were invented." |
| `retention_exceeded` | "EMS no longer holds the 1-minute data needed for this period." |
| `automation_not_authorized` | "The WiseWatts automation account is deactivated or no longer has access to this site. Automatic generation has stopped." |
| `pdf_validation_failed` | "The report failed its quality check and was not published." |
| `worker_interrupted` / `generation_failed` | "Generation was interrupted or failed unexpectedly." |

---

## 8. Storage, retention and deletion specification

### 8.1 Tables (migration 329; owned by `ems_admin`, no direct grants)

| Table | Key columns |
|---|---|
| `analytics.site_reports` | `id`, `organization_id`, `site_id`, `report_type`, `period_start_date`, `period_end_date`, `comparison_start_date`, `comparison_end_date`, `latest_version_id`, `state` (ACTIVE/DELETED/PURGED), `deleted_at`, `deleted_by`, `created_at`. `UNIQUE (site_id, report_type, period_start_date)` |
| `analytics.site_report_versions` | `id`, `report_id`, `version_no`, `generated_at`, `generated_by` (NULL = automatic), `automation_portal_user_id`, `trigger`, `expires_at` (= `generated_at + 60 d`, immutable), `purge_at` (computed on delete: `least(expires_at, deleted_at + 7 d)`), `state` (AVAILABLE/EXPIRED/PURGED), `incomplete_data`, `comparison_incomplete`, `coverage` JSONB, `settings_snapshot` JSONB, `engine_version`, `file_name`, `file_size_bytes`, `sha256` |
| `analytics.site_report_files` | `version_id` PK, `content` BYTEA |
| `analytics.site_report_attempts` | `id`, `report_id`, `trigger`, `status` (PENDING/PROCESSING/SUCCEEDED/FAILED), `not_before`, `retry_no`, `requested_by`, `read_identity_portal_user_id`, `worker_id`, `lease_expires_at`, `started_at`, `finished_at`, `error_code`, `error_message`, `version_id`; partial unique index on `report_id` for PENDING/PROCESSING |

### 8.2 Publication (A74–A76, A79, A80)

In one transaction, and only while the lease is held: insert the version (with
SHA-256 and settings snapshot), insert the file, set `latest_version_id`, mark
the attempt SUCCEEDED. There is no update path for content. A failed
regeneration changes nothing, so the previous version stays latest.

### 8.3 Retention (A78)

Each version has `expires_at = generated_at + 60 days`. The purge deletes the
file and marks the version EXPIRED. The latest *available* version is downloaded.
A report whose versions have all expired keeps its row and can be regenerated
while data exists. Report and attempt metadata, which contain no content, are
kept [DESIGN: 365 days].

### 8.4 Deletion, recycle bin, permanent deletion (A81–A87)

- **Delete** (WiseWatts Admin, whole report, confirmation): `state = DELETED`,
  `deleted_at/by`, each version's `purge_at = least(expires_at, deleted_at +
  7 d)`, and an audit event. The report is hidden from history and shown in the
  recycle bin. Delete is refused while an attempt is PROCESSING. Generation of
  that period is blocked while deleted.
- **Restore** (within 7 days of `deleted_at`): `state = ACTIVE`, `purge_at`
  cleared, `expires_at` **unchanged** (A86), and an audit event. A version that
  reached its 60-day expiry while in the bin stays purged.
- **Permanent deletion, automatic** (purge job): each version is deleted at its
  own `purge_at` (A85). When the last version is purged, the report row becomes
  PURGED (a tombstone for audit) and an audit event is written with actor type
  SYSTEM. After that the period may be generated again manually.
- **Permanent deletion, manual** (A111, approved): a WiseWatts Admin may
  permanently delete a report **only while it is in the seven-day recycle bin**
  (state DELETED, before its `purge_at`), after explicit confirmation.
  - All versions and files are removed at once, the row becomes PURGED, and an
    audit event names the user.
  - The DB function refuses any report not in state DELETED, so an ACTIVE
    report cannot be permanently deleted directly from history.
- **Deleting a report vs expiring a version:** deletion acts on the whole report
  and all versions (A81). Expiry acts on one version at its own 60-day mark
  (A78) and never deletes the report or its other versions.

---

## 9. Security, permissions and audit specification

### 9.1 Capability matrix (A1–A7, A12)

| Capability | WiseWatts Admin (ADMIN, GLOBAL) | Radisson Admin (ADMIN, org/sites) | Operator | Viewer |
|---|---|---|---|---|
| Customer portal: view history, versions, coverage; download | ✓ | ✓ | ✓ | ✓ |
| Administration App access (any reporting page) | ✓ | — | — | — |
| Configuration: enrolment, automation account, asset list/groups, setpoints, schedules, operating thresholds, schedule pause/resume | ✓ | — | — | — |
| Customer portal: generate on demand (an ended period, including historical; a new version of an existing report) (A113) | ✓ | ✓ | — | — |
| Report management in the Administration App: generate, historical, regenerate, retry, delete, restore, permanent deletion, recycle bin, attempt history | ✓ | — | — | — |
| Retrospective AHU baseline (A112) | ✓ | — | — | — |
| Data-quality thresholds | code only (WiseWatts) | — | — | — |
| `report.export` (existing) | unchanged | unchanged | unchanged | unchanged |

Every capability is limited to sites the user can access. Permission model:
- New `PortalPermission.REPORT_VIEW` for all roles.
- Management is gated by **"WiseWatts Admin" = active, role ADMIN, scope
  GLOBAL**. This is a scope check, not a role permission, because tenant ADMINs
  hold every role permission today. A `report.manage` permission is therefore
  not introduced.

Radisson Admins' reporting permissions are view, download and on-demand
generation in the customer portal (A113, refining A107). The new role permission
`report.generate` (ADMIN only) gates the customer route and is advertised only
where Reports is enabled. The database (`request_portal_site_report`) requires
an active ADMIN with access to the site, and refuses the site's automation
account. The automation account (A108) is ADMIN in the Radisson organization but
not GLOBAL, so it has no Administration App capability, and it cannot generate
in the portal.

### 9.2 Enforcement (A2, A3, A6, A12; ADR-023 unchanged)

1. **Administration App routes** for reporting require an authenticated
   Administration App session for an active GLOBAL ADMIN. This is checked in the
   route **regardless of `EMS_ADMIN_STAFF_ONLY`**, which is still off on staging
   (ADR-023 stage 4 not started). A tenant ADMIN who could reach the
   Administration App today still gets 403 on every reporting page.
2. **Management and settings functions** (SECURITY DEFINER) re-check active +
   ADMIN + GLOBAL + site access and enrolment, with EXECUTE granted to **`ems_app`
   only**. `ems_customer_api` (ADR-023 decision 5) gets **no** management
   function, so the customer API cannot change anything even if a route were
   added by mistake.
3. **Read functions** (list, version details, download) re-check
   `portal_user_can_access_site` and enrolment, with EXECUTE granted to
   `ems_customer_api` and `ems_app`. Downloads re-check at download time and send
   `Content-Disposition: attachment`, `application/pdf`, `nosniff` and
   `private, no-store`, with a sanitised file name.
4. **Worker functions** (claim, lease, publish, fail, purge, probe state): EXECUTE
   to `ems_app` on staging (A91).
5. No table grants; no `grafana_reader` or `ems_readonly` access
   (postconditions as in migration 309).
6. Other organizations get 404 on every route.

### 9.3 Worker identity and database role (A88–A93)

- On staging the worker connects as `ems_app` through the existing environment
  mechanism. No new credential.
- **Before production:** a dedicated least-privilege `ems_report_worker` role,
  with EXECUTE on the worker and portal read functions only, is a mandatory
  release prerequisite (A92).
- The automation account (A88, A89) is a portal identity used only as the read
  identity; it holds no credential the worker uses. **It is not created in this
  task (A93).** Creating it is a separate authorised step before P10.

### 9.4 Audit (A22, A82, A87)

`admin.audit_events` actions:
`SITE_REPORT_ENROL`, `SITE_REPORT_ROSTER_CHANGE`,
`SITE_REPORT_AUTOMATION_ACCOUNT_CHANGE`, `SITE_REPORT_SCHEDULE_PAUSE`,
`SITE_REPORT_SCHEDULE_RESUME`, `REPORT_SETTING_CHANGE`,
`REPORT_SETTING_WITHDRAW`, `SITE_REPORT_GENERATE`, `SITE_REPORT_REGENERATE`,
`SITE_REPORT_RETRY`, `SITE_REPORT_DELETE`, `SITE_REPORT_RESTORE`,
`SITE_REPORT_PURGE`.

Each event records organization, site, entity, previous and new values, actor
(or SYSTEM), role and time. [ASSUMPTION: no restrictive CHECK on action/entity
values; checked in the migration precheck.]

---

## 10. Testing and acceptance criteria

### 10.1 Test plan

| Area | Tests |
|---|---|
| Regression (A44) | **T-REG-1**: the 97 tool tests ported to `app/tests/report_engine/`, green on the EMS Python 3.12 image, reference figures kept (test-only CSV fixture adapter) |
| Non-regression (NFR-7) | **T-NONREG**: existing backend, DB assertion and web suites green; Export data tab unchanged; no change to telemetry or Analytics functions (diff check) |
| EMS mapping (A29, A30, A15, A51–A55) | **T-MAP-1** recorded portal-read fixtures equal the CSV frames, 11–24 Oct · **T-MAP-2** full-period Power and Temperature reconciliation (read-only, recorded) · **T-MAP-3** 15-min kitchen CSV vs EMS 1-min aggregated · **T-MAP-4** sensor-less assets have no temperature column · **T-MAP-5** 14-day chunk boundaries · **T-MAP-6** GOOD → MEASURED; valid reconstructed → RECONSTRUCTED (value kept); invalid/NULL → MISSING |
| Timestamps (A24–A28) | **T-TS-1** Sat 23:59 / Sun 00:00: the closing reading in the preceding week · **T-TS-2** month ends 31→1, 30→1 · **T-TS-3** Dec→Jan comparison · **T-TS-4** February incl. leap year · **T-TS-5** UTC↔IST +05:30 day boundaries |
| Weekly (A26, A31, A35, A40, A42) | **T-WK-1** EMS-fed run with the CSV-equal window equals the CSV reference except the 3 documented kitchen meters · **T-WK-2** final window including the closing reading · **T-WK-3** % NA for zero/missing comparison, Δ shown · weekly kitchen rule > 10 % and > 25 kWh unchanged (in T-MO-5) |
| Monthly (A33–A39, A43) | **T-MO-1** section and metric set identical to weekly · **T-MO-2** monthly totals vs previous month, Δ and % · **T-MO-3** every monthly daily chart has exactly one series (current month) and no previous-month daily data or day-of-month pairing · **T-MO-4** the PDF text contains no month-length / day-count reference · **T-MO-5** kitchen attention monthly only at > 10 % and > 100 kWh; weekly at > 10 % and > 25 kWh · **T-MO-6** runtime/out-of-hours over a month |
| Content (A15, A21, A59, A60, A95–A97) | **T-RPT-1** weekly sections, charts, tables present · **T-RPT-4** "Not temperature-monitored" · **T-RPT-5** setpoint range display · **T-RPT-6** Data completeness note only when incomplete; never a coverage page · **T-RPT-7** WiseWatts logo, "Radisson Blu Coimbatore", no Radisson logo |
| Historical (A71) | **T-HIS-1** allowed inside floors · **T-HIS-2** refused outside the 90-day floor · **T-HIS-3** comparison partly outside → generated, comparison disclosed · **T-HIS-4** duplicate period refused |
| Data quality (A45–A57, A64–A67) | **T-DQ-1** ≤ 30-min gap filled and flagged GAP_FILLED; longer stays missing · **T-DQ-2** asset-day < 90 % measured → partial (estimated readings do not count) · **T-DQ-3** incomplete at +6 h → Pending; re-check +30 min · **T-DQ-4** data at +8 h → Generated · **T-DQ-5** at +12 h, minimum met → Generated + Incomplete data · **T-DQ-6** HVAC or Kitchen < 80 % (current period) → Failed with explanation · **T-DQ-7** one asset with no data, groups ≥ 80 % → Generated + label + asset identified · **T-DQ-8** temperature never filled · **T-DQ-9** no peak-eligible timestamp → Failed · **T-DQ-10** availability = measured + reconstructed + gap-filled: e.g. 75 % measured + 6 % reconstructed + 2 % gap-filled = 83 % → passes; coverage shows 75 % measured / 8 % estimated (6 + 2) · **T-DQ-11** comparison period 40 % available, current period complete → status Generated, **no** "Incomplete data" label, **no** PDF "Data completeness" note; affected comparison figures marked †; a note beneath each affected table; history and version details show "Comparison incomplete" (A109) · **T-DQ-12** current and comparison both incomplete → "Incomplete data" label + Data completeness note **and** † + table notes + "Comparison incomplete" |
| PDF (A94, A98, A100) | **T-PDF-1** valid weekly/monthly pass · **T-PDF-2** missing section, wrong site/period, blank page, truncated file each rejected · **T-PDF-3** no version on failure · **T-PDF-4** no DOCX produced or exposed · **T-PDF-5** all fonts embedded and Source Sans 3 |
| Retry / duplicates (A61–A63, A68–A73) | **T-RT-1** temporary failure → retries at 15/30/60, max 3 · **T-RT-2** lease lapse re-claim · **T-RT-3** concurrent ticks create one report · **T-RT-4** one active attempt per report · **T-RT-5** defaults on; pause/resume independent; no back-fill; manual still allowed · **T-RT-6** every attempt recorded with trigger, user/automation account, status, reason, version · **T-RT-7** data-quality, automation and retention failures not auto-retried |
| Permissions / isolation (A1–A7, A12, A88–A90) | **T-SEC-1** all four profiles view and download in the customer portal · **T-SEC-2** another organization's user gets 404 everywhere · **T-SEC-3** Radisson Admin, Operator and Viewer have no management capability (customer API exposes none; direct calls of management functions with their uid refused) · **T-SEC-4** Radisson Admin cannot change the asset list/groups (DB refuses non-GLOBAL) · **T-SEC-5** automation account deactivated / site access removed → `automation_not_authorized`, automatic generation stops, no retry · **T-SEC-7** download re-checks access · **T-SEC-8** function security postconditions; `ems_customer_api` has EXECUTE on read functions only · **T-SEC-9** automation account with access to another site, or a personal/non-designated account, refused (A89) · **T-SEC-10** Option A shape (A108): only an active ADMIN / SELECTED_SITES identity in the site's organization whose only site is Coimbatore is accepted; a GLOBAL account or a second site is refused; the account is refused by every management function; an access failure stops the attempt with no automatic retry. At P10, a read-only check confirms the created account has no usable password and the expected scope |
| Administration App (A2–A4, A8, A9, A63, A69) | **T-ADM-1** reporting pages render and save for a WiseWatts Admin · **T-ADM-2** enrolment, roster, initial setpoints, schedules and thresholds entered by a WiseWatts Admin · **T-ADM-3** a tenant (Radisson) ADMIN session gets 403 on every reporting page **with `EMS_ADMIN_STAFF_ONLY` off and on** · **T-ADM-4** generate, historical, regenerate, retry, delete, restore and permanent deletion available to a WiseWatts Admin only, each refused for a tenant ADMIN with `EMS_ADMIN_STAFF_ONLY` off and on (A107, A111) |
| Settings (A13–A23) | **T-SET-1** 24 → 23 °C split per reading by timestamp · **T-SET-2** past effective date rejected by the DB (direct function call) and the form · **T-SET-3** append-only versions + audit (previous/new, effective_from, user, time) · **T-SET-5** existing PDFs byte-identical after a settings change · **T-SET-6** operating thresholds editable by a WiseWatts Admin; data-quality thresholds not editable anywhere · **T-SET-7** future change withdrawn before effect; cannot withdraw once effective · **T-SET-8** effective at save: a change saved at 10:42 applies from 10:42; a reading at 10:41 uses the previous value; a client-supplied timestamp is ignored · **T-SET-9** a future-dated change (e.g. 25-Nov) takes effect at 25-Nov 00:00 Asia/Kolkata (= 24-Nov 18:30 UTC); a 24-Nov 23:59 reading uses the previous value and a 25-Nov 00:00 reading the new one; the form offers no time field and a supplied time is ignored (A110) |
| Versions / retention / deletion (A74–A87) | **T-VER-1** regenerate → v2, v1 downloadable · **T-VER-2** Processing keeps v1 downloadable; failed regeneration leaves v1 latest · **T-VER-3** v1 expires at its own generation + 60 d while v2 remains · **T-VER-4** SHA-256 stable; no update path · **T-DEL-1** delete → hidden, in bin, audited · **T-DEL-2** restore within 7 days; `expires_at` unchanged; audited · **T-DEL-3** version purged at deletion + 7 d when that is earlier · **T-DEL-4** version expiry at 60 d (no deletion) · **T-DEL-5** delete refused while Processing · **T-DEL-6** generation blocked while deleted · **T-DEL-7** a version whose 60 d falls inside the 7-day bin window is purged at its 60 d · **T-DEL-8** multi-version report in the bin: v1 (generated day 0) and v2 (day 55), deleted day 57 → v1 purged day 60, v2 purged day 64; restore on day 61 restores only v2 with its original expiry · **T-DEL-9** manual permanent deletion (A111): WiseWatts Admin only, only from the recycle bin, confirmation required, all versions and files removed, audit names the user; refused for Radisson Admin/Operator/Viewer and for reports not in the bin · **T-DEL-10** a version expiring at 60 d (no deletion) leaves the report and its other versions intact · **T-DEL-11** no permanent-deletion action is rendered in report history; a direct call to the permanent-deletion function for an ACTIVE report is refused; the action without confirmation is refused; a successful permanent deletion writes `SITE_REPORT_PURGE` with the user as actor (A111) |
| UI | **T-UI-1** customer tab: filters, read-only actions, version details, polling (Vitest) · **T-UI-2** exactly four statuses + label · **T-UI-3** coverage summary and breakdown · tsc, eslint, build · Administration App route/template tests · manual exercise locally against staging through the tunnel (CLAUDE.md §4A) |
| DB | `scripts/test/assert_site_report_settings.*`, `assert_site_reports.*` on the disposable integration DB (pre/postconditions, grants, rollback) |
| Retrospective baseline (A112, A114, A116; rev 4.2) | **T-RB-1** a WiseWatts Admin back-dates exactly the in-force AHU versions to 00:00 site time; values unchanged; per-version and baseline audit; no report, no attempt; switches and resume times unchanged; the scheduler creates nothing · **T-RB-2** once per site; a normal back-dated setting is still refused; a back-dated version cannot be withdrawn · **T-RB-3** Radisson Admin, Operator, Viewer, a GLOBAL Operator and an inactive staff account are refused · **T-RB-4** a partial, duplicated or empty version set, today or a future date, > 180 days back, or a missing approval / statement are refused and nothing is written · **T-RB-5** refused when it would override an earlier version (history conflict) · **T-RB-6** the customer API cannot apply a baseline or read its table · **T-RB-7** engine: baseline + identical 19 Nov 08:13 version gives the same figures as one version since 1 Oct (week 15–21 Nov); November fully configured; October discloses the unconfigured September comparison · **T-RB-8** worker end to end: snapshot `retrospective_baseline` block, per-setting flags, the PDF "Reporting settings basis" note with "not independently verified historical hotel operating practice", engine 1.2.0, history flag |
| On-demand generation (A113, A115; rev 4.2) | **T-OD-1** Site Admin and WiseWatts Admin generate (HISTORICAL trigger for an old period), audited with channel CUSTOMER_PORTAL, valid read identity · **T-OD-2** Operator, Viewer, another organization, a GLOBAL Operator and an inactive account are refused, and nothing is created · **T-OD-3** the designated automation account is refused · **T-OD-4** an existing report gets a new version; v1 is unchanged (sha256, snapshot) and still downloadable · **T-OD-5** refusals: period not ended, invalid period/type, not enrolled, in the recycle bin, already pending, queue of 3 · **T-OD-6** a requester who loses the ADMIN role → `requester_not_authorized` · **T-OD-7** routes: 202 for Admins, 403 for Operator/Viewer, cross-origin 403, non-JSON 415, invalid body 422, inaccessible site 404, the database message returned; `report.generate` only for ADMIN and only where Reports is enabled; the worker publishes a Site Admin's request |
| UI (rev 4.2) | **T-UI-7** Create report is the default tab; `?tab=export` and old `?tab=create` links; no site selector, the sidebar site named · **T-UI-8** the Generate form only when `can_generate`; ended periods only (Sun–Sat weeks, months); explicit click posts `{report_type, period_start}`; "Generate new version" for an existing period; the database refusal shown · **T-UI-9** "Retrospective baseline" label and tooltip |

### 10.2 Acceptance criteria

- **AC-1:** On staging, a WiseWatts Admin generates the Radisson weekly PDF for a
  completed week and the monthly PDF for a completed month from EMS data only.
- **AC-2:** The T-WK-1 comparison report: EMS-fed figures equal the CSV reference
  except the documented 15-minute kitchen meters.
- **AC-3:** An automatic weekly report is produced via the automation account
  without user action: first check ≥ +6 h, outcome by +12 h (+ generation time).
- **AC-4:** Radisson Admin, Operator and Viewer view and download in the customer
  portal, with no management actions; a Radisson Admin is refused on every
  Administration App reporting page; another organization sees nothing.
- **AC-5:** Settings changes take effect at save time for today and at 00:00 site
  time for future dates (A110); past dates are rejected; history and audit are
  complete.
- **AC-6:** Delete → restore → delete → purge follows A81–A87 per version, with
  audit, verified with time-controlled tests (T-DEL-8). Manual permanent
  deletion from the recycle bin (A111) is audited.
- **AC-6c:** Permanent deletion is possible only from the recycle bin, after
  explicit confirmation, and is audited. Report history offers no permanent
  deletion, and the DB refuses it for active reports (A111).
- **AC-6a:** A report with a complete current period and an incomplete
  comparison period is Generated without the "Incomplete data" label, with †
  markers, notes beneath the affected tables, and "Comparison incomplete" in
  history (A109).
- **AC-6b:** The automation account checks (A108) run on every attempt; an
  access failure stops generation without automatic retry.
- **AC-7:** Regeneration preserves versions and publishes only validated PDFs.
- **AC-8:** The monthly PDF has the weekly sections, monthly total comparisons,
  current-month-only daily charts, no month-length text, and the 100 kWh kitchen
  rule.
- **AC-9:** No production change; existing EMS behaviour unchanged (T-NONREG).
- **AC-10:** The traceability matrix (§2) maps every A/S decision to passing
  tests or reviewed behaviour.

Revision 4.2 (A112–A117). AC-4 is amended by AC-13: a Radisson Admin may now
generate in the customer portal.

- **AC-11 (A112):**
  - A WiseWatts Admin can record the Coimbatore retrospective AHU baseline
    effective 1 Oct 2026 00:00 IST, once.
  - Exactly the approved setpoints, schedules and OFF/ON thresholds are copied
    unchanged; there is no STANDBY threshold.
  - The approval, actor, effective date and every affected setting are audited.
  - Anyone else is refused, as are any other version set and any date outside
    the allowed window.
  - A normal back-dated setting is still refused (A18).
- **AC-12 (A114):** Applying migration 330 and the baseline creates no report or
  attempt and leaves the weekly/monthly switches and resume times unchanged.
- **AC-13 (A113):** In the customer portal:
  - A Site Admin and a WiseWatts Admin can generate a report for an ended
    period, and a new version of an existing one, with earlier versions
    unchanged and downloadable.
  - Operators and Viewers see no Generate control and get 403 from the API
    and `site_report_generate_forbidden` from the database.
  - Cross-origin and non-JSON requests are refused.
  - Every request is audited with channel `CUSTOMER_PORTAL`.
- **AC-14 (A115):** A historical report exists only after a user's explicit
  Generate request. The automatic schedule never back-fills, as before.
- **AC-15 (A116):** A version that used baseline settings:
  - carries the `retrospective_baseline` snapshot block;
  - states the basis in the PDF ("not independently verified historical hotel
    operating practice", "no telemetry or temperature was added or altered");
  - shows "Retrospective baseline" in history.
  Its figures across the baseline → 19 Nov 08:13 boundary equal a single
  version in force since 1 Oct. October discloses its unconfigured September
  comparison.
- **AC-16 (A117):** Reports opens on Create report. There is no site selector;
  the sidebar's site is used.

---

## 11. Implementation sequence

Each phase ends with tests green, a coherent local commit, and a short report.
Nothing is merged or deployed without your explicit approval.

| Phase | Content | Gate |
|---|---|---|
| P0 | Review of revision 4 (all product questions closed) | **Your approval to implement** |
| P1 | Engine extraction to `app/src/report_engine/`; 97 tests ported; Python 3.12 | 97/97; reference figures identical |
| P2 | EMS loader with reading classes (A51–A55); recorded staging fixtures (read-only); T-MAP, T-WK-1 | Comparison report vs the CSV reference |
| P3 | Periods, effective-at-save settings resolution, monthly content, gate, comparisons | T-TS, T-MO, T-DQ, T-SET (engine) |
| P4 | ReportLab renderer, Source Sans 3, branding, validator | **Your visual sign-off of sample weekly and monthly PDFs** |
| P5 | Migrations 328 (profiles, roster, settings) and 329 (reports, versions, files, attempts) + DB assertions | DB tests; migration impact note |
| P6 | Worker / scheduler / purge; compose service (profile `reports`); read-only API; permissions | Backend tests |
| P7 | Administration App reporting pages (configuration + report management) | T-ADM, route tests |
| P8 | Customer-portal Create report tab (read-only) | Vitest / tsc / eslint / build |
| P9 | PR to `staging`; CI. **Your approval to merge**: this deploys 328/329, the new service and the staging deploy workflow change (C11) via CI/CD | Staging deploy green |
| P10 | **Separately authorised:** creation of the dedicated automation account (A93). Then WiseWatts enrolment, roster, settings and automation designation; read-only verification; acceptance report covering the first brief's 12 items | **Your acceptance** |

Documentation (C12) is updated within each phase.

---

## 12. Risk, assumption and dependency register

| ID | Item | L / I | Mitigation |
|---|---|---|---|
| RK-1 | 1.9 GB staging host; pandas, matplotlib and monthly data | M / H | `mem_limit` ≈ 600 MB, float32, needed columns only, one job at a time; peak RSS measured in P2 |
| RK-2 | DB read time ≈ 8 min weekly / ≈ 35 min monthly | M / M | Sequential bounded calls, off-peak, kitchen measurement reads skipped |
| RK-3 | 90-day 1-minute measurement retention limits historical reports | H / M | Availability check, clear refusal |
| RK-4 | Automation identity, Option A (A108) trade-off: a Radisson-organization ADMIN identity, classified by EMS as a customer-organization account and possibly listed among Radisson's users | Certain / M | No usable password; never signs in; per-attempt checks (scope SELECTED_SITES = Coimbatore only); every management function requires GLOBAL; purpose recorded in ADR-025 and the runbook; creation separately authorised (A93) |
| RK-4a | [ASSUMPTION] EMS account provisioning can create an identity with no usable password (e.g. a random high-entropy secret generated and never disclosed) | M / L | Confirmed at account creation (P10); if the provisioning tools require a handed-over password, stop and ask before creating it |
| RK-5 | `EMS_ADMIN_STAFF_ONLY` is off on staging, so a tenant ADMIN can sign in to the Administration App today | M / H | Reporting routes and functions check GLOBAL themselves (§9.2, T-ADM-3); ADR-023 stage 4 unchanged |
| RK-6 | Image size +150–200 MB for every `APP_IMAGE` service (pandas, numpy, matplotlib, reportlab, pypdf, pypdfium2, ~2 MB of Source Sans 3 fonts) | H / L | Engine imported only by the worker entry point |
| RK-7 | CI/CD change: staging deploy must start `report-worker`; production must not | M / M | Compose profile; staging-only enablement; approval at P9 |
| RK-8 | Migrations 328/329 join the shared chain; production needs `ems_report_worker` first (A92) | M / M | Additive; feature off on production; release prerequisite recorded |
| RK-9 | Tool tested on Python 3.14; EMS image is 3.12 | M / L | T-REG-1 on 3.12 |
| RK-10 | Timestamp residual (*T*+49 s sample) | L / L | Results equal the reference (E2.4) |
| RK-11 | 3 kitchen meters differ from the reference (EMS more complete) | Certain / L | Documented in the comparison report |
| RK-12 | Staging pipeline lag → frequent Pending/incomplete | M / M | 12 h deadline, labels, coverage |
| RK-13 | Exact EMS reconstruction flag semantics (A52) | M / M | Pinned by a DB test in P2 before use [ASSUMPTION] |
| RK-14 | `admin.audit_events` accepts the new action values | L / L | Migration precheck [ASSUMPTION] |
| RK-15 | Settings start empty until WiseWatts enters them; until then no deviation/out-of-hours/runtime | Certain / M | Missing-configuration behaviour (5.3); a configuration-completeness indicator on Site → Reporting |
| D-1 | Your approval to implement (P0) | — | Blocks P1 |
| D-2 | Approval to merge/deploy to staging (P9) | — | — |
| D-3 | Separately authorised creation of the automation account (A93) | — | Needed by P10 |
| D-4 | A Radisson-scoped test account on staging (Admin/Operator/Viewer) for the permission checks | — | Needed by P10 |

---

## 13. Open questions — closed; remaining review items

**There are no open product questions.** The revision 2 questions TQ1–TQ7
were resolved in revision 3 (§2.4). The revision 3 questions OQ1–OQ4 were
approved by the product owner in revision 4 and are closed (§2.5: A107–A110).

The items below are not product decisions. They are listed so that nothing is
silently resolved.

| Type | Item | Handling |
|---|---|---|
| Assumption | Exact EMS columns that identify a valid reconstructed energy bucket (A52) | Pinned by a DB test in P2 before use (RK-13) |
| Assumption | `admin.audit_events` accepts the new action values | Migration precheck (RK-14) |
| Assumption | An account with no usable password can be provisioned (A108) | Checked at P10; stop and ask if not (RK-4a) |
| Assumption | PDF size about 1–2 MB | Confirmed at first render |
| Not yet done (implementation test, not evidence) | Full-period Power and Temperature reconciliation; only sample values have been compared so far (evidence E2.2, E2.4) | T-MAP-2 in P2 (A30) |
| Separate approvals (not given by this document) | Approval to implement (P0); merge to staging including the deploy-workflow change (P9); creation of the automation account (P10, A93); the `ems_report_worker` role and any production deployment (A92, A106) | Requested at the relevant phase |

No contradiction remains between the PRD, decision register, architecture, API,
UI, database, tests and acceptance criteria (cross-checked for revision 4).
The evidence file needed no correction.

---

## 14. Change inventory

| ID | Component | Reuse | New | Files likely created / modified | API | DB | Dependencies | Risks |
|---|---|---|---|---|---|---|---|---|
| C1 | Report engine | Tool calculation, chart and runtime code | Periods, settings resolution, reading classes, monthly content, gate, ReportLab renderer, validator, branding | `app/src/report_engine/{model,prepare,metrics,summary,runtime,charts,periods,settings,quality,render_pdf,validate_pdf,branding}.py`; `app/src/report_engine/fonts/SourceSans3-*.ttf` + `OFL.txt` | — | — | pandas, numpy, matplotlib, reportlab, pypdf, pypdfium2 (`app/requirements.txt`); Source Sans 3 (OFL 1.1, vendored) | RK-6, RK-9 |
| C2 | EMS loader | Existing fetch functions | Chunked loader with reading classes | `app/src/report_engine/ems_loader.py` | — | — | — | RK-2, RK-13 |
| C3 | Settings | `admin.audit_events` | Profiles, roster, effective-at-save setting versions, functions | `postgres/migrations/328_site_report_settings.sql`, `scripts/test/assert_site_report_settings.{sql,sh}` | — | 3 tables, about 10 functions (EXECUTE `ems_app`) | — | RK-4, RK-5 |
| C4 | Report store | Migration 309 pattern | Reports, versions, files, attempts, purge; read functions | `postgres/migrations/329_site_reports.sql`, `scripts/test/assert_site_reports.{sql,sh}` | — | 4 tables, about 18 functions (reads: `ems_customer_api` + `ems_app`; management/worker: `ems_app`) | — | RK-8 |
| C5 | Worker / scheduler | `ReportExportWorker` structure | Scheduler, probe, runner, retries, purge, automation identity checks | `app/src/report_worker_main.py`, `app/src/site_report_worker.py`, `app/src/site_report_service.py`, `app/src/config.py` | — | — | — | RK-1, RK-2 |
| C6 | Read-only report API | Router and guard patterns | `GET /api/v1/sites/{site_id}/reports`, `…/reports/{id}`, `…/reports/{id}/versions/{version_id}`, `…/versions/{version_id}/download`, `…/reports/schedule-status` | `app/src/routers/site_reports.py`, `app/src/customer_main.py`, `app/src/main.py` | GET only | — | — | — |
| C7 | Administration App reporting pages | Site and asset detail templates, staff session, CSRF | Site → Reporting, Site → Reports (management, recycle bin, attempts), Asset → Reporting settings | `app/src/templates/site_reporting.html`, `site_reports.html`, `asset_reporting.html`, admin reporting routes (new router module) | Admin form routes (POST, CSRF) | — | — | RK-5 |
| C8 | Customer-portal tab | `ReportsPage.tsx`, provider, styles | Sub-tabs; read-only history, version details, download | `web/src/routes/reportExports/ReportsPage.tsx`, `web/src/routes/reports/createReport/*`, `web/src/api/siteReports.ts`, tests | consumes C6 | — | — | — |
| C9 | Permissions | `PortalPermission` | `REPORT_VIEW`; WiseWatts Admin (GLOBAL ADMIN) helper | `app/src/auth/authorization.py`, web permission helpers | — | scope checks in functions | — | — |
| C10 | Tests | Existing suites | §10 | `app/tests/report_engine/*`, `app/tests/test_site_report_*.py`, `scripts/test/assert_site_report*`, `web/src/routes/reports/createReport/*.test.tsx`, fixtures | — | — | — | — |
| C11 | Compose / CI | One `APP_IMAGE` | `report-worker` service (profile `reports`, `mem_limit`) | `compose.yaml`, `.github/workflows/deploy-staging.yml` (staging only) | — | — | — | RK-7 (approval at P9) |
| C12 | Documentation | docs structure | Feature doc, ADR-025 (reporting engine, PDF, automation identity), decision log, operations runbook. **ADR-023 is referenced but not amended** (A12) | `docs/07-features/create-report/*`, `docs/00-governance/decisions/ADR-025-…md`, `docs/00-governance/decision-log.md`, `docs/10-operations/…` | — | — | — | — |

**Not changed:** telemetry pipeline, Analytics read functions, Reports export,
Grafana, MQTT, ADR-023, production configuration, and existing permission
semantics.
