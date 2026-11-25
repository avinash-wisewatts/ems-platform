import { describe, expect, it } from "vitest";
import { COMING_SOON_NAV, PRIMARY_NAV, SECONDARY_NAV, SHELL_PRIMARY_NAV, groupNav, visibleNav } from "./navigation";
import { ADMIN_USER, VIEWER_USER } from "../test-utils";

describe("navigation model -- permission gates VISIBILITY only", () => {
  it("a VIEWER sees the primary shell nav, including the Slice 0/A/B real screens, but not admin affordances", () => {
    const primary = visibleNav(PRIMARY_NAV, VIEWER_USER.permissions);
    const secondary = visibleNav(SECONDARY_NAV, VIEWER_USER.permissions);
    expect(primary.map((i) => i.key)).toEqual([
      "home",
      "energy",
      "demand",
      "power-quality",
      "reports",
      "alerts",
      "spaces",
      "assets",
      "features",
    ]);
    expect(secondary).toHaveLength(0);
  });

  it("an ADMIN additionally sees the administration affordance", () => {
    const secondary = visibleNav(SECONDARY_NAV, ADMIN_USER.permissions);
    expect(secondary.map((i) => i.key)).toEqual(["admin"]);
  });

  it("every foundation nav target is either the home screen or under /features (real or still-placeholder)", () => {
    for (const item of [...PRIMARY_NAV, ...SECONDARY_NAV]) {
      expect(item.to === "/home" || item.to.startsWith("/features")).toBe(true);
    }
  });
});

describe("navigation IA -- MVP-1 closeout: Energy/Demand/PQ are Site capabilities, Spaces/Assets are the hierarchy drill-down", () => {
  it("groups Home/Energy/Demand/Power Quality/Reports under 'site' and Spaces/Assets under 'hierarchy', not as flat unrelated siblings", () => {
    const byKey = Object.fromEntries(PRIMARY_NAV.map((item) => [item.key, item.group]));
    expect(byKey["home"]).toBe("site");
    expect(byKey["energy"]).toBe("site");
    expect(byKey["demand"]).toBe("site");
    expect(byKey["power-quality"]).toBe("site");
    expect(byKey["reports"]).toBe("site");
    expect(byKey["alerts"]).toBe("site");
    expect(byKey["spaces"]).toBe("hierarchy");
    expect(byKey["assets"]).toBe("hierarchy");
    // The later-phases catch-all is deliberately not yet part of the agreed IA.
    expect(byKey["features"]).toBeUndefined();
  });

  it("groupNav partitions the visible list into contiguous IA sections without reordering or dropping items", () => {
    const primary = visibleNav(PRIMARY_NAV, VIEWER_USER.permissions);
    const sections = groupNav(primary);

    expect(sections.map((s) => s.group)).toEqual(["site", "hierarchy", undefined]);
    expect(sections[0]!.items.map((i) => i.key)).toEqual([
      "home",
      "energy",
      "demand",
      "power-quality",
      "reports",
      "alerts",
    ]);
    expect(sections[1]!.items.map((i) => i.key)).toEqual(["spaces", "assets"]);
    expect(sections[2]!.items.map((i) => i.key)).toEqual(["features"]);

    // Every visible item still appears exactly once -- grouping is a pure split.
    expect(sections.flatMap((s) => s.items.map((i) => i.key))).toEqual(primary.map((i) => i.key));
  });
});

describe("Coming Soon navigation items", () => {
  it("are exactly Single Line Diagram and Settings, each with a purpose and in-app links", () => {
    expect(COMING_SOON_NAV.map((i) => i.key)).toEqual(["single-line-diagram", "settings"]);
    for (const item of COMING_SOON_NAV) {
      expect(item.to.startsWith("/features/")).toBe(true);
      expect(item.comingSoon.purpose.length).toBeGreaterThan(0);
      for (const link of item.comingSoon.availableNow ?? []) expect(link.to.startsWith("/")).toBe(true);
    }
  });

  it("stay visible in the primary navigation (not hidden)", () => {
    const keys = SHELL_PRIMARY_NAV.map((i) => i.key);
    expect(keys).toContain("single-line-diagram");
    expect(keys).toContain("settings");
  });
});
