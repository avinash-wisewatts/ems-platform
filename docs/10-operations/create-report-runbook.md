# Runbook — Reports → Create report (weekly / monthly PDF reports)

Feature: [docs/07-features/create-report/README.md](../07-features/create-report/README.md) ·
Decision: [ADR-025](../00-governance/decisions/ADR-025-site-energy-performance-reports.md) ·
Environments: **staging only** (migrations 328–329 are staging/test-scoped; production is not approved, A106).

## Components

| Component | Where | Notes |
|---|---|---|
| `report-worker` container | compose service, profile `reports`, same `APP_IMAGE` | Started by `.github/workflows/deploy-staging.yml` (`APP_SERVICES="admin-portal live-telemetry report-worker"`). One job at a time; `mem_limit` 700 MB; healthcheck = heartbeat file younger than 15 minutes. Idle (heartbeat only) when `EMS_REPORTS_ENABLED` is off. |
| Database | `analytics.site_report_profiles`, `site_report_assets`, `asset_report_setting_versions` (328); `site_reports`, `site_report_versions`, `site_report_files`, `site_report_attempts` (329) | Only through SECURITY DEFINER functions. Worker and Administration App use `ems_app` on staging; the customer API may execute only the four read functions. |
| Administration App | `/administration/sites/{site}/reporting`, `/administration/sites/{site}/reports`, `/administration/site-reports/{report}` | WiseWatts Admins only (active ADMIN, GLOBAL). Linked from Site detail ("Reporting", "Reports"). |
| Customer portal | Reports → Create report (`/app/reports?tab=create`) | Read-only for Admin, Operator and Viewer with site access. Served by `customer-api` on the customer host. |

## Setup for a site (WiseWatts Admin, Administration App)

1. Site detail → **Reporting** → **Enrol site for reports** (weekly and monthly schedules start on; earlier periods are never generated automatically).
2. Reporting asset list: assign each reporting asset a group (and, for AHUs, its area). Radisson's 23 assets: §4.1 of the planning package.
3. For each asset (click its name): temperature setpoint (temperature-monitored assets only), operating schedule and operating thresholds (AHUs). Changes take effect now (today) or at 00:00 site time on a future date; past dates are refused.
4. **Automation account** (A88, A108): requires separate explicit authorization to create. It must be an active ADMIN, scope Selected sites, in the site's organization, with this site only, and no usable password. Once it exists, select it on the Reporting page. Until then automatic attempts fail with `automation_not_authorized` (no automatic retry); manual generation by a WiseWatts Admin still works.

## Day-to-day

- Automatic weekly reports are first attempted at Sunday 06:00 site time and monthly reports on the 1st at 06:00. They wait (Pending, re-check every 30 minutes) while the final period minutes are still arriving, and generate at 12:00 at the latest.
- **Report management** (Administration App → Reports): Generate a completed week or month (including history inside the ~90-day 1-minute retention), Regenerate (new version; the previous one stays downloadable), Retry a Failed report, Delete (moves to the recycle bin for 7 days), Restore, and Delete permanently. Permanent deletion is offered only in the recycle bin and requires typing `PERMANENTLY DELETE`.
- Retention: each version expires 60 days after it was generated. In the recycle bin each version is permanently deleted at the earlier of deletion + 7 days and its own expiry. Restore never extends expiry.

## Diagnostics (read-only)

```sql
-- Latest attempts for a site (as ems_admin, staging only):
SELECT r.report_type, r.period_start_date, a.trigger, a.status, a.retry_no, a.not_before, a.error_code, a.wait_message
FROM analytics.site_report_attempts a JOIN analytics.site_reports r ON r.id = a.report_id
WHERE r.site_id = '<site>' ORDER BY a.created_at DESC LIMIT 20;
```

```bash
docker logs --since 2h ems-report-worker        # claim, waiting, per-attempt outcome and duration; never secrets or PDF content
docker inspect --format '{{.State.Health.Status}}' ems-report-worker
```

| Failure code | Meaning | Action |
|---|---|---|
| `automation_not_authorized` | Automation account not set, inactive, wrong scope or no longer only this site | Fix the account (separate authorization), then Retry |
| `requester_not_authorized` | The WiseWatts Admin who requested it lost access | Retry as a current WiseWatts Admin |
| `insufficient_data` | Current period below 80 % for HVAC or Kitchen, or no valid peak timestamp | Investigate telemetry; Retry or Regenerate after data recovers |
| `retention_exceeded` | Period older than the 1-minute retention | Not generable |
| `pdf_validation_failed:<check>` | The PDF failed a quality check; nothing was published | Report a defect with the attempt id |
| `worker_interrupted`, `generation_failed` | Temporary; retried automatically at 15, 30 and 60 minutes | Check worker logs if all retries fail |
| `roster_empty` | No reporting assets configured | Configure the reporting asset list |

## Resource notes

Staging host ~1.9 GB RAM. One monthly report reads about 9 asset-weeks of 1-minute data per asset (measured: 23 assets × 14 days in ~21 s on 2026-11-19) and holds compact per-minute maps only; the worker is capped at 700 MB. Do not run several workers.

## Rollback

1. Stop the worker: `docker compose -f compose.yaml stop report-worker` (staging host).
2. Deploy an application image without the feature (normal rollback workflow; the customer API is redeployed separately).
3. Only if the database objects must go (destructive; deletes all reports and reporting settings): `postgres/maintenance/328_329_site_reports_rollback.sql` with explicit authorization.

## Before any production use (not approved)

Product Owner approval (A106); a dedicated least-privilege `ems_report_worker` database role (A92); the automation account created under separate authorization (A93); migrations 328–329 moved out of the staging-only scope; production deployment workflow changes.
