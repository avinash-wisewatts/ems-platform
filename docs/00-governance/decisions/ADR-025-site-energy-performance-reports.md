# ADR-025: Reports → Create report — weekly and monthly site energy-performance PDF reports generated from EMS data

Status: Decided (Product Owner, planning package revision 4.1, decisions
A1–A111 + status set, 2026-11-19); **implemented** on branch
`feature/reports-create-report` (migrations 328–329, report worker, engine,
Administration App pages, customer-portal tab) for **staging only**. Not
approved for production (A106): migrations 328/329 are staging/test-scoped
and the report worker is started only by the staging deployment. The
dedicated automation account (A108) is **not created** (A93) — automatic
generation fails clearly until it exists and is designated.

Scope: Radisson Blu Coimbatore (A105).

## Context

WiseWatts produced the Radisson Blu Coimbatore weekly EMS performance report
with a local Streamlit tool fed by 23 CSV files manually exported from
Eniscope; it produced a Word document. EMS already holds the same telemetry
(planning evidence E2: 20 of 23 assets identical to 0.0001 kWh over 14 days;
the other three were 15-minute CSV exports that EMS holds at 1 minute).

The authoritative specification is
[docs/07-features/create-report/README.md](../../07-features/create-report/README.md)
(revision 4.1). This ADR records the architecture.

## Decision

1. **EMS is the only data source.** A report reads the period's 1-minute
   Energy, Power and Temperature through the existing portal-scoped Analytics
   functions (`get_portal_asset_energy_series`, `get_portal_asset_measurements_1m`,
   `get_portal_analytics_catalog`) as a read identity, never from files
   (A29, A30). `bucket_start` is converted to the site timezone without
   shifting (evidence E2.4). No new read path into telemetry is added.
2. **The reference tool's method is kept** (A31, A44): ported into
   `app/src/report_engine/` (prepare, metrics, runtime, charts). The ported
   engine reproduces every pinned figure of the reference tool (T-REG-1) and,
   fed with EMS data for 11–24 Oct 2026, matches the CSV reference except
   the three documented 15-minute kitchen meters (T-WK-1,
   [implementation evidence](../../07-features/create-report/evidence-2026-11-19-implementation.md)).
3. **PDF only** (A94): ReportLab layout, Source Sans 3 embedded in text and
   charts (A98), WiseWatts logo and colours, "Radisson Blu Coimbatore"
   (A95–A97). No Word output, no LibreOffice. Every PDF is validated before
   publication (A100): opens, renders every page non-blank, contains the
   site, the exact periods, every required section and table header, the
   expected charts, and only embedded Source Sans 3 fonts.
4. **Dedicated worker** (`report-worker` compose service, same immutable
   `APP_IMAGE`, profile `reports`, memory-capped, one job at a time): schedules
   due reports (no back-fill, A70), waits for late data (+6 h first check,
   30-minute re-checks, +12 h deadline, A64–A67), generates, validates,
   publishes atomically, retries temporary failures at 15/30/60 minutes
   (A68), purges expired and recycle-bin versions (A78, A85).
5. **Storage in the EMS database** (A77), following the migration 309
   pattern: `analytics.site_reports` / `site_report_versions` /
   `site_report_files` (BYTEA) / `site_report_attempts`, reached only through
   SECURITY DEFINER functions with pinned `search_path`.
6. **Access** (A1–A7, A12, A107): reporting configuration and every
   report-management action are WiseWatts Admin only (active `ADMIN`,
   `GLOBAL` scope) in the staff-only Administration App, checked in the
   route regardless of `EMS_ADMIN_STAFF_ONLY` **and** in every database
   function. Every profile with site access views and downloads in the
   customer portal through four read-only functions — the only report
   functions the `ems_customer_api` role may execute. ADR-023 is unchanged.
7. **Settings** (A13–A23, A110): per asset, append-only, effective-dated;
   "today" takes effect at the save instant, a future date at 00:00 site
   time, a past date is refused by the database; each reading uses the
   setpoint in force at its timestamp; every change is audited; every PDF
   version stores the settings snapshot it used and its SHA-256.
