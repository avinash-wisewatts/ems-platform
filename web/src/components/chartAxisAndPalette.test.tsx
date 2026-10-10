import { describe, expect, it } from "vitest";
import { render } from "@testing-library/react";
import { SERIES_COLORS, SeriesSwatch, formatAxisTick, lineDash, niceAxis, seriesStyleForSlot } from "./ChartFrame";

const labels = (lo: number, hi: number) => {
  const axis = niceAxis(lo, hi);
  return axis.ticks.map((t) => formatAxisTick(t, axis.decimals));
};

describe("niceAxis -- tick precision follows the scale", () => {
  it("whole numbers when the step is 1 or more", () => {
    expect(labels(0, 482.37)).toEqual(["0", "100", "200", "300", "400", "500"]);
    expect(labels(12.3, 17.9)).toEqual(["12", "14", "16", "18"]);
    expect(labels(228.4, 241.9)).toEqual(["225", "230", "235", "240", "245"]);
  });

  it("one decimal when the step is 0.1 to 0.5", () => {
    expect(labels(0, 1.7)).toEqual(["0.0", "0.5", "1.0", "1.5", "2.0"]);
    expect(labels(49.82, 50.21)).toEqual(["49.8", "49.9", "50.0", "50.1", "50.2", "50.3"]);
  });

  it("more decimals only when the step is finer, so labels stay distinct (power factor)", () => {
    const pf = labels(0.912, 0.987);
    expect(pf).toEqual(["0.90", "0.92", "0.94", "0.96", "0.98", "1.00"]);
    expect(new Set(pf).size).toBe(pf.length);
  });

  it("never repeats a label and never shows floating-point noise", () => {
    for (const [lo, hi] of [[0, 0.3], [0.1, 0.7], [-3.3, 7.7], [1e-4, 9e-4], [0, 12345678]] as const) {
      const out = labels(lo, hi);
      expect(new Set(out).size).toBe(out.length);
      for (const label of out) expect(label).not.toMatch(/\d{6,}\.|\.\d*0{4,}\d|9{4,}/);
    }
  });

  it("covers the data: the domain is widened to whole steps", () => {
    const axis = niceAxis(3.2, 20.9);
    expect(axis.domain[0]).toBeLessThanOrEqual(3.2);
    expect(axis.domain[1]).toBeGreaterThanOrEqual(20.9);
    expect(axis.ticks[0]).toBe(axis.domain[0]);
    expect(axis.ticks[axis.ticks.length - 1]).toBe(axis.domain[1]);
  });

  it("a bar axis from zero stays anchored at zero; negative ranges work; no -0", () => {
    expect(niceAxis(0, 3.4).ticks[0]).toBe(0);
    expect(labels(-12, 4)).toEqual(["-15", "-10", "-5", "0", "5"]);
    expect(formatAxisTick(-0.00001, 1)).toBe("0.0");
  });

  it("a flat or empty range still gives a usable axis", () => {
    expect(niceAxis(5, 5).ticks.length).toBeGreaterThan(1);
    expect(niceAxis(NaN, NaN).ticks.length).toBeGreaterThan(1);
  });
});

/** WCAG 2.x relative luminance contrast ratio of two #rrggbb colours. */
function contrast(a: string, b: string): number {
  const luminance = (hex: string) => {
    const [r, g, bl] = [1, 3, 5].map((i) => {
      const c = parseInt(hex.slice(i, i + 2), 16) / 255;
      return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r! + 0.7152 * g! + 0.0722 * bl!;
  };
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi! + 0.05) / (lo! + 0.05);
}

/** The chart panel background (styles.css --panel). */
const PANEL = "#ffffff";

describe("series palette -- contrast on the chart panel", () => {
  it("the validated order, with the darker aqua, yellow and magenta steps", () => {
    expect([...SERIES_COLORS]).toEqual(["#2a78d6", "#eb6834", "#199e70", "#c98500", "#d55181", "#008300", "#6250d6", "#e34948"]);
  });

  it.each([...SERIES_COLORS])("%s is at least 3:1 against the white panel (WCAG 1.4.11)", (color) => {
    expect(contrast(color, PANEL)).toBeGreaterThanOrEqual(3);
  });

  it("the replaced low-contrast hues are gone", () => {
    for (const old of ["#1baf7a", "#eda100", "#e87ba4"]) expect(SERIES_COLORS).not.toContain(old);
  });
});

describe("series palette", () => {
  it("eight distinct hues in a fixed order, then the same hues with a second encoding", () => {
    expect(new Set(SERIES_COLORS).size).toBe(8);
    expect(seriesStyleForSlot(0)).toEqual({ color: SERIES_COLORS[0], pattern: 0 });
    expect(seriesStyleForSlot(7)).toEqual({ color: SERIES_COLORS[7], pattern: 0 });
    expect(seriesStyleForSlot(8)).toEqual({ color: SERIES_COLORS[0], pattern: 1 });
    expect(seriesStyleForSlot(17)).toEqual({ color: SERIES_COLORS[1], pattern: 2 });
    expect(seriesStyleForSlot(24)).toEqual({ color: SERIES_COLORS[0], pattern: 3 });
    // 25 series (the API maximum) never share a colour and an encoding.
    const styles = Array.from({ length: 25 }, (_, i) => JSON.stringify(seriesStyleForSlot(i)));
    expect(new Set(styles.slice(0, 24)).size).toBe(24);
  });

  it("a repeated hue is never drawn the same way: dashed lines, hatched bars", () => {
    expect(lineDash(seriesStyleForSlot(0))).toBeUndefined();
    expect(lineDash(seriesStyleForSlot(8))).toBeTruthy();
    expect(lineDash(seriesStyleForSlot(16))).not.toBe(lineDash(seriesStyleForSlot(8)));
    const { container } = render(<SeriesSwatch kind="bar" style={seriesStyleForSlot(9)} />);
    expect(container.querySelector("pattern")).not.toBeNull();
    expect(container.querySelector("svg > rect")?.getAttribute("fill")).toMatch(/^url\(#/);
  });

  it("swatches are decorative: hidden from assistive technology", () => {
    const { container } = render(<SeriesSwatch kind="line" style={seriesStyleForSlot(2)} />);
    expect(container.querySelector("svg")).toHaveAttribute("aria-hidden", "true");
    expect(container.querySelector("line")).toHaveAttribute("stroke", SERIES_COLORS[2]);
  });
});
