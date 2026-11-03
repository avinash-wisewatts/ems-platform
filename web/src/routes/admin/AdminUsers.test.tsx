import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { Route, Routes } from "react-router-dom";
import { AppRoutes } from "../../router";
import { ADMIN_NAV, visibleNav } from "../../layout/navigation";
import { ADMIN_USER, SITES_ONE, VIEWER_USER, renderWithProviders, stubFetch } from "../../test-utils";
import type { ManagedUser, UserManagementOptions } from "../../api/adminUsers";
import { UsersPage } from "./UsersPage";
import { UserDetailPage } from "./UserDetailPage";

const ORG_A = "aaaaaaaa-1111-4111-8111-000000000001";
const ORG_B = "bbbbbbbb-1111-4111-8111-000000000001";
const SITE_A1 = "aaaaaaaa-2222-4222-8222-000000000001";
const SITE_A2 = "aaaaaaaa-2222-4222-8222-000000000002";

const OPTIONS: UserManagementOptions = {
  actor: { portal_user_id: 1, role_code: "ADMIN", access_scope_mode: "GLOBAL", organization_id: null },
  roles: [
    { role_code: "ADMIN", display_name: "Administrator", description: "Admin things.", permissions: ["user.manage"], assignable: true },
    { role_code: "OPERATOR", display_name: "Operator", description: "Operate.", permissions: ["asset.manage"], assignable: true },
    { role_code: "VIEWER", display_name: "Viewer", description: "Read only.", permissions: ["dashboard.view"], assignable: true },
  ],
  scopes: [
    { access_scope_mode: "GLOBAL", label: "All organizations (WiseWatts staff)" },
    { access_scope_mode: "ORGANIZATION", label: "Whole organization" },
    { access_scope_mode: "SELECTED_SITES", label: "Selected sites" },
  ],
  organizations: [
    { organization_id: ORG_A, organization_name: "Org A", organization_code: "A" },
    { organization_id: ORG_B, organization_name: "Org B", organization_code: "B" },
  ],
  sites: [
    { site_id: SITE_A1, site_name: "Alpha One", site_code: "A1", organization_id: ORG_A, organization_name: "Org A" },
    { site_id: SITE_A2, site_name: "Alpha Two", site_code: "A2", organization_id: ORG_A, organization_name: "Org A" },
  ],
  password_policy: { min_length: 12, max_length: 128 },
};

function user(id: number, overrides: Partial<ManagedUser> = {}): ManagedUser {
  return {
    portal_user_id: id,
    username: `user${id}@example.com`,
    display_name: `User ${id}`,
    email: `user${id}@example.com`,
    role_code: "VIEWER",
    role_label: "Viewer",
    access_scope_mode: "ORGANIZATION",
    organization_id: ORG_A,
    organization_name: "Org A",
    sites: [],
    is_active: true,
    created_at: "2026-10-01T10:00:00Z",
    updated_at: "2026-10-01T10:00:00Z",
    is_self: false,
    ...overrides,
  };
}

const USERS: ManagedUser[] = [
  user(1, { username: "admin@example.com", display_name: "Platform Admin", role_code: "ADMIN", role_label: "Administrator",
    access_scope_mode: "GLOBAL", organization_id: null, organization_name: null, is_self: true }),
  user(10, { display_name: "Alice Viewer" }),
  user(11, { display_name: "Bob Operator", role_code: "OPERATOR", role_label: "Operator", organization_id: ORG_B, organization_name: "Org B" }),
  user(12, { display_name: "Carol Sites", access_scope_mode: "SELECTED_SITES", is_active: false,
    sites: [{ site_id: SITE_A1, site_name: "Alpha One", site_code: "A1" }] }),
];

type Call = { url: string; method: string; body: unknown };

function stubAdminApi(handlers: Partial<Record<string, (body: unknown) => { status?: number; jsonBody?: unknown }>> = {}) {
  const calls: Call[] = [];
  const mock = stubFetch((url, init) => {
    const method = init?.method ?? "GET";
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ url, method, body });
    const key = `${method} ${url}`;
    const handler = handlers[key];
    if (handler) return handler(body);
    if (key === "GET /api/admin/v1/users/options") return { jsonBody: OPTIONS };
    if (key === "GET /api/admin/v1/users") return { jsonBody: { users: USERS } };
    const one = /^GET \/api\/admin\/v1\/users\/(\d+)$/.exec(key);
    if (one) {
      const found = USERS.find((u) => u.portal_user_id === Number(one[1]));
      return found
        ? { jsonBody: { user: found, temporary_password: null } }
        : { status: 404, jsonBody: { error: "not_found", detail: "User not found." } };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "Not found." } };
  });
  return { mock, calls };
}

