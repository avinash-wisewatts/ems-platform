/**
 * MVP-6 -- Q76 Site Performance Report (ADR-015). Reports area only
 * (EMS-REQ-110) -- this route is not linked to from any other screen.
 * Orchestrates the two steps: configuration (EMS-REQ-111) and the
 * generated, in-app report (EMS-REQ-112/113), with "Change" (preserve
 * selection) and "Generate another report" (reset) both returning here.
 */

import { useState } from "react";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { useTenant } from "../../tenant/TenantProvider";
import { SitePerformanceReportConfig } from "./SitePerformanceReportConfig";
import { SitePerformanceReportView } from "./SitePerformanceReportView";
import type { ReportConfig } from "../../reports/sitePerformanceReport";

export function SitePerformanceReport() {
  const { selectedSite, sites } = useTenant();
  const [config, setConfig] = useState<ReportConfig | null>(null);
  const [priorConfig, setPriorConfig] = useState<ReportConfig | null>(null);

  return (
    <div className="page page--site-performance-report" data-testid="page-site-performance-report">
      <HierarchyCrumb
        siteName={selectedSite?.site_name ?? ""}
        multiSite={sites.length > 1}
        leaf={{ label: "Reports" }}
      />
      <h1>Site Performance Report</h1>

      {config ? (
        <SitePerformanceReportView
          config={config}
          onChange={() => {
            setPriorConfig(config);
            setConfig(null);
          }}
          onGenerateAnother={() => {
            setPriorConfig(null);
            setConfig(null);
          }}
        />
      ) : (
        <SitePerformanceReportConfig onGenerate={setConfig} initial={priorConfig} />
      )}
    </div>
  );
}
