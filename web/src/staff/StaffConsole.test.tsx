import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { stubFetch } from "../test-utils";
import type { AdminMe, UserManagementOptions } from "../api/adminUsers";
import { StaffConsole, staffBrowser, staffLoginUrl } from "./StaffConsole";

const STAFF: AdminMe = {
  portal_user_id: 1,
  username: "admin_user",
  display_name: "EMS Administrator",
  role_code: "ADMIN",
  access_scope_mode: "GLOBAL",
  organization_id: null,
  is_staff: true,
  permissions: ["dashboard.view", "user.manage"],
};

const OPTIONS: UserManagementOptions = {
  actor: { portal_user_id: 1, role_code: "ADMIN", access_scope_mode: "GLOBAL", organization_id: null },
  roles: [{ role_code: "VIEWER", display_name: "Viewer", description: "Read only.", permissions: [], assignable: true }],
  scopes: [{ access_scope_mode: "GLOBAL", label: "All organizations (WiseWatts staff)" }],
  organizations: [],
  sites: [],
  password_policy: { min_length: 12, max_length: 128 },
};

function stubApi(me: { status?: number; jsonBody?: unknown }) {
  return stubFetch((url) => {
    if (url === "/api/admin/v1/me") return me;
    if (url === "/api/admin/v1/users/options") return { jsonBody: OPTIONS };
    if (url === "/api/admin/v1/users") return { jsonBody: { users: [] } };
    return { status: 404, jsonBody: { error: "not_found", detail: "" } };
  });
}

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <StaffConsole />
    </MemoryRouter>,
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("StaffConsole (/admin/*)", () => {
  it("shows Users for a staff administrator, using only /api/admin/v1", async () => {
    const fetchMock = stubApi({ jsonBody: STAFF });
    renderAt("/admin/users");
    expect(await screen.findByTestId("staff-console")).toBeInTheDocument();
    expect(screen.getByTestId("staff-console-user")).toHaveTextContent("EMS Administrator");
    await waitFor(() => expect(fetchMock.mock.calls.some(([u]) => u === "/api/admin/v1/users")).toBe(true));
    const urls = fetchMock.mock.calls.map(([u]) => String(u));
    expect(urls.every((u) => u.startsWith("/api/admin/v1/"))).toBe(true);
  });

  it("redirects unknown /admin paths to /admin/users", async () => {
    const fetchMock = stubApi({ jsonBody: STAFF });
    renderAt("/admin/whatever");
    expect(await screen.findByTestId("staff-console")).toBeInTheDocument();
    // The Users page (and nothing else) loads its list.
    await waitFor(() => expect(fetchMock.mock.calls.some(([u]) => u === "/api/admin/v1/users")).toBe(true));
  });

  it("refuses a tenant (non-GLOBAL) administrator", async () => {
    stubApi({ jsonBody: { ...STAFF, access_scope_mode: "ORGANIZATION", organization_id: "o", is_staff: false } });
    renderAt("/admin/users");
    expect(await screen.findByTestId("staff-console-denied")).toBeInTheDocument();
    expect(screen.queryByTestId("staff-console")).not.toBeInTheDocument();
  });

  it("refuses an identity without user.manage (403 from the probe)", async () => {
    stubApi({ status: 403, jsonBody: { error: "forbidden", detail: "No." } });
    renderAt("/admin/users");
    expect(await screen.findByTestId("staff-console-denied")).toBeInTheDocument();
  });

  it("sends an expired session to the Administration App login, returning to the same path", async () => {
    const assign = vi.spyOn(staffBrowser, "assign").mockImplementation(() => undefined);
    stubApi({ status: 401, jsonBody: { error: "unauthenticated", detail: "" } });
    renderAt("/admin/users");
    await waitFor(() => expect(assign).toHaveBeenCalledTimes(1));
    expect(String(assign.mock.calls[0]?.[0])).toMatch(/^\/login\?next_path=/);
  });

  it("builds a login URL that preserves the path", () => {
    expect(staffLoginUrl("/admin/users/5")).toBe("/login?next_path=%2Fadmin%2Fusers%2F5");
  });
});
