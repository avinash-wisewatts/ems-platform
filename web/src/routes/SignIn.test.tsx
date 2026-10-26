import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, screen, waitFor } from "@testing-library/react";
import { Route, Routes } from "react-router-dom";
import { browser } from "../api/client";
import { UnauthenticatedError } from "../api/errors";
import { renderWithProviders, stubFetch } from "../test-utils";
import { LoginRedirect } from "./LoginRedirect";
import { SignIn } from "./SignIn";

const unauthenticated = () => Promise.reject(new UnauthenticatedError());

type Call = { url: string; init?: RequestInit };

function customerHost(login: { status: number; body?: unknown }) {
  const calls: Call[] = [];
  stubFetch((url, init) => {
    calls.push({ url, init });
    if (url === "/auth/session") return { status: 200, jsonBody: { sign_in: "customer" } };
    if (url === "/auth/login") return { status: login.status, jsonBody: login.body };
    return { status: 404 };
  });
  return calls;
}

function renderSignIn(entry = "/sign-in?next=%2Ffeatures%2Fenergy") {
  return renderWithProviders(
    <Routes>
      <Route path="/sign-in" element={<SignIn />} />
      <Route path="/features/energy" element={<p>energy</p>} />
    </Routes>,
    { session: unauthenticated, initialEntries: [entry] },
  );
}

async function fillAndSubmit(username = "viewer@customer.example", password = "pw") {
  const user = await screen.findByLabelText("Username");
  fireEvent.change(user, { target: { value: username } });
  fireEvent.change(screen.getByLabelText("Password"), { target: { value: password } });
  fireEvent.click(screen.getByRole("button", { name: "Sign in" }));
}

describe("SignIn (ADR-023)", () => {
  let assign: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    assign = vi.spyOn(browser, "assign").mockImplementation(() => undefined);
  });
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("on the customer host signs in through /auth/login and loads the return path", async () => {
    const calls = customerHost({ status: 200, body: {} });
    renderSignIn();
    await fillAndSubmit();
    await waitFor(() => expect(assign).toHaveBeenCalledWith("/app/features/energy"));
    const login = calls.find((c) => c.url === "/auth/login")!;
    expect(login.init?.method).toBe("POST");
    expect(login.init?.credentials).toBe("same-origin");
    expect(JSON.parse(String(login.init?.body))).toEqual({ username: "viewer@customer.example", password: "pw" });
    expect(new Headers(login.init?.headers).get("Content-Type")).toBe("application/json");
  });

  it("shows one generic message for rejected credentials and clears the password", async () => {
    customerHost({ status: 401, body: { error: "invalid_credentials" } });
    renderSignIn();
    await fillAndSubmit();
    expect(await screen.findByRole("alert")).toHaveTextContent("Invalid username or password.");
    expect(screen.getByLabelText("Password")).toHaveValue("");
    expect(assign).not.toHaveBeenCalled();
  });

  it("shows an availability message when the sign-in request fails otherwise", async () => {
    customerHost({ status: 403, body: { error: "forbidden" } });
    renderSignIn();
    await fillAndSubmit();
    expect(await screen.findByRole("alert")).toHaveTextContent("Sign-in is unavailable right now.");
  });

  it("hands over to the Administration App's /login where /auth/* does not exist", async () => {
    stubFetch(() => ({ status: 0 })); // opaque redirect to /login
    renderSignIn();
    await waitFor(() => expect(assign).toHaveBeenCalledWith("/login?next_path=%2Fapp%2Ffeatures%2Fenergy"));
    expect(screen.queryByLabelText("Password")).toBeNull();
  });

  it.each(["https://evil.example/x", "//evil.example", "/\\evil", "features"])(
    "never redirects off the app (next=%s)",
    async (next) => {
      customerHost({ status: 200, body: {} });
      renderSignIn(`/sign-in?next=${encodeURIComponent(next)}`);
      await fillAndSubmit();
      await waitFor(() => expect(assign).toHaveBeenCalledWith("/app/"));
    },
  );

  it("disables submit until both fields are filled", async () => {
    customerHost({ status: 200, body: {} });
    renderSignIn();
    const button = await screen.findByRole("button", { name: "Sign in" });
    expect(button).toBeDisabled();
    fireEvent.change(screen.getByLabelText("Username"), { target: { value: "u" } });
    expect(button).toBeDisabled();
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "p" } });
    expect(button).toBeEnabled();
  });
});

describe("LoginRedirect", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("routes an unauthenticated visitor to the sign-in page", async () => {
    vi.spyOn(browser, "assign").mockImplementation(() => undefined);
    customerHost({ status: 200, body: {} });
    renderWithProviders(
      <Routes>
        <Route path="/sign-in" element={<SignIn />} />
        <Route path="*" element={<LoginRedirect />} />
      </Routes>,
      { session: unauthenticated, initialEntries: ["/features/energy"] },
    );
    expect(await screen.findByTestId("page-sign-in")).toBeInTheDocument();
  });
});