function renderPage(path: string) {
  return renderWithProviders(
    <Routes>
      <Route path="/admin/users" element={<UsersPage />} />
      <Route path="/admin/users/:portalUserId" element={<UserDetailPage />} />
    </Routes>,
    { initialEntries: [path], sites: () => Promise.resolve(SITES_ONE) },
  );
}

const rows = () => within(screen.getByTestId("users-table")).getAllByRole("row").slice(1);

beforeEach(() => {
  vi.unstubAllGlobals();
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe("Admin navigation", () => {
  it("is visible only with user.manage", () => {
    expect(visibleNav(ADMIN_NAV, ADMIN_USER.permissions).map((i) => i.key)).toEqual(["admin-users"]);
    expect(visibleNav(ADMIN_NAV, VIEWER_USER.permissions)).toEqual([]);
  });

  it("a viewer who opens /admin/users directly gets Not permitted and no admin request is made", async () => {
    const { calls } = stubAdminApi();
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(VIEWER_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/admin/users"],
    });
    expect(await screen.findByTestId("page-forbidden")).toBeInTheDocument();
    expect(screen.queryByTestId("shell-nav-admin")).not.toBeInTheDocument();
    expect(calls.some((c) => c.url.startsWith("/api/admin/"))).toBe(false);
  });

  it("an administrator sees Admin -> Users in the sidebar and reaches the page", async () => {
    stubAdminApi();
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/admin/users"],
    });
    const adminNav = await screen.findByTestId("shell-nav-admin");
    expect(within(adminNav).getByTestId("shell-nav-admin-users")).toHaveAttribute("href", "/admin/users");
    expect(await screen.findByTestId("users-table")).toBeInTheDocument();
  });
});

describe("Users listing", () => {
  it("shows every column for the users the server returned", async () => {
    stubAdminApi();
    renderPage("/admin/users");
    await screen.findByTestId("users-table");
    expect(rows()).toHaveLength(4);
    const carol = within(screen.getByTestId("users-row-12"));
    expect(carol.getByText("user12@example.com", { selector: "a" })).toBeInTheDocument();
    expect(carol.getByText("Carol Sites")).toBeInTheDocument();
    expect(carol.getByText("Viewer")).toBeInTheDocument();
    expect(carol.getByText("Org A")).toBeInTheDocument();
    expect(carol.getByText("Alpha One")).toBeInTheDocument();
    expect(carol.getByText("Inactive")).toBeInTheDocument();
    expect(within(screen.getByTestId("users-row-1")).getByText("You")).toBeInTheDocument();
    expect(within(screen.getByTestId("users-row-1")).getByText("WiseWatts staff")).toBeInTheDocument();
  });

  it("filters by search, role, organization and status", async () => {
    stubAdminApi();
    renderPage("/admin/users");
    await screen.findByTestId("users-table");

    fireEvent.change(screen.getByTestId("users-search"), { target: { value: "bob" } });
    expect(rows().map((r) => r.dataset.testid)).toEqual(["users-row-11"]);
    fireEvent.change(screen.getByTestId("users-search"), { target: { value: "" } });

    fireEvent.change(screen.getByTestId("users-role-filter"), { target: { value: "VIEWER" } });
    expect(rows().map((r) => r.dataset.testid)).toEqual(["users-row-10", "users-row-12"]);

    fireEvent.change(screen.getByTestId("users-status-filter"), { target: { value: "inactive" } });
    expect(rows().map((r) => r.dataset.testid)).toEqual(["users-row-12"]);

    fireEvent.change(screen.getByTestId("users-role-filter"), { target: { value: "" } });
    fireEvent.change(screen.getByTestId("users-status-filter"), { target: { value: "" } });
    fireEvent.change(screen.getByTestId("users-org-filter"), { target: { value: ORG_B } });
    expect(rows().map((r) => r.dataset.testid)).toEqual(["users-row-11"]);
    expect(screen.getByTestId("users-count")).toHaveTextContent("1 of 4 users");
  });

  it("shows a retryable error when the list cannot be loaded", async () => {
    stubAdminApi({ "GET /api/admin/v1/users": () => ({ status: 500, jsonBody: { error: "x", detail: "Boom." } }) });
    renderPage("/admin/users");
    expect(await screen.findByText("Users could not be loaded")).toBeInTheDocument();
  });
});

