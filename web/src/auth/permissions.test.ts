import { describe, expect, it } from "vitest";
import { canUseShell, hasAnyPermission, hasPermission, SHELL_MINIMUM_PERMISSION } from "./permissions";

const admin = { permissions: ["dashboard.view", "site.manage", "user.manage"] };
const viewer = { permissions: ["dashboard.view", "report.export"] };
const none = { permissions: [] as string[] };

describe("frontend permission helpers (UX gating only)", () => {
  it("hasPermission", () => {
    expect(hasPermission(admin, "site.manage")).toBe(true);
    expect(hasPermission(viewer, "site.manage")).toBe(false);
    expect(hasPermission(null, "dashboard.view")).toBe(false);
  });

  it("hasAnyPermission", () => {
    expect(hasAnyPermission(viewer, ["site.manage", "report.export"])).toBe(true);
    expect(hasAnyPermission(viewer, ["site.manage", "user.manage"])).toBe(false);
  });

  it("every non-empty role can use the shell; the minimum is dashboard.view", () => {
    expect(SHELL_MINIMUM_PERMISSION).toBe("dashboard.view");
    expect(canUseShell(admin)).toBe(true);
    expect(canUseShell(viewer)).toBe(true);
    expect(canUseShell(none)).toBe(false);
    expect(canUseShell(null)).toBe(false);
  });
});
