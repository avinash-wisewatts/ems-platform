import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, screen, waitFor } from "@testing-library/react";
import { AppRoutes } from "../../router";
import { SITES_ONE, VIEWER_USER, renderWithProviders, stubFetch } from "../../test-utils";
import { resetOwnPasswordChangeAvailability } from "./ChangePasswordPage";

type Call = { url: string; method: string; body: unknown };

function stubBackend({
  customerHost = false,
  change = { status: 204 } as { status: number; jsonBody?: unknown },
}: { customerHost?: boolean; change?: { status: number; jsonBody?: unknown } } = {}) {
  const calls: Call[] = [];
  stubFetch((url, init) => {
    const method = init?.method ?? "GET";
    calls.push({ url, method, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (url === "/auth/session") {
      return customerHost ? { status: 200, jsonBody: { sign_in: "customer" } } : { status: 404, jsonBody: {} };
    }
    if (method === "POST" && url === "/api/admin/v1/me/password") return change;
    return { status: 404, jsonBody: { error: "not_found", detail: "" } };
  });
  return calls;
}

function renderAccount(path = "/account/password") {
  return renderWithProviders(<AppRoutes />, {
    session: () => Promise.resolve(VIEWER_USER),
    sites: () => Promise.resolve(SITES_ONE),
    initialEntries: [path],
  });
}

function fill(current: string, next: string, confirm = next) {
  fireEvent.change(screen.getByTestId("own-current"), { target: { value: current } });
  fireEvent.change(screen.getByTestId("own-new"), { target: { value: next } });
  fireEvent.change(screen.getByTestId("own-confirm"), { target: { value: confirm } });
  fireEvent.click(screen.getByTestId("own-password-submit"));
}

function storedText(): string {
  return JSON.stringify({ ...window.localStorage }) + JSON.stringify({ ...window.sessionStorage });
}

beforeEach(() => {
  resetOwnPasswordChangeAvailability();
  window.localStorage.clear();
  window.sessionStorage.clear();
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe("Change password (/account/password)", () => {
  it("a viewer changes their own password with the current password", async () => {
    const calls = stubBackend();
    renderAccount();
    expect(await screen.findByTestId("own-password-form")).toBeInTheDocument();
    fill("Current-Password-1", "Brand-New-Pass-22");
    expect(await screen.findByTestId("own-password-notice")).toHaveTextContent("Your password was changed.");
    const post = calls.find((c) => c.method === "POST");
    expect(post?.url).toBe("/api/admin/v1/me/password");
    expect(post?.body).toEqual({ current_password: "Current-Password-1", new_password: "Brand-New-Pass-22" });
    expect(storedText()).not.toContain("Brand-New-Pass-22");
    expect(storedText()).not.toContain("Current-Password-1");
  });

  it("validates locally before sending", async () => {
    const calls = stubBackend();
    renderAccount();
    await screen.findByTestId("own-password-form");
    fill("Current-Password-1", "short");
    expect(await screen.findByTestId("own-password-notice")).toHaveTextContent("at least 12");
    fill("Current-Password-1", "Brand-New-Pass-22", "Different-Pass-22");
    expect(await screen.findByTestId("own-password-notice")).toHaveTextContent("do not match");
    expect(calls.some((c) => c.method === "POST")).toBe(false);
  });

  it("shows the server's lockout refusal", async () => {
    stubBackend({
      change: {
        status: 403,
        jsonBody: {
          error: "account_locked",
          detail: "Your account is temporarily locked after failed password attempts. Try again later.",
        },
      },
    });
    renderAccount();
    await screen.findByTestId("own-password-form");
    fill("Current-Password-1", "Brand-New-Pass-22");
    expect(await screen.findByTestId("own-password-notice")).toHaveTextContent("temporarily locked");
  });

  it("is not offered on the customer host", async () => {
    const calls = stubBackend({ customerHost: true });
    renderAccount();
    expect(await screen.findByTestId("account-password-unavailable")).toBeInTheDocument();
    expect(screen.queryByTestId("own-password-form")).not.toBeInTheDocument();
    expect(calls.some((c) => c.url.startsWith("/api/admin/"))).toBe(false);
  });
});

describe("User menu", () => {
  it("links a viewer to Change password on the Administration App path", async () => {
    stubBackend();
    renderAccount("/home");
    fireEvent.click(await screen.findByTestId("user-menu-trigger"));
    expect(await screen.findByTestId("change-password-link")).toHaveAttribute("href", "/account/password");
  });

  it("has no Change password link on the customer host", async () => {
    const calls = stubBackend({ customerHost: true });
    renderAccount("/home");
    fireEvent.click(await screen.findByTestId("user-menu-trigger"));
    await waitFor(() => expect(calls.some((c) => c.url === "/auth/session")).toBe(true));
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(screen.getByTestId("logout")).toBeInTheDocument();
    expect(screen.queryByTestId("change-password-link")).not.toBeInTheDocument();
  });
});