8. **Automation identity** (A88–A90, A108, Option A): a WiseWatts-controlled
   ADMIN in the Radisson organization with `SELECTED_SITES` = {Coimbatore}
   and no usable password, designated on the site profile and checked on
   every attempt; an access failure stops the attempt without automatic
   retry. On staging the worker connects as `ems_app` (A91); a dedicated
   least-privilege `ems_report_worker` role is a production prerequisite (A92).

## Consequences

- The report engine's dependencies (pandas, numpy, matplotlib, reportlab,
  pypdf, pypdfium2, pillow; ~150–200 MB) are in the shared application image
  but imported only by the worker; the web processes never import them
  (tested).
- Historical generation is bounded by the 90-day 1-minute measurement
  retention (A71); older periods are refused with a clear reason.
- The Administration App's existing authentication middleware now maps
  `POST /administration/site-reports/*` to `site.manage` (as
  `/administration/sites/*`); the route and database add the WiseWatts Admin
  requirement on top.

## Amendment 1 (2026-11-21): retrospective AHU baseline and customer-portal generation

Product Owner, planning package revision 4.2, decisions A112–A117; migration
330 (staging/test only); engine 1.2.0.

1. **Retrospective AHU reporting baseline (A112, A114).**
   - What it is: one WiseWatts-approved baseline per site. For Radisson Blu
     Coimbatore, the approved AHU setpoints, operating schedules and OFF/ON
     thresholds are treated as in force from 1 Oct 2026, recorded in
     `analytics.site_report_retrospective_baselines`.
   - How it is applied: `analytics.apply_site_report_retrospective_baseline`,
     by a WiseWatts Admin. The function copies exactly the in-force AHU
     versions, unchanged, refuses to override recorded history, and audits
     every version.
   - Scope of the exception: it supersedes "settings are never back-dated"
     (A17/A18) for this baseline only. The normal setting path still refuses
     past dates.
   - What it is not: a reporting baseline, **not** verified historical hotel
     operating practice.
   - What it does not do: applying it generates no report and changes no
     schedule.
2. **On-demand generation in the customer portal (A113, A115).**
   - Who: Site Admins and WiseWatts Admins (role ADMIN; new permission
     `report.generate`). Operators and Viewers stay view/download only.
   - How: `POST /api/v1/sites/{site_id}/site-reports`, same-origin JSON,
     backed by `analytics.request_portal_site_report`. That function is
     executable by `ems_customer_api` and re-checks an active ADMIN with site
     access, never the automation account.
   - What it creates: a report for an ended period, or a new version of an
     existing one. Historical reports are produced only by such an explicit
     request. The automatic schedule is unchanged.
   - Read identity: `site_report_read_identity_problem` now accepts the
     requester while they are still allowed to generate.
   - Still Administration App only, for WiseWatts Admins: retry, delete,
     restore, permanent deletion and all configuration. ADR-023 is unchanged:
     the customer API mounts no administration route.
3. **Labelling (A116).**
   - Settings snapshots mark baseline-derived settings and carry a
     `retrospective_baseline` block.
   - The PDF carries a "Reporting settings basis" note.
   - History shows "Retrospective baseline".
   - Existing PDF versions are never modified.
4. **UI (A117).** Create report is the default Reports tab. The site comes from
   the application sidebar; the tab has no site selector.

Rollback: `postgres/maintenance/330_site_report_retrospective_baseline_rollback.sql`,
run before the 328/329 rollback.

## DDS change-control note

No new DDS core concept is introduced. Report records, versions, files and
attempts are application/process records (like the migration 309 export
jobs), not domain concepts. The reporting roster and the per-asset
setpoints, operating schedules and operating thresholds are configuration
attributes of the existing **Asset** concept, scoped to one reporting use
and versioned in time; they do not model a new entity, relationship or
calculation. This classification was not part of the approved planning
package and is recorded here for Product Owner review.

## Rollback

Amendment 1 first: `postgres/maintenance/330_site_report_retrospective_baseline_rollback.sql`
(deletes baseline-derived setting versions and the baseline records; restores
the migration 329 read-identity rule and history read). Then
`postgres/maintenance/328_329_site_reports_rollback.sql` (destructive: drops
all report data and reporting settings; audit events are kept), after
deploying an image without the feature and stopping `report-worker`.
