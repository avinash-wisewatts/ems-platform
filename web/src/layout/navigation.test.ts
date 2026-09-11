import { describe, expect, it } from "vitest";
import { PRIMARY_NAV, SECONDARY_NAV, visibleNav } from "./navigation";
import { ADMIN_USER, VIEWER_USER } from "../test-utils";

describe("navigation model -- permission gates VISIBILITY only", () => {
  it("a VIEWER sees the primary shell nav, including the Slice 0/A real screens, but not admin affordances", () => {
    const primary = visibleNav(PRIMARY_NAV, VIEWER_USER.permissions);
    const secondary = visibleNav(SECONDARY_NAV, VIEWER_USER.permissions);
    expect(primary.map((i) => i.key)).toEqual(["home", "energy", "spaces", "assets", "features"]);
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
