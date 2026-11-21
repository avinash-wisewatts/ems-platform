/**
 * Reports: sub-tabs "Create report" (weekly / monthly PDF reports,
 * report.view; ADR-025) and "Export data" (the existing measurement export,
 * report.export). Create report is the DEFAULT tab (ADR-025 Amendment 1,
 * A117); Export data is kept in the URL (?tab=export) so it can be linked
 * to. With only one permitted tab, no tab bar is shown.
 */
import { useSearchParams } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { hasPermission } from "../../auth/permissions";
import { CreateReportTab } from "../reports/createReport/CreateReportTab";
import { ReportsPage } from "./ReportsPage";

export function ReportsTabs() {
  const { user } = useSession();
  const [params, setParams] = useSearchParams();
  const canExport = hasPermission(user, "report.export");
  const canView = hasPermission(user, "report.view");
  const wantsExport = params.get("tab") === "export";
  const showCreate = canView && (!wantsExport || !canExport);

  if (!(canExport && canView)) {
    return showCreate ? <CreateReportTab /> : <ReportsPage />;
  }

  const select = (tab: "export" | "create") => {
    const next = new URLSearchParams(params);
    if (tab === "export") next.set("tab", "export");
    else next.delete("tab");
    setParams(next, { replace: true });
  };

  return (
    <div className="reports-tabs-page">
      <div className="reports-tabs" role="tablist" aria-label="Reports" data-testid="reports-tabs">
        <button
          type="button"
          role="tab"
          aria-selected={showCreate}
          className={`reports-tab${showCreate ? " reports-tab--active" : ""}`}
          onClick={() => select("create")}
          data-testid="reports-tab-create"
        >
          Create report
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={!showCreate}
          className={`reports-tab${showCreate ? "" : " reports-tab--active"}`}
          onClick={() => select("export")}
          data-testid="reports-tab-export"
        >
          Export data
        </button>
      </div>
      <div role="tabpanel">{showCreate ? <CreateReportTab /> : <ReportsPage />}</div>
    </div>
  );
}
