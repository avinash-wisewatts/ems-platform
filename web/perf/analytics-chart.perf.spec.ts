/**
 * Analytics chart performance (F5): the real Analytics page, production
 * build, real Chromium; /api intercepted with a synthetic site and a
 * synthetic series response (no backend). See playwright.config.ts here.
 *
 * Measured per run (in-page, performance.now()):
 *   firstPaint  series response received -> chart painted (JSON parse,
 *               React render, the bar paths, paint); clickToPaint adds the
 *               request and transfer
 *   zoom        drag-to-zoom mouse-up -> repainted
 *   showAll     Show all click -> repainted
 *   hover       mouse move over the plot -> tooltip repainted (median of 10)
 *   slider      range-slider traveller moves -> repainted (median of 5; max too)
 * Each is the median of EMS_PERF_RUNS runs (default 3) in a fresh page.
 */
import { expect, test, type Page } from "@playwright/test";

const SERIES = Number(process.env.EMS_PERF_SERIES ?? 25);
const RUNS = Number(process.env.EMS_PERF_RUNS ?? 3);
const BUDGET = {
  firstPaint: Number(process.env.EMS_PERF_FIRST_PAINT_MS ?? 1000),
  zoom: Number(process.env.EMS_PERF_ZOOM_MS ?? 500),
  showAll: Number(process.env.EMS_PERF_SHOW_ALL_MS ?? 500),
  hover: Number(process.env.EMS_PERF_HOVER_MS ?? 150),
};

const SITE = "perf-site";
const TZ = "Asia/Kolkata";
const Q = 15 * 60_000;
const D = 86_400;

const point = (data_point: string, label: string) => ({
  data_point,
  label,
  category: "Energy",
  unit: "kWh",
  chart_kind: "bar",
  aggregation: "sum",
  phases: { system: true, three_phase: false },
  available_from: "2025-01-01T00:00:00Z",
  available_to: null,
});
const catalog = {
  site_id: SITE,
  site_name: "Perf site",
  site_timezone: TZ,
  limits: { max_data_points: 5, max_assets: 10, max_series: 25 },
  resolutions: [
    { resolution: "1m", max_window_seconds: 3 * D, default_window_seconds: D, available_from: null },
    { resolution: "15m", max_window_seconds: 30 * D, default_window_seconds: 7 * D, available_from: null },
    { resolution: "30m", max_window_seconds: 60 * D, default_window_seconds: 30 * D, available_from: null },
    { resolution: "1h", max_window_seconds: 180 * D, default_window_seconds: 90 * D, available_from: null },
    { resolution: "1d", max_window_seconds: 1095 * D, default_window_seconds: 365 * D, available_from: null },
  ],
  assets: Array.from({ length: 5 }, (_, i) => ({
    asset_id: `p${i}`,
    asset_name: `Perf asset ${i}`,
    asset_type_id: null,
    asset_type_name: null,
    building_name: null,
    floor_name: null,
    space_id: null,
    space_name: null,
    location_path: null,
    data_points: [point("ENERGY_IMPORT", "Energy"), point("ENERGY_EXPORT", "Energy Export")],
  })),
};
const me = {
  portal_user_id: 1,
  username: "perf",
  display_name: "Perf",
  role_code: "ADMIN",
  access_scope_mode: "GLOBAL",
  organization_id: null,
  site_ids: [SITE],
  permissions: ["dashboard.view", "analytics.view"],
};
const sites = { sites: [{ site_id: SITE, organization_id: "o", organization_name: "Org", site_code: "PERF", site_name: "Perf site", timezone: TZ }] };

/** SERIES Energy bar series over the requested range on the 15-minute grid;
 *  the last 2% of buckets are future (null), one bucket in progress. */
