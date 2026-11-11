import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MultiSeriesChartFrame, type ChartSeries } from "./ChartFrame";

// The real application stylesheet, so the cascade between the site-wide
// button[aria-pressed="true"] chip and the legend toggle is what ships. Read
// from disk: the test config turns CSS imports off (css: false), and the
// project has no Node typings, hence the narrow local type.
type NodeProcess = {
  cwd(): string;
  getBuiltinModule(id: "node:fs"): { readFileSync(path: string, encoding: "utf8"): string };
};
const nodeProcess = (globalThis as unknown as { process: NodeProcess }).process;
const appStyles = nodeProcess.getBuiltinModule("node:fs").readFileSync(`${nodeProcess.cwd()}/src/styles.css`, "utf8");

let sheet: HTMLStyleElement;
beforeEach(() => {
  sheet = document.createElement("style");
  sheet.textContent = appStyles;
  document.head.appendChild(sheet);
});
afterEach(() => sheet.remove());

const H = 3_600_000;
const T0 = Date.parse("2026-10-04T18:30:00Z");
const buckets = Array.from({ length: 2 }, (_, i) => ({ start: T0 + i * H, end: T0 + (i + 1) * H }));
const series: ChartSeries[] = [
  { key: "e", name: "Asset 1 · Energy", unit: "kWh", kind: "bar", values: [1, 2] },
  { key: "p", name: "Asset 1 · Power", unit: "kW", kind: "line", values: [3, 4] },
];

function renderLegend() {
  render(<MultiSeriesChartFrame buckets={buckets} series={series} range={{ from: T0, to: T0 + 2 * H }} ariaLabel="Chart" width={600} height={240} />);
  return (name: string) => within(screen.getByTestId("chart-legend")).getByRole("button", { name });
}

/** Declarations of the rule with exactly this selector in the stylesheet. */
function ruleBody(selector: string): string | null {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`).exec(appStyles)?.[1] ?? null;
}

/** CSS specificity (ids, classes / attributes / pseudo-classes, types) of a
 *  simple compound selector -- enough for the two selectors compared here. */
function specificity(selector: string): [number, number, number] {
  const ids = (selector.match(/#[\w-]+/g) ?? []).length;
  const classes = (selector.match(/\.[\w-]+|\[[^\]]+\]|:(?!:)[\w-]+/g) ?? []).length;
  const types = (selector.replace(/\[[^\]]+\]|\.[\w-]+|#[\w-]+|:[\w-]+/g, " ").match(/[a-z][\w-]*/gi) ?? []).length;
  return [ids, classes, types];
}
const beats = (a: [number, number, number], b: [number, number, number]) =>
  a[0] !== b[0] ? a[0] > b[0] : a[1] !== b[1] ? a[1] > b[1] : a[2] > b[2];

const CHIP = 'button[aria-pressed="true"]';
const OVERRIDE = ".chart-frame__legend-toggle[aria-pressed]";

describe("legend toggles are borderless (not the site-wide pressed-button chip)", () => {
  // jsdom resolves conflicting rules by source order, not specificity, so the
  // cascade is checked on the stylesheet itself; the real look was checked in
  // Chrome (see the PR).
  it("the stylesheet still has the site-wide chip that the override must beat", () => {
    expect(ruleBody(CHIP)).toMatch(/background:\s*#e6f7f6/);
    expect(ruleBody(CHIP)).toMatch(/border-color:/);
  });

  it("an override for pressed legend toggles clears the chip border and fill, with higher specificity", () => {
    const body = ruleBody(OVERRIDE);
    expect(body).not.toBeNull();
    expect(body).toMatch(/border-color:\s*transparent/);
    expect(body).toMatch(/background:\s*none/);
    expect(body).toMatch(/color:\s*var\(--text\)/);
    expect(specificity(OVERRIDE)).toEqual([0, 2, 0]);
    expect(specificity(CHIP)).toEqual([0, 1, 1]);
    expect(beats(specificity(OVERRIDE), specificity(CHIP))).toBe(true);
  });

  it("the shown entry is a pressed toggle with the legend class the override targets", () => {
    const toggle = renderLegend()("Asset 1 · Energy");
    expect(toggle).toHaveAttribute("aria-pressed", "true");
    expect(toggle).toHaveClass("chart-frame__legend-toggle");
    expect(toggle.matches(OVERRIDE)).toBe(true);
  });

  it("a hidden entry stays distinguishable: muted, struck through, faded swatch -- and still a focusable button", async () => {
    const legend = renderLegend();
    await userEvent.click(legend("Asset 1 · Power"));
    const hidden = legend("Asset 1 · Power");
    expect(hidden).toHaveAttribute("aria-pressed", "false");
    expect(hidden).toHaveClass("chart-frame__legend-toggle--hidden");
    expect(getComputedStyle(hidden.querySelector(".chart-frame__legend-name")!).textDecoration).toContain("line-through");
    expect(getComputedStyle(hidden.querySelector(".chart-frame__swatch")!).opacity).toBe("0.35");
    hidden.focus();
    expect(hidden).toHaveFocus();
    // The shown entry is not struck through.
    const shown = legend("Asset 1 · Energy");
    expect(getComputedStyle(shown.querySelector(".chart-frame__legend-name")!).textDecoration).not.toContain("line-through");
  });

  it("the stylesheet keeps a visible keyboard focus ring for legend toggles", () => {
    expect(appStyles).toMatch(/\.chart-frame__legend-toggle:focus-visible\s*\{[^}]*outline:\s*2px solid/);
  });
});
