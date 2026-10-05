import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "@playwright/test";

/**
 * Analytics chart performance benchmark (F5) -- repeatable, local, NOT run in
 * CI (timings depend on the machine). It builds the production bundle, serves
 * it with `vite preview`, and drives the real Analytics page in Chromium with
 * every /api request intercepted (no backend, no staging, no credentials).
 *
 *   cd web && npx playwright test -c perf/playwright.config.ts
 *
 * Budgets (approved 2026-10-05, 25 series x 30 days of 15-minute buckets):
 * first paint < 1 s, zoom < 0.5 s, Show all < 0.5 s, hover < 150 ms.
 * Override with EMS_PERF_FIRST_PAINT_MS / _ZOOM_MS / _SHOW_ALL_MS / _HOVER_MS.
 */
const PORT = Number(process.env.EMS_PERF_PORT ?? 4179);
const HERE = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  testDir: ".",
  testMatch: "*.perf.spec.ts",
  outputDir: path.join(HERE, "..", "test-results", "perf"),
  timeout: 180_000,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    viewport: { width: 1440, height: 900 },
  },
  webServer: {
    command: `npx vite build && npx vite preview --host 127.0.0.1 --port ${PORT} --strictPort`,
    cwd: path.join(HERE, ".."),
    url: `http://127.0.0.1:${PORT}/app/`,
    reuseExistingServer: false,
    timeout: 240_000,
  },
});
