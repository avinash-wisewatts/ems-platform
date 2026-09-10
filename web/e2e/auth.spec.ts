import { test, expect, type BrowserContext } from "@playwright/test";

/**
 * ROADMAP-REQUIRED integration test: authentication + permission behaviour
 * against a REAL staging tenant.
 *
 * Not executed in unit CI or during Phase 8 implementation. Run by an operator
 * after the shell is deployed to staging, with:
 *   - EMS_E2E_BASE_URL          the staging admin-portal origin (SSH-tunnelled)
 *   - EMS_E2E_SESSION_COOKIE    "ems_admin_session=<value>" captured from a
 *                               real login as a real staging portal user
 *   - EMS_E2E_EXPECT_ROLE       that user's role (ADMIN | OPERATOR | VIEWER)
 *
 * It manufactures no identities and mutates no data -- it only reads.
 */

const BASE = process.env.EMS_E2E_BASE_URL ?? "";
const COOKIE = process.env.EMS_E2E_SESSION_COOKIE ?? "";
const EXPECT_ROLE = process.env.EMS_E2E_EXPECT_ROLE ?? "";

const configured = Boolean(BASE && COOKIE);

test.describe("Phase 8 shell -- real staging session", () => {
  test.skip(!configured, "Set EMS_E2E_BASE_URL and EMS_E2E_SESSION_COOKIE to run against staging.");

  async function withSession(context: BrowserContext) {
    const [name, ...rest] = COOKIE.split("=");
    const value = rest.join("=");
    const url = new URL(BASE);
    await context.addCookies([
      { name: name!.trim(), value: value.trim(), domain: url.hostname, path: "/" },
    ]);
  }

  test("unauthenticated visit to /app is redirected to the existing /login (no SPA login form)", async ({
    page,
  }) => {
    const res = await page.goto(`${BASE}/app`, { waitUntil: "domcontentloaded" });
    expect(res).toBeTruthy();
    await expect(page).toHaveURL(/\/login(\?|$)/);
    // the server-rendered login page, not an SPA-rendered form
    await expect(page.locator('form[action="/login"]')).toBeVisible();
  });

  test("authenticated session bootstraps the shell and lists only this user's sites", async ({
    browser,
  }) => {
    const context = await browser.newContext();
    await withSession(context);
    const page = await context.newPage();

    await page.goto(`${BASE}/app/`, { waitUntil: "networkidle" });

    // GET /api/v1/me succeeds -> the shell chrome renders (never a redirect loop)
    await expect(page.getByTestId("app-shell")).toBeVisible({ timeout: 15_000 });
    await expect(page.getByTestId("identity-name")).not.toBeEmpty();

    // GET /api/v1/sites returns the scope-filtered list; the picker (or auto
    // selection) reflects it and shows no cross-tenant leakage.
    const meResp = await page.request.get(`${BASE}/api/v1/me`);
    expect(meResp.ok()).toBeTruthy();
    const me = await meResp.json();
    if (EXPECT_ROLE) expect(me.role_code).toBe(EXPECT_ROLE);
    expect(me.permissions).toContain("dashboard.view");

    const sitesResp = await page.request.get(`${BASE}/api/v1/sites`);
    expect(sitesResp.ok()).toBeTruthy();
    const sites = (await sitesResp.json()).sites as { organization_id: string }[];
    if (me.access_scope_mode === "ORGANIZATION") {
      const orgs = new Set(sites.map((s) => s.organization_id));
      expect([...orgs]).toEqual([me.organization_id]);
    }

    await context.close();
  });

  test("navigation is permission-gated for this user's role (UX only)", async ({ browser }) => {
    const context = await browser.newContext();
    await withSession(context);
    const page = await context.newPage();
    await page.goto(`${BASE}/app/home`, { waitUntil: "networkidle" });

    await expect(page.getByTestId("nav-home")).toBeVisible();
    const adminNav = page.getByTestId("nav-admin");
    if (EXPECT_ROLE === "ADMIN") {
      await expect(adminNav).toBeVisible();
    } else if (EXPECT_ROLE) {
      await expect(adminNav).toHaveCount(0);
    }
    await context.close();
  });

  test("an inaccessible space returns 404 with no existence leak", async ({ browser }) => {
    const context = await browser.newContext();
    await withSession(context);
    const page = await context.newPage();
    const resp = await page.request.get(
      `${BASE}/api/v1/spaces/ffffffff-ffff-ffff-ffff-ffffffffffff/measurements` +
        `?parameter=TEMPERATURE&resolution=raw&from=2026-01-01T00:00:00Z&to=2026-01-01T06:00:00Z`,
    );
    expect(resp.status()).toBe(404);
    expect(await resp.json()).toEqual({
      error: "not_found",
      detail: "Space not found or not accessible.",
    });
    await context.close();
  });
});
