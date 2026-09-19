/**
 * Small, monochrome, currentColor-stroke line icons for the redesigned
 * shell's primary sidebar navigation. Deliberately plain/utilitarian (per
 * the WiseWatts dashboard design requirements: "clean and data-focused; do
 * not use decorative/colorful icons"). Not used inside any KPI/metric
 * section -- navigation chrome only.
 */

import type { ReactNode } from "react";

export type NavIconKey =
  | "main-dashboard"
  | "asset-view"
  | "analytics"
  | "single-line-diagram"
  | "alerts"
  | "settings"
  | "archive";

const PATHS: Record<NavIconKey, ReactNode> = {
  "main-dashboard": (
    <>
      <rect x="3.5" y="3.5" width="7" height="7" rx="1" />
      <rect x="13.5" y="3.5" width="7" height="7" rx="1" />
      <rect x="3.5" y="13.5" width="7" height="7" rx="1" />
      <rect x="13.5" y="13.5" width="7" height="7" rx="1" />
    </>
  ),
  "asset-view": (
    <>
      <path d="M12 3 20 7.5v9L12 21 4 16.5v-9Z" strokeLinejoin="round" />
      <path d="M4 7.5 12 12l8-4.5M12 12v9" />
    </>
  ),
  analytics: (
    <>
      <path d="M4 20V10M11 20V4M18 20v-6" strokeLinecap="round" />
      <path d="M3 20h18" strokeLinecap="round" />
    </>
  ),
  "single-line-diagram": (
    <>
      <circle cx="5" cy="5" r="2" />
      <circle cx="19" cy="5" r="2" />
      <circle cx="12" cy="19" r="2" />
      <path d="M5 7v4a3 3 0 0 0 3 3h1M19 7v4a3 3 0 0 1-3 3h-1M12 14v3" />
    </>
  ),
  alerts: (
    <>
      <path d="M12 4a5 5 0 0 0-5 5c0 5-2 6-2 6h14s-2-1-2-6a5 5 0 0 0-5-5Z" strokeLinejoin="round" />
      <path d="M10 19a2 2 0 0 0 4 0" />
    </>
  ),
  settings: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4" />
    </>
  ),
  archive: (
    <>
      <rect x="3.5" y="4.5" width="17" height="4" rx="1" />
      <path d="M4.5 8.5v9a1.5 1.5 0 0 0 1.5 1.5h12a1.5 1.5 0 0 0 1.5-1.5v-9" />
      <path d="M10 12.5h4" strokeLinecap="round" />
    </>
  ),
};

export function NavIcon({ icon }: { icon: NavIconKey }) {
  return (
    <svg
      className="nav-icon"
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      aria-hidden="true"
    >
      {PATHS[icon]}
    </svg>
  );
}
