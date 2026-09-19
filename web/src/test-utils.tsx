import type { ReactElement, ReactNode } from "react";
import { render } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { vi } from "vitest";
import { SessionProvider } from "./auth/SessionProvider";
import { TenantProvider } from "./tenant/TenantProvider";
import type { CurrentUser, SitesResponse } from "./api/types";

export const ADMIN_USER: CurrentUser = {
  portal_user_id: 1,
  username: "admin@example.com",
  display_name: "Platform Admin",
  role_code: "ADMIN",
  access_scope_mode: "GLOBAL",
  organization_id: null,
  site_ids: [],
  permissions: [
    "organization.manage",
    "user.manage",
    "site.manage",
    "location.manage",
    "asset.manage",
    "gateway.manage",
    "device.manage",
    "relationship.manage",
    "metering_policy.manage",
    "commissioning.execute",
    "alert.acknowledge",
    "dashboard.view",
    "report.export",
    "audit.view",
  ],
};

export const VIEWER_USER: CurrentUser = {
  portal_user_id: 2,
  username: "viewer@example.com",
  display_name: "Read Only",
  role_code: "VIEWER",
  access_scope_mode: "ORGANIZATION",
  organization_id: "11111111-1111-4111-8111-111111111111",
  site_ids: [],
  permissions: ["dashboard.view", "report.export"],
};

export const NO_SHELL_USER: CurrentUser = {
  ...VIEWER_USER,
  portal_user_id: 3,
  permissions: [], // no dashboard.view -> cannot use the shell
};

export const SITES_TWO_ORGS: SitesResponse = {
  sites: [
    {
      site_id: "aaaaaaaa-0000-4000-8000-000000000001",
      organization_id: "org-a",
      organization_name: "Org A",
      site_code: "A_ONE",
      site_name: "Alpha One",
      timezone: "Asia/Kolkata",
    },
    {
      site_id: "aaaaaaaa-0000-4000-8000-000000000002",
      organization_id: "org-a",
      organization_name: "Org A",
      site_code: "A_TWO",
      site_name: "Alpha Two",
      timezone: "Asia/Kolkata",
    },
    {
      site_id: "bbbbbbbb-0000-4000-8000-000000000001",
      organization_id: "org-b",
      organization_name: "Org B",
      site_code: "B_ONE",
      site_name: "Bravo One",
      timezone: "UTC",
    },
  ],
};

export const SITES_ONE: SitesResponse = {
  sites: [SITES_TWO_ORGS.sites[0]!],
};

export const SITES_THREE_ORGS: SitesResponse = {
  sites: [
    ...SITES_TWO_ORGS.sites,
    {
      site_id: "cccccccc-0000-4000-8000-000000000001",
      organization_id: "org-c",
      organization_name: "Org C",
      site_code: "C_ONE",
      site_name: "Charlie One",
      timezone: "UTC",
    },
    {
      site_id: "cccccccc-0000-4000-8000-000000000002",
      organization_id: "org-c",
      organization_name: "Org C",
      site_code: "C_TWO",
      site_name: "Charlie Two",
      timezone: "UTC",
    },
  ],
};

type RenderOptions = {
  session?: () => Promise<CurrentUser>;
  sites?: () => Promise<SitesResponse>;
  initialEntries?: string[];
};

/** Render a subtree with Session + Tenant providers using injected loaders. */
export function renderWithProviders(ui: ReactElement, opts: RenderOptions = {}) {
  const session = opts.session ?? (() => Promise.resolve(ADMIN_USER));
  const sites = opts.sites ?? (() => Promise.resolve(SITES_TWO_ORGS));

  function Wrapper({ children }: { children: ReactNode }) {
    return (
      <MemoryRouter initialEntries={opts.initialEntries ?? ["/"]}>
        <SessionProvider loader={session}>
          <TenantProvider loader={sites}>{children}</TenantProvider>
        </SessionProvider>
      </MemoryRouter>
    );
  }

  return render(ui, { wrapper: Wrapper });
}

/** Stub global fetch with a scripted responder. Returns the mock. */
export function stubFetch(
  responder: (url: string, init?: RequestInit) => Partial<Response> & { jsonBody?: unknown },
) {
  const mock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const r = responder(url, init);
    const status = r.status ?? 200;
    return {
      ok: r.ok ?? (status >= 200 && status < 300),
      status,
      statusText: r.statusText ?? "",
      headers: new Headers(),
      json: async () => r.jsonBody,
      text: async () => JSON.stringify(r.jsonBody ?? ""),
    } as unknown as Response;
  });
  vi.stubGlobal("fetch", mock);
  return mock;
}