describe("Create user", () => {
  async function openCreate() {
    renderPage("/admin/users");
    fireEvent.click(await screen.findByTestId("create-user-open"));
    return screen.getByTestId("create-user-form");
  }

  function fillValid() {
    fireEvent.change(screen.getByTestId("create-username"), { target: { value: "new.user" } });
    fireEvent.change(screen.getByTestId("create-display-name"), { target: { value: "New User" } });
    fireEvent.change(screen.getByTestId("create-email"), { target: { value: "new@example.com" } });
    fireEvent.change(screen.getByTestId("create-role"), { target: { value: "OPERATOR" } });
    fireEvent.change(screen.getByTestId("create-scope"), { target: { value: "SELECTED_SITES" } });
    fireEvent.change(screen.getByTestId("create-org"), { target: { value: ORG_A } });
    fireEvent.click(screen.getByTestId(`create-site-${SITE_A2}`));
  }

  it("validates required fields, email and site selection before sending", async () => {
    const { calls } = stubAdminApi();
    await openCreate();
    fireEvent.click(screen.getByTestId("create-submit"));
    expect(screen.getByTestId("create-error")).toHaveTextContent("Enter a username.");
    fireEvent.change(screen.getByTestId("create-username"), { target: { value: "x.user" } });
    fireEvent.change(screen.getByTestId("create-display-name"), { target: { value: "X" } });
    fireEvent.change(screen.getByTestId("create-email"), { target: { value: "not-an-email" } });
    fireEvent.click(screen.getByTestId("create-submit"));
    expect(screen.getByTestId("create-error")).toHaveTextContent("valid email");
    fireEvent.change(screen.getByTestId("create-email"), { target: { value: "x@example.com" } });
    fireEvent.change(screen.getByTestId("create-role"), { target: { value: "VIEWER" } });
    fireEvent.change(screen.getByTestId("create-scope"), { target: { value: "SELECTED_SITES" } });
    fireEvent.change(screen.getByTestId("create-org"), { target: { value: ORG_A } });
    fireEvent.click(screen.getByTestId("create-submit"));
    expect(screen.getByTestId("create-error")).toHaveTextContent("at least one site");
    fireEvent.click(screen.getByTestId("create-password-set"));
    fireEvent.click(screen.getByTestId(`create-site-${SITE_A1}`));
    fireEvent.change(screen.getByTestId("create-password"), { target: { value: "short" } });
    fireEvent.click(screen.getByTestId("create-submit"));
    expect(screen.getByTestId("create-error")).toHaveTextContent("at least 12");
    expect(calls.some((c) => c.method === "POST")).toBe(false);
  });

  it("creates with a generated password, shows it once and adds the user to the list", async () => {
    const created = user(50, { username: "new.user", display_name: "New User", role_code: "OPERATOR", role_label: "Operator",
      access_scope_mode: "SELECTED_SITES", sites: [{ site_id: SITE_A2, site_name: "Alpha Two", site_code: "A2" }] });
    const { calls } = stubAdminApi({
      "POST /api/admin/v1/users": () => ({ status: 201, jsonBody: { user: created, temporary_password: "Tmp-Pass-Word-1234" } }),
    });
    await openCreate();
    fillValid();
    fireEvent.click(screen.getByTestId("create-submit"));

    expect(await screen.findByTestId("temporary-password-value")).toHaveTextContent("Tmp-Pass-Word-1234");
    const post = calls.find((c) => c.method === "POST")!;
    expect(post.body).toEqual({
      username: "new.user",
      display_name: "New User",
      email: "new@example.com",
      role_code: "OPERATOR",
      is_active: true,
      access_scope_mode: "SELECTED_SITES",
      organization_id: ORG_A,
      site_ids: [SITE_A2],
    });
    expect(screen.getByTestId("users-row-50")).toBeInTheDocument();
  });

  it("shows the server's duplicate-username refusal", async () => {
    stubAdminApi({
      "POST /api/admin/v1/users": () => ({ status: 409, jsonBody: { error: "duplicate_username", detail: "A user with this username already exists." } }),
    });
    await openCreate();
    fillValid();
    fireEvent.click(screen.getByTestId("create-submit"));
    expect(await screen.findByTestId("create-error")).toHaveTextContent("A user with this username already exists.");
    expect(screen.getByTestId("create-user-form")).toBeInTheDocument();
  });

  it("a tenant administrator is offered only their own organization and narrower scopes", async () => {
    const tenantOptions: UserManagementOptions = {
      ...OPTIONS,
      actor: { portal_user_id: 5, role_code: "ADMIN", access_scope_mode: "ORGANIZATION", organization_id: ORG_A },
      scopes: OPTIONS.scopes.filter((s) => s.access_scope_mode !== "GLOBAL"),
      organizations: [OPTIONS.organizations[0]!],
    };
    stubAdminApi({ "GET /api/admin/v1/users/options": () => ({ jsonBody: tenantOptions }) });
    await openCreate();
    const scope = screen.getByTestId("create-scope") as HTMLSelectElement;
    expect([...scope.options].map((o) => o.value)).not.toContain("GLOBAL");
    expect(scope.value).toBe("ORGANIZATION");
    const org = screen.getByTestId("create-org") as HTMLSelectElement;
    expect(org.value).toBe(ORG_A);
    expect(org).toBeDisabled();
  });
});

