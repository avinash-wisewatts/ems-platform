# Export — Reports tab site measurement export

Status: IMPLEMENTED (2026-10-24, migration 309); deployed to staging 2026-10-24; not deployed to production; UI acceptance testing outstanding. Asset selection and 14-day 1-minute exports (migration 312, ADR-014 Amendment 3) implemented 2026-10-24, not merged or deployed · Owner: Product + Engineering
Decisions: [ADR-014](../../00-governance/decisions/ADR-014-q75-export-scope-and-behavior.md) (Amendment 2), [ADR-022](../../00-governance/decisions/ADR-022-analytics-v1-scope-and-contract.md) (the series exported), [ADR-019](../../00-governance/decisions/ADR-019-analytical-backbone-time-basis-and-tiers.md) (resolutions and windows), [ADR-007](../../00-governance/decisions/ADR-007-analytics-api-boundary.md) (API boundary)

## Purpose

Let a customer download all available measurement data for up to 10
selected assets of a site over a date/time range -- at 1 minute for up to
14 days -- for use outside the EMS. The Energy
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
  (Auto, 1 minute … 1 day; Auto and the maximum windows as Analytics,
  except 1 minute: up to 14 days).
- **Assets** (ADR-014 Amendment 3): the Analytics asset selector (search,
  group by Space / Asset Type, Select All / Clear All), at most 10 assets.
  A site with 10 or fewer assets starts with every asset selected; a larger
  site starts with none and asks for a selection (Select All fills to 10).
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
CSV per selected asset (without a selection, every asset
`GET /sites/{id}/assets` lists, at most 10), named by
asset name (characters invalid in file names replaced, duplicates numbered
`Name (2).csv`). Each CSV (UTF-8 with BOM, CRLF):

- `Timestamp (UTC)`, `Timestamp (Site Local)` — bucket start,
  `YYYY-MM-DD HH:MM:SS`; the local time follows DST (the UTC column
  disambiguates repeated local hours); UTC is used if the site has no
  timezone.