function seriesResponse(url: URL) {
  const from = Date.parse(url.searchParams.get("from")!);
  const to = Date.parse(url.searchParams.get("to")!);
  const count = Math.round((to - from) / Q);
  const firstFuture = Math.floor(count * 0.98);
  const series = Array.from({ length: SERIES }, (_, k) => ({
    asset_id: `s${k}`,
    asset_name: `Series asset ${k}`,
    data_point: "ENERGY_IMPORT",
    label: "Energy",
    qualifier: "TOTAL",
    unit: "kWh",
    chart_kind: "bar",
    aggregation: "sum",
    status: "OK",
    status_reasons: [],
    resolution_available_from: null,
    first_data_at: new Date(from).toISOString(),
    last_data_at: new Date(from + firstFuture * Q).toISOString(),
    stale: false,
    points: Array.from({ length: count }, (_, i) => {
      const future = i > firstFuture;
      const state = future ? "FUTURE" : i === firstFuture ? "IN_PROGRESS" : "COMPLETE";
      const value = future ? null : Math.round(Math.abs(Math.sin(i / 17 + k)) * (k + 1) * 1000) / 1000;
      return {
        bucket_start: new Date(from + i * Q).toISOString(),
        bucket_end: new Date(from + (i + 1) * Q).toISOString(),
        value,
        min: null,
        max: null,
        bucket_state: state,
        data_state: future ? "FUTURE" : "MEASURED",
        expected_intervals: 15,
        assigned_expected_intervals: future ? 0 : 15,
        valid_intervals: future ? 0 : 15,
        invalid_intervals: 0,
        reconstructed_intervals: 0,
        evidence_flags: [],
        evidence_status: future ? null : "GOOD",
        quality: null,
        is_partial: state !== "COMPLETE",
      };
    }),
    summary: { total: null, average: null, min: null, min_at: null, max: null, max_at: null },
  }));
  return {
    site_id: SITE,
    site_timezone: TZ,
    as_of: new Date().toISOString(),
    from: new Date(from).toISOString(),
    to: new Date(to).toISOString(),
    requested_resolution: "auto",
    resolution: "15m",
    phase: "system",
    series,
  };
}

type PerfWindow = Window & { __perf: Record<string, number> };

/** Arms a one-shot listener: the event's time to the paint after its work. */
async function armPaintTimer(page: Page, eventType: string, key: string) {
  await page.evaluate(
    ([type, name]) => {
      const w = window as unknown as PerfWindow;
      window.addEventListener(
        type!,
        () => {
          const t = performance.now();
          requestAnimationFrame(() => requestAnimationFrame(() => (w.__perf[name!] = performance.now() - t)));
        },
        { capture: true, once: true },
      );
    },
    [eventType, key],
  );
}

const readTimer = (page: Page, key: string) =>
  page.waitForFunction((name) => (window as unknown as PerfWindow).__perf[name] ?? null, key).then((h) => h.jsonValue() as Promise<number>);