describe("User detail", () => {
  it("edits details through PATCH", async () => {
    const { calls } = stubAdminApi({
      "PATCH /api/admin/v1/users/10": (body) => ({ jsonBody: { user: { ...USERS[1], ...(body as object) }, temporary_password: null } }),
    });
    renderPage("/admin/users/10");
    fireEvent.change(await screen.findByTestId("user-display-name"), { target: { value: "Alice Renamed" } });
    fireEvent.click(screen.getByTestId("user-details-save"));
    expect(await screen.findByTestId("user-details-notice")).toHaveTextContent("Details saved.");
    expect(calls.find((c) => c.method === "PATCH")!.body).toEqual({ display_name: "Alice Renamed", email: "user10@example.com" });
  });

  it("changes role and site access in one request", async () => {
    const { calls } = stubAdminApi({
      "PATCH /api/admin/v1/users/10": () => ({ jsonBody: { user: USERS[1], temporary_password: null } }),
    });
    renderPage("/admin/users/10");
    fireEvent.change(await screen.findByTestId("user-role"), { target: { value: "OPERATOR" } });
    fireEvent.change(screen.getByTestId("user-scope"), { target: { value: "SELECTED_SITES" } });
    fireEvent.click(screen.getByTestId(`user-site-${SITE_A1}`));
    fireEvent.click(screen.getByTestId("user-access-save"));
    await screen.findByTestId("user-access-notice");
    expect(calls.find((c) => c.method === "PATCH")!.body).toEqual({
      role_code: "OPERATOR",
      access_scope_mode: "SELECTED_SITES",
      organization_id: ORG_A,
      site_ids: [SITE_A1],
    });
  });

  it("deactivates after confirmation and reactivates", async () => {
    const { calls } = stubAdminApi({
      "PATCH /api/admin/v1/users/10": (body) => ({ jsonBody: { user: { ...USERS[1], ...(body as object) }, temporary_password: null } }),
    });
    renderPage("/admin/users/10");
    fireEvent.click(await screen.findByTestId("user-deactivate"));
    fireEvent.click(screen.getByTestId("user-deactivate-confirm"));
    await waitFor(() => expect(screen.getByTestId("user-status")).toHaveTextContent("Inactive"));
    fireEvent.click(screen.getByTestId("user-activate"));
    await waitFor(() => expect(screen.getByTestId("user-status")).toHaveTextContent("Active"));
    expect(calls.filter((c) => c.method === "PATCH").map((c) => c.body)).toEqual([{ is_active: false }, { is_active: true }]);
  });

  it("resets another user's password and shows the temporary password once", async () => {
    const { calls } = stubAdminApi({
      "POST /api/admin/v1/users/10/password": () => ({ jsonBody: { portal_user_id: 10, temporary_password: "Reset-Pass-Word-99" } }),
    });
    renderPage("/admin/users/10");
    fireEvent.click(await screen.findByTestId("user-reset-submit"));
    expect(await screen.findByTestId("temporary-password-value")).toHaveTextContent("Reset-Pass-Word-99");
    expect(calls.find((c) => c.method === "POST")!.body).toEqual({});
  });

  it("on one's own account: role, access and status are locked and the password section is Change my password", async () => {
    const { calls } = stubAdminApi({
      "POST /api/admin/v1/me/password": () => ({ status: 204 }),
    });
    renderPage("/admin/users/1");
    expect(await screen.findByTestId("user-access-self")).toBeInTheDocument();
    expect(screen.getByTestId("user-role")).toBeDisabled();
    expect(screen.queryByTestId("user-access-save")).not.toBeInTheDocument();
    expect(screen.queryByTestId("user-deactivate")).not.toBeInTheDocument();
    expect(screen.queryByTestId("user-reset-form")).not.toBeInTheDocument();

    fireEvent.change(screen.getByTestId("own-current"), { target: { value: "Old-Password-123" } });
    fireEvent.change(screen.getByTestId("own-new"), { target: { value: "New-Password-456" } });
    fireEvent.change(screen.getByTestId("own-confirm"), { target: { value: "New-Password-456" } });
    fireEvent.click(screen.getByTestId("own-password-submit"));
    expect(await screen.findByTestId("own-password-notice")).toHaveTextContent("Your password was changed.");
    expect(calls.find((c) => c.method === "POST")!.body).toEqual({
      current_password: "Old-Password-123",
      new_password: "New-Password-456",
    });
  });

  it("a user outside the administrator's scope reads as not found", async () => {
    stubAdminApi();
    renderPage("/admin/users/999");
    expect(await screen.findByText("User not found")).toBeInTheDocument();
  });

  it("shows the server's refusal (privilege escalation is refused server-side)", async () => {
    stubAdminApi({
      "PATCH /api/admin/v1/users/10": () => ({
        status: 403,
        jsonBody: { error: "forbidden", detail: "You cannot grant an access scope wider than your own." },
      }),
    });
    renderPage("/admin/users/10");
    fireEvent.change(await screen.findByTestId("user-scope"), { target: { value: "GLOBAL" } });
    fireEvent.click(screen.getByTestId("user-access-save"));
    expect(await screen.findByTestId("user-access-notice")).toHaveTextContent("wider than your own");
  });
});

