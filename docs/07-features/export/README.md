# Export — Reports tab site measurement export

Status: IMPLEMENTED (2026-10-24, migration 309); deployed to staging 2026-10-24; not deployed to production; UI acceptance testing outstanding. Asset selection and 14-day 1-minute exports (migration 312, ADR-014 Amendment 3): PR #153 merged `7c28cfd` and deployed to staging 2026-10-24; staging UI acceptance completed 2026-10-25; not deployed to production · Owner: Product + Engineering
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
- Staging: see "Deployment and acceptance" and "Staging acceptance of
  migration 312" below.

## Deployment and acceptance

| Environment | State (checked 2026-10-24, read-only) | Acceptance |
|---|---|---|
| Staging | Deployed: PR #145 (squash `4f01764`, deploy run 40009981810), the all-points fix PR #146 (squash `257b503`, deploy run 40069783724) and asset selection / 14-day 1-minute PR #153 (squash `7c28cfd`, deploy run 40108375840: migration 312 APPLY once in 137 ms with postconditions passed, post-deployment verification passed); ledger 183 rows; both app containers on `7c28cfd`, healthy. | **Accepted 2026-10-25** (authenticated UI acceptance by the Product Owner through the local Web App against staging over the SSH tunnel, plus read-only evidence below). Not yet exercised by a second portal user: staging has one active portal user (a GLOBAL admin), so non-owner / other-organization isolation rests on the real-database tests. |
| Production | **Not deployed.** The app image is `7e3da57` (PR #144), which contains neither `4f01764` nor `257b503`; the ledger ends at migration 308 (180 rows); `analytics.report_export_jobs` / `report_export_files` do not exist. | **Outstanding** until Reports (migration 309 and the app/web image) is promoted to production through the production release process; then repeat the UI acceptance there. |

### Staging acceptance of migration 312 (2026-10-24/25)

Evidence collected read-only (SELECT-only SQL, read-only HTTP; the ZIP was
copied to the engineer's machine and inspected there).

- **Deployed 1-minute read** (`get_portal_asset_measurements_1m`, every
  catalogue point, 14 days): Chiller1 49 points (37 measurement, 12 register
  points reported and omitted) -- 20,121 minute rows, 744,477 values,
  10.7 s; Banquet 2 AHU 55 points (12 omitted) -- 20,137 rows, 865,136
  values, 13.2 s. The previous per-point read did not finish 9 points x 1
  day in 90 s. Host memory unchanged during the reads.
- **Background exports run in the UI** (Coimbatore, 11 Oct - 25 Oct 00:00
  IST, all COMPLETED on the first attempt, queue wait under 5 s):

  | Resolution | Assets | Rows | ZIP size | Run time |
  |---|---|---|---|---|
  | Auto (1 h) | 9 (AHUs + chillers) | 3,024 | 0.5 MB | 61 s |
  | 1 minute | 9 (AHUs + chillers) | 181,440 | 18.3 MB | 2 min 52 s |
  | 1 minute | 6 (pumps, cooling towers) | 120,960 | 10.3 MB | 1 min 27 s |
  | 1 minute | 5 (kitchen) | 100,800 | 10.1 MB | 1 min 14 s |

  The largest single export had 9 assets; a 10-asset export was not run
  (extrapolated: ~3 min 10 s and ~20 MB).
- **ZIP / CSV integrity** (9-asset 1-minute file, byte size equal to the
  stored size): `testzip` OK; one CSV per selected asset; each exactly
  20,160 rows (14 x 1,440), consecutive minutes with no step other than
  1 minute, no ragged rows, site-local column at +05:30; total rows equal
  the job's `row_count`; 99.7-99.9 % of cells filled. No register columns
  (Apparent Energy, per-phase Energy) are present; System Energy and Energy
  Export are. The AirSense AHUs carry Temperature, Relative Humidity,
  Illuminance, Occupancy Activity and Time Since Last Occupancy Event.
- **Access control**: anonymous estimate, create, list, job and file
  requests through the proxy are 401; for an unknown portal user the job,
  file, list and 1-minute read return nothing; an asset of the other
  staging site requested under Coimbatore returns nothing; `ems_app` has no
  SELECT on `analytics.report_export_files`. App log: create 202, estimate
  200 (and 4 validation 422s), downloads 200, no 5xx, no tracebacks.
- **Expiry**: files expire 24 h after completion; an export created before
  312 reached `expires_at` (25 Oct 01:06 IST) and was purged by the worker
  (status EXPIRED, file deleted).
- **Storage**: `analytics.report_export_files` 46 MB for 6 unexpired files
  (the four acceptance exports ~39 MB), released as each file expires.
  Database 29 GB, disk 41 GB free (58 % used).
- **Health after the test**: PostgreSQL not restarted (up since
  2026-09-22); pipeline jobs 1000 / 1001 / 1012 / 1076 succeeding;
  environment telemetry current; containers healthy.

Before any production promotion:

- Get a Product Owner answer on the per-cell quality-state point (ADR-014
  decisions 3/10/11).
- Production volumes are larger than staging's: repeat the read-only timing
  of the 1-minute read on production before enabling 14-day 1-minute
  exports there.
