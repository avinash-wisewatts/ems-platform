# Export — Reports tab site measurement export

Status: IMPLEMENTED (2026-10-24, migration 309); staging deployment in progress · Owner: Product + Engineering
Decisions: [ADR-014](../../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md) (Amendment 2), [ADR-022](../../00-governance/decisions/ADR-022-analytics-v1-scope-and-contract.md) (the series exported), [ADR-019](../../00-governance/decisions/ADR-019-analytical-backbone-time-basis-and-tiers.md) (resolutions and windows), [ADR-007](../../00-governance/decisions/ADR-007-analytics-api-boundary.md) (API boundary)

## Purpose

Let a customer download all available measurement data for every asset of
a site over a date/time range, for use outside the EMS. The Energy
screen's contextual chart export (ADR-014 Amendment 1) is separate and
unchanged.

## User experience

- **Navigation**: `Reports` in the primary sidebar, directly below
  `Alerts`, at `/app/reports` (gated on `report.export`, which every role
  holds today). The Archive section's Site Performance Report
  (`/features/reports`, ADR-015) is a different feature and unchanged.
- **Controls**: Site (the global site selection, as on the Analytics page),
  the Analytics date-range control (quick ranges, calendar, optional time
  of day, site timezone, bounded by the site's earliest data), Resolution
  (Auto, 1 minute … 1 day; Auto and the maximum windows as Analytics).
- **Estimate**: asset count, range and resolved resolution, and whether the
  export downloads now, runs in the background, or is too large.
- **Export**: small exports download immediately; larger ones are queued.
  The Background exports table lists the user's jobs with status
  `Queued` / `Processing` / `Completed` / `Failed` (and `Expired`), the
  download link while the file is available, the failure message, and
  `Retry` for failed jobs.
- **Notification**: on every page, a notification "Your export is ready"
  with a `Download ZIP` link (or "Export failed" with the message), plus a
  count badge on the Reports nav entry, until dismissed (dismissal is
  remembered per browser).

## File format

One ZIP, `<site>_<local start>_<local end>_<resolution>.zip`, containing one
CSV per site asset (every asset `GET /sites/{id}/assets` lists), named by
asset name (characters invalid in file names replaced, duplicates numbered
`Name (2).csv`). Each CSV (UTF-8 with BOM, CRLF):

- `Timestamp (UTC)`, `Timestamp (Site Local)` — bucket start,
  `YYYY-MM-DD HH:MM:SS`; the local time follows DST (the UTC column
  disambiguates repeated local hours); UTC is used if the site has no
  timezone.
- One column per Analytics series of the asset, System first then each
  phase the asset has fully assigned: e.g. `Energy (kWh)`, `Power (kW)`,
  `Power L1 (kW)`, `Line to Line Voltage L12 (V)`. Values: bucket sum for
  Energy, bucket mean for measurements, up to 6 decimals.
- A missing reading is an empty cell. An asset with no data in the range
  (or no assigned data points) is a header-only CSV — never omitted.
- Header text is CSV-escaped and formula-injection guarded.

Known gap (ADR-014 decisions 3/10/11): per-cell data-quality state is not
exported — open Product question.

## Architecture

- **Reads**: only the portal-scoped Analytics functions the Analytics page
  uses (catalogue, `get_portal_asset_energy_series`,
  `get_portal_asset_point_series`, retention floors), keyed on the
  requesting user — for a background job, the job's owner, re-checked at
  run time. One asset at a time; at most 9 series per read.
- **API** (additive, `app/src/routers/report_exports.py`, every route
  requires `report.export` server-side):
  `GET /api/v1/sites/{id}/report-exports/estimate`,
  `GET /api/v1/sites/{id}/report-exports/file` (immediate ZIP),
  `POST /api/v1/sites/{id}/report-exports` (queue),
  `GET /api/v1/report-exports`, `GET /api/v1/report-exports/{job_id}`,
  `POST /api/v1/report-exports/{job_id}/retry`,
  `GET /api/v1/report-exports/{job_id}/file`. The two POSTs write only the
  caller's own job records; they require `application/json` and reject
  `Sec-Fetch-Site: cross-site`. Another user's job, or a job whose site the
  user can no longer access, is 404; an expired file is 410. Downloads are
  `attachment` + `Cache-Control: no-store`.
- **Jobs and storage** (migration 309): `analytics.report_export_jobs` and
  `analytics.report_export_files` (ZIP as `bytea`), reachable only through
  SECURITY DEFINER functions granted to `ems_app`. No new service, queue or
  object store: the admin-portal process runs one in-process worker
  (`app/src/report_export_worker.py`) that claims jobs with
  `FOR UPDATE SKIP LOCKED` and a 10-minute lease (extended after each
  asset); a job interrupted by a restart is reclaimed, at most 3 attempts,
  then `FAILED` (`worker_interrupted`). The same worker purges expired files
  every 10 minutes and deletes job rows after 30 days.
- **Notifications**: the shell polls `GET /api/v1/report-exports` every 5 s
  while a job is active, otherwise every 60 s (no push channel exists).

## Operations

| Setting (`app/.env`) | Default | Meaning |
|---|---|---|
| `EMS_REPORT_EXPORT_RETENTION_HOURS` | 24 | How long a completed file is downloadable (1–720). |
| `EMS_REPORT_EXPORT_IMMEDIATE_MAX_CELLS` | 150000 | Largest export (buckets x columns) downloaded in the request. |
| `EMS_REPORT_EXPORT_MAX_CELLS` | 3000000 | Largest export accepted as a background job. |
| `EMS_REPORT_EXPORT_MAX_ACTIVE_JOBS` | 3 | Queued + processing jobs per user (HTTP 429 beyond). |
| `EMS_REPORT_EXPORT_WORKER_ENABLED` | true | Run the in-process worker. |
| `EMS_REPORT_EXPORT_POLL_SECONDS` | 5 | Worker idle poll interval. |

ZIPs are held in the database until purged; with the defaults a file is a
few MB at most. Rollback: migration 309's header.

## Validation

- Backend: `app/tests/test_report_export_service.py`, `_routes.py`,
  `_worker.py`, `_jobs_db.py` (real database: owner/tenant isolation,
  active-job limit, claim/lease/attempts, holder-only completion, expiry,
  purge, grants), `_migration_manifest.py`.
- Frontend: `web/src/routes/reportExports/ReportsPage.test.tsx`,
  `web/src/reportExports/ReportExportsProvider.test.tsx`, client helpers.
- Local end-to-end (2026-10-24, disposable test database): immediate ZIP,
  background job Queued → Completed, owner download, anonymous 401,
  other-organization user 404, failed-job retry.
- Staging: see the PR / deployment record.