async function oneRun(page: Page) {
  await page.route("**/api/v1/**", (route) => {
    const url = new URL(route.request().url());
    const p = url.pathname;
    let body: unknown = null;
    if (p.endsWith("/me")) body = me;
    else if (p.endsWith("/api/v1/sites")) body = sites;
    else if (p.endsWith("/analytics/catalog")) body = catalog;
    else if (p.endsWith("/analytics/series")) body = seriesResponse(url);
    else if (p.endsWith("/alerts")) body = { alerts: [], total: 0 };
    return route.fulfill({ status: body ? 200 : 404, contentType: "application/json", body: JSON.stringify(body ?? {}) });
  });
  await page.addInitScript((site) => sessionStorage.setItem("ems.web.selectedSiteId", site), SITE);
  await page.goto("/app/features/analytics");
  const assets = page.getByTestId("asset-selector");
  await assets.getByRole("button", { name: /^Unassigned/ }).click();
  await assets.getByRole("checkbox", { name: "Perf asset 0" }).click();
  await page.getByTestId("data-point-selector").getByRole("button", { name: /^Frequently Used/ }).click();
  await page.getByTestId("data-point-group-Frequently Used").getByRole("checkbox", { name: "Energy" }).click();
  await page.getByRole("button", { name: /From.*To/ }).click();
  const dialog = page.getByRole("dialog", { name: "Date range" });
  await dialog.getByRole("button", { name: "30 Days" }).click();
  await dialog.getByRole("button", { name: "Apply" }).click();

  // First paint: armed before Update, fired when every bar path is drawn.
  await page.evaluate((n) => {
    const w = window as unknown as PerfWindow;
    w.__perf = {};
    document.addEventListener(
      "click",
      (e) => {
        if ((e.target as Element).closest("[data-testid=analytics-update]")) w.__perf.click = performance.now();
      },
      { capture: true },
    );
    const observer = new MutationObserver(() => {
      const bars = document.querySelectorAll(".chart-frame__bar-series");
      if (bars.length !== n || ![...bars].every((b) => (b.getAttribute("d") ?? "").length > 0)) return;
      observer.disconnect();
      requestAnimationFrame(() =>
        requestAnimationFrame(() => {
          const painted = performance.now();
          const entry = performance
            .getEntriesByType("resource")
            .find((r) => r.name.includes("/analytics/series")) as PerformanceResourceTiming | undefined;
          w.__perf.firstPaint = painted - (entry?.responseEnd || w.__perf.click!);
          w.__perf.clickToPaint = painted - w.__perf.click!;
        }),
      );
    });
    observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["d"] });
  }, SERIES);
  await page.getByTestId("analytics-update").click();
  const firstPaint = await readTimer(page, "firstPaint");
  const clickToPaint = await readTimer(page, "clickToPaint");
  const drawn = await page.evaluate(() => ({
    mode: document.querySelector(".chart-frame__bars")?.getAttribute("data-bar-mode") ?? "",
    rects: (document.querySelector(".chart-frame__bar-series")?.getAttribute("d")?.match(/M/g) ?? []).length,
  }));

  const surface = page.locator(".chart-frame--multi .recharts-surface").first();
  const box = (await surface.boundingBox())!;
  const plotLeft = box.x + 64;
  const plotWidth = box.width - 64 - 16;
  const midY = box.y + (box.height - 40) / 2;

  // Hover: ten positions across the plot, each timed to its repaint.
  const hovers: number[] = [];
  for (let i = 0; i < 10; i++) {
    await armPaintTimer(page, "mousemove", `hover${i}`);
    await page.mouse.move(plotLeft + plotWidth * (0.05 + i * 0.09), midY);
    hovers.push(await readTimer(page, `hover${i}`));
  }
  await expect(page.getByTestId("chart-tooltip")).toBeVisible();

  // Drag-to-zoom across 10% of the plot.
  await page.mouse.move(plotLeft + plotWidth * 0.45, midY);
  await page.mouse.down();
  await page.mouse.move(plotLeft + plotWidth * 0.55, midY, { steps: 4 });
  await armPaintTimer(page, "mouseup", "zoom");
  await page.mouse.up();
  const zoom = await readTimer(page, "zoom");
  await expect(page.getByTestId("chart-show-all")).toBeVisible();

  // Show all.
  await armPaintTimer(page, "click", "showAll");
  await page.getByTestId("chart-show-all").click();
  const showAll = await readTimer(page, "showAll");
  await expect(page.getByTestId("chart-show-all")).toHaveCount(0);

  // Range slider: drag the left traveller in five steps, each timed.
  const traveller = page.locator(".recharts-brush-traveller").first();
  const tb = (await traveller.boundingBox())!;
  const ty = tb.y + tb.height / 2;
  await page.mouse.move(tb.x + tb.width / 2, ty);
  await page.mouse.down();
  const slides: number[] = [];
  for (let i = 1; i <= 5; i++) {
    await armPaintTimer(page, "mousemove", `slide${i}`);
    await page.mouse.move(tb.x + tb.width / 2 + plotWidth * 0.08 * i, ty);
    slides.push(await readTimer(page, `slide${i}`));
  }
  await page.mouse.up();
  const sliderMode = await page.evaluate(() => document.querySelector(".chart-frame__bars")?.getAttribute("data-bar-mode") ?? "");

  hovers.sort((a, b) => a - b);
  slides.sort((a, b) => a - b);
  return {
    firstPaint,
    clickToPaint,
    zoom,
    showAll,
    hover: hovers[5]!,
    hoverMax: hovers[9]!,
    slider: slides[2]!,
    sliderMax: slides[4]!,
    fullRangeMode: drawn.mode,
    sliderMode,
    rectsPerSeries: drawn.rects,
  };
}

test(`Analytics chart: ${SERIES} bar series x 30 days of 15-minute buckets`, async ({ browser }) => {
  const runs: Awaited<ReturnType<typeof oneRun>>[] = [];
  for (let i = 0; i < RUNS; i++) {
    const context = await browser.newContext();
    const page = await context.newPage();
    runs.push(await oneRun(page));
    await context.close();
  }
  type Timing = "firstPaint" | "clickToPaint" | "zoom" | "showAll" | "hover" | "hoverMax" | "slider" | "sliderMax";
  const median = (key: Timing) => {
    const values = runs.map((r) => r[key]).sort((a, b) => a - b);
    return Math.round(values[Math.floor(values.length / 2)]!);
  };
  const result = {
    series: SERIES,
    fullRangeMode: runs[0]!.fullRangeMode,
    rectsPerSeries: runs[0]!.rectsPerSeries,
    sliderMode: runs[0]!.sliderMode,
    runs: RUNS,
    firstPaintMs: median("firstPaint"),
    clickToPaintMs: median("clickToPaint"),
    zoomMs: median("zoom"),
    showAllMs: median("showAll"),
    hoverMs: median("hover"),
    hoverMaxMs: median("hoverMax"),
    sliderMs: median("slider"),
    sliderMaxMs: median("sliderMax"),
    perRun: runs.map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, typeof v === "number" ? Math.round(v) : v]))),
  };
  process.stdout.write(`\nANALYTICS_CHART_PERF ${JSON.stringify(result)}\n`);

  expect(result.firstPaintMs, "first paint").toBeLessThan(BUDGET.firstPaint);
  expect(result.zoomMs, "zoom").toBeLessThan(BUDGET.zoom);
  expect(result.showAllMs, "Show all").toBeLessThan(BUDGET.showAll);
  expect(result.hoverMs, "hover").toBeLessThan(BUDGET.hover);
});