describe("Resetting another administrator's password", () => {
  const PEER_ADMIN = user(20, { display_name: "Peer Admin", role_code: "ADMIN", role_label: "Administrator" });
  const tenantOptions: UserManagementOptions = {
    ...OPTIONS,
    actor: { portal_user_id: 5, role_code: "ADMIN", access_scope_mode: "ORGANIZATION", organization_id: ORG_A },
  };

  it("is not offered to a tenant administrator, and no reset request is sent", async () => {
    const { calls } = stubAdminApi({
      "GET /api/admin/v1/users/options": () => ({ jsonBody: tenantOptions }),
      "GET /api/admin/v1/users/20": () => ({ jsonBody: { user: PEER_ADMIN, temporary_password: null } }),
    });
    renderPage("/admin/users/20");
    expect(await screen.findByTestId("reset-password-staff-only")).toHaveTextContent("WiseWatts staff administrators");
    expect(screen.queryByTestId("user-reset-submit")).not.toBeInTheDocument();
    expect(calls.some((c) => c.method === "POST")).toBe(false);
  });

  it("is offered to a WiseWatts staff administrator", async () => {
    stubAdminApi({
      "GET /api/admin/v1/users/20": () => ({ jsonBody: { user: PEER_ADMIN, temporary_password: null } }),
    });
    renderPage("/admin/users/20");
    expect(await screen.findByTestId("user-reset-submit")).toBeInTheDocument();
    expect(screen.queryByTestId("reset-password-staff-only")).not.toBeInTheDocument();
  });

  it("a tenant administrator can still reset a non-administrator", async () => {
    stubAdminApi({ "GET /api/admin/v1/users/options": () => ({ jsonBody: tenantOptions }) });
    renderPage("/admin/users/10");
    expect(await screen.findByTestId("user-reset-submit")).toBeInTheDocument();
  });
});

describe("Passwords never reach browser storage", () => {
  it("a generated temporary password is kept only in page state", async () => {
    window.localStorage.clear();
    window.sessionStorage.clear();
    stubAdminApi({
      "POST /api/admin/v1/users/10/password": () => ({ jsonBody: { portal_user_id: 10, temporary_password: "Reset-Pass-Word-99" } }),
    });
    renderPage("/admin/users/10");
    fireEvent.click(await screen.findByTestId("user-reset-submit"));
    expect(await screen.findByTestId("temporary-password-value")).toHaveTextContent("Reset-Pass-Word-99");
    const stored = JSON.stringify({ ...window.localStorage }) + JSON.stringify({ ...window.sessionStorage });
    expect(stored).not.toContain("Reset-Pass-Word-99");
  });
});