- One column per series of every data point confirmed for the asset
  (`metadata.asset_points`, as listed by the asset's Analytics catalogue):
  - the Analytics chart data points first, exactly as the Analytics page
    serves them — System, then each phase the asset has fully assigned:
    e.g. `Energy (kWh)`, `Power (kW)`, `Power L1 (kW)`,
    `Line to Line Voltage L12 (V)`;
  - then every other confirmed point, one column per assigned qualifier,
    named by its catalogue name: e.g. `Temperature (degC)`,
    `Relative Humidity (%)`, `Occupancy Activity`, `Illuminance (lux)`,
    `Apparent Power (kVA)`, `Current NEUTRAL (A)`. Register points other
    than System Energy (per-phase Energy, Apparent Energy, …) have no
    1-minute source and are not 1-minute columns.
  Values: bucket sum for Energy / register points, bucket mean for
  measurements (as converted by the read layer), up to 6 decimals.
- One row per bucket of the range (at 1 minute, every minute: 20,160 rows
  for 14 days). A missing reading is an empty cell. An asset with no data in the range
  (or no assigned data points) is a header-only CSV — never omitted.
- Header text is CSV-escaped and formula-injection guarded.

Known gap (ADR-014 decisions 3/10/11): per-cell data-quality state is not
exported — open Product question.

## Architecture

- **Reads**: only the portal-scoped Analytics functions the Analytics page
  uses (catalogue, `get_portal_asset_energy_series`,
  `get_portal_asset_point_series`, retention floors), keyed on the
  requesting user — for a background job, the job's owner, re-checked at
  run time. One asset at a time; at most 9 series per read. **1 minute**
  (migration 312): every measurement column of an asset comes from ONE
  call of `analytics.get_portal_asset_measurements_1m`, which reads
  `telemetry.normalized_points` once per bound device on the existing
  `(device_id, event_time)` index and returns wide rows (one per minute);
  values follow `get_portal_asset_point_series` at 1m exactly (GOOD-sample
  mean, field-mapping units, asset_points windows, capture-policy and
  retention-floor gating), proven against it in
  `test_report_export_asset_selection_1m_db.py`. System Energy still comes
  from the persisted Energy tier. Why: the generic read probes by
  `(logical_point_id, time)`, which on staging volumes costs tens of
  seconds per series-day (measured 2026-10-24: 9 points x 1 day did not
  finish in 90 s); the device-keyed read served 58 points x 14 days of one
  Coimbatore meter in 2.9 s, and the 14-day 1m System Energy read took
  1.1 s. No index was added (the `normalized_points` identity-index
  decision, draft migration 296, is unchanged). The Analytics
  chart registry (`ANALYTICS_DATA_POINTS`) decides what the Analytics page
  charts; it does not limit the export, whose columns come from the asset's
  confirmed catalogue points.
- **API** (additive, `app/src/routers/report_exports.py`, every route
  requires `report.export` server-side):
  `GET /api/v1/sites/{id}/report-exports/estimate`,
  `GET /api/v1/sites/{id}/report-exports/file` (immediate ZIP),
  `POST /api/v1/sites/{id}/report-exports` (queue),
  `GET /api/v1/report-exports`, `GET /api/v1/report-exports/{job_id}`,
  `POST /api/v1/report-exports/{job_id}/retry`,
  `GET /api/v1/report-exports/{job_id}/file`. The selection is `asset_id`
  (repeated) on the GETs and `asset_ids` in the POST body; more than 10 is
  422 `too_many_assets`, an asset that is not an accessible asset of the
  site is 422 `invalid_assets`, and a request without a selection covers
  the whole site and is held to the same maximum. The two POSTs write only the
  caller's own job records; they require `application/json` and reject
  `Sec-Fetch-Site: cross-site`. Another user's job, or a job whose site the
  user can no longer access, is 404; an expired file is 410. Downloads are
  `attachment` + `Cache-Control: no-store`.
- **Jobs and storage** (migration 309; `asset_ids` and the create with
  selected assets, migration 312 -- a whole-site request is stored as the
  site's assets at that moment; jobs queued before 312 have NULL = whole
  site): `analytics.report_export_jobs` and
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
| `EMS_REPORT_EXPORT_MAX_CELLS` | 20000000 | Largest export accepted as a background job (was 3,000,000; raised by migration 312's change so that 10 assets x 14 days at 1 minute -- ~12 M cells -- is accepted). |
| `EMS_REPORT_EXPORT_MAX_ASSETS` | 10 | Most assets one export covers (the web app's `REPORT_MAX_ASSETS` matches). |
| `EMS_REPORT_EXPORT_MAX_ACTIVE_JOBS` | 3 | Queued + processing jobs per user (HTTP 429 beyond). |
| `EMS_REPORT_EXPORT_WORKER_ENABLED` | true | Run the in-process worker. |
| `EMS_REPORT_EXPORT_POLL_SECONDS` | 5 | Worker idle poll interval. |

ZIPs are held in the database until purged. At 1 minute a file is larger: an
asset is ~1 M cells for 14 days (several MB of CSV before compression), so a
10-asset, 14-day export is tens of MB. The worker builds one asset at a time
(the 1-minute path writes the read's rows straight into the CSV rows, no
per-column copies) on the 1.9 GB staging host. Rollback: migration 312's
header, then migration 309's.

## Fix history

**2026-10-24 — missing non-chart data points.** Reported on staging: the
Coimbatore Seasons Restaurant AHU-1/AHU-2 CSVs lacked Temperature,
Humidity and Occupancy. The assets have confirmed `asset_points` on their
AirSense devices (`ENV_TEMPERATURE`, `ENV_RELATIVE_HUMIDITY`,
`OCCUPANCY_ACTIVITY`, `ENV_ILLUMINANCE_LUX`), the catalogue function returns
them (`TEMPERATURE`, `HUMIDITY`, `OCCUPANCY_ACTIVITY`, `ILLUMINANCE`), and
`get_portal_asset_point_series` serves their telemetry. Root cause: the
export planned columns from the Analytics chart registry, which lists nine
electrical data points, so every other confirmed point was dropped. That
affected the 4 AHUs with AirSense sensors at Coimbatore (plus Battery
Voltage and Time Since Last Occupancy Event on Banquet 2 AHU) and, on every
metered asset at both staging sites, Apparent Power, Apparent Energy,
Current THD, Phase Angle and Neutral current. Fixed in
`app/src/report_export_service.py` (extra catalogue columns); the Analytics
page is unchanged. Whether the Analytics page should also chart these points
is a separate, open Product question (ADR-022's curated registry).

**2026-10-24 — 1-minute exports failed and were capped at 3 days.** A
1-minute export asked the generic read for register points outside the
chart registry (Apparent Energy on every metered asset), which it refuses
at 1 minute (22023), failing the export; and the 3-day Analytics window
applied. Fixed with migration 312 and the 1-minute path above (register
points are reported by the read and left out), together with asset
selection (ADR-014 Amendment 3).

## Validation

- Backend: `app/tests/test_report_export_service.py`, `_routes.py`,
  `_worker.py`, `_jobs_db.py` (real database: owner/tenant isolation,
  active-job limit, claim/lease/attempts, holder-only completion, expiry,
  purge, grants), `_migration_manifest.py`;
  `test_report_export_asset_selection_1m_db.py` (real database: the
  1-minute read equals the Analytics 1m read for a two-device asset with
  invalid samples and a mid-minute binding start; register points
  reported; capture policy; portal scope; 15-day bound; create with
  selected assets) and `_asset_selection_1m_manifest.py`.
- Frontend: `web/src/routes/reportExports/ReportsPage.test.tsx`,
  `web/src/reportExports/ReportExportsProvider.test.tsx`, client helpers.
- Local end-to-end (2026-10-24, disposable test database): immediate ZIP,
  background job Queued → Completed, owner download, anonymous 401,
  other-organization user 404, failed-job retry.
- Staging: see "Deployment and acceptance" below. Asset selection and the
  1-minute read (migration 312) are not on staging yet; after deployment,
  repeat the read-only timing check of the 1-minute read for one Coimbatore
  asset over 14 days and export 10 assets x 14 days at 1 minute in the UI.

## Deployment and acceptance

| Environment | State (checked 2026-10-24, read-only) | Acceptance |
|---|---|---|
| Staging | Deployed: PR #145 (squash `4f01764`, deploy run 40009981810) and the all-points fix PR #146 (squash `257b503`, deploy run 40069783724); migration 309 in the ledger (181 rows). | Backend export verified read-only: the deployed code was run inside the app container for the Coimbatore AHUs, with every catalogue column present and gaps empty. **Reports UI acceptance testing is outstanding**: the Reports page has not been exercised by a logged-in user (immediate and background export, notification, download, retry). |
| Production | **Not deployed.** The app image is `7e3da57` (PR #144), which contains neither `4f01764` nor `257b503`; the ledger ends at migration 308 (180 rows); `analytics.report_export_jobs` / `report_export_files` do not exist. | **Outstanding** until Reports (migration 309 and the app/web image) is promoted to production through the production release process; then repeat the UI acceptance there. |

Before any production promotion:

- Complete the staging UI acceptance.
- Get a Product Owner answer on the per-cell quality-state point (ADR-014
  decisions 3/10/11).
