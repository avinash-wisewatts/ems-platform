import { defineConfig } from "@playwright/test";

/**
 * E2E is the ONE roadmap-required integration test: authentication / permission
 * behaviour against a REAL staging tenant. It is NOT run in unit CI and NOT run
 * during this implementation task -- it needs a reachable, deployed staging
 * shell and a real portal session.
 *
 * Usage (operator, after the shell is deployed to staging):
 *   EMS_E2E_BASE_URL=http://127.0.0.1:8080 \
 *   EMS_E2E_SESSION_COOKIE="ems_admin_session=<value from a real login>" \
 *   npx playwright test
 *
 * The cookie is obtained by logging in once through the existing /login page
 * as a real staging portal user; the spec then asserts the shell bootstraps
 * that session, lists only that user's accessible sites, and gates navigation
 * by that user's permissions. No identities are manufactured.
 */
export default defineConfig({
  testDir: "./e2e",
  timeout: 30_000,
  fullyParallel: false,
  retries: 0,
  reporter: [["list"]],
  use: {
    baseURL: process.env.EMS_E2E_BASE_URL ?? "http://127.0.0.1:8080",
    ignoreHTTPSErrors: true,
  },
});
