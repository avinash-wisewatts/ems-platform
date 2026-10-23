/**
 * Reports tab -- in-app completion notifications, rendered by the shell on
 * every page: "Your export is ready" with the download link, or the failure
 * message with a link to the Reports tab (where it can be retried).
 */
import { Link } from "react-router-dom";
import { useTenant } from "../tenant/TenantProvider";
import { formatExportRange } from "./format";
import { useReportExports } from "./ReportExportsProvider";

/** At most this many notifications are shown at once (newest first). */
const VISIBLE = 3;

export function ReportExportNotifications() {
  const { notifications, dismiss } = useReportExports();
  const { sites } = useTenant();
  if (notifications.length === 0) return null;
  return (
    <div className="export-toasts" role="region" aria-label="Export notifications" data-testid="export-notifications">
      {notifications.slice(0, VISIBLE).map((job) => {
        const site = sites.find((s) => s.site_id === job.site_id);
        const range = formatExportRange(job.range_from, job.range_to, site?.timezone);
        const siteName = job.site_name ?? site?.site_name ?? "Site";
        const failed = job.status === "FAILED";
        return (
          <div
            key={job.job_id}
            className={`export-toast export-toast--${failed ? "failed" : "ready"}`}
            role={failed ? "alert" : "status"}
            data-testid={`export-notification-${job.job_id}`}
          >
            <div className="export-toast__body">
              <p className="export-toast__title">{failed ? "Export failed" : "Your export is ready"}</p>
              <p className="export-toast__detail">
                {siteName} · {range}
              </p>
              {failed && job.error_message ? <p className="export-toast__detail">{job.error_message}</p> : null}
            </div>
            <div className="export-toast__actions">
              {failed ? (
                <Link to="/reports" onClick={() => dismiss(job.job_id)}>
                  View in Reports
                </Link>
              ) : (
                <a href={job.download_url ?? undefined} download onClick={() => dismiss(job.job_id)}>
                  Download ZIP
                </a>
              )}
              <button type="button" className="export-toast__dismiss" onClick={() => dismiss(job.job_id)} aria-label="Dismiss">
                ✕
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
}
