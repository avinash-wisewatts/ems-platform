import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { SessionProvider, useSession } from "./SessionProvider";
import { UnauthenticatedError } from "../api/errors";
import { NetworkError } from "../api/errors";
import { ADMIN_USER } from "../test-utils";

function Probe() {
  const s = useSession();
  return (
    <div>
      <span data-testid="status">{s.status}</span>
      <span data-testid="user">{s.user?.username ?? "-"}</span>
      <span data-testid="err">{s.error?.name ?? "-"}</span>
    </div>
  );
}

describe("SessionProvider -- bootstraps the existing portal session", () => {
  it("200 from /api/v1/me -> authenticated with identity + permissions", async () => {
    render(
      <SessionProvider loader={() => Promise.resolve(ADMIN_USER)}>
        <Probe />
      </SessionProvider>,
    );
    expect(screen.getByTestId("status").textContent).toBe("loading");
    await waitFor(() => expect(screen.getByTestId("status").textContent).toBe("authenticated"));
    expect(screen.getByTestId("user").textContent).toBe("admin@example.com");
  });

  it("401 -> unauthenticated (not an error state)", async () => {
    render(
      <SessionProvider loader={() => Promise.reject(new UnauthenticatedError())}>
        <Probe />
      </SessionProvider>,
    );
    await waitFor(() => expect(screen.getByTestId("status").textContent).toBe("unauthenticated"));
    expect(screen.getByTestId("err").textContent).toBe("-");
  });

  it("network failure -> error status carrying the cause", async () => {
    render(
      <SessionProvider loader={() => Promise.reject(new NetworkError("backend down"))}>
        <Probe />
      </SessionProvider>,
    );
    await waitFor(() => expect(screen.getByTestId("status").textContent).toBe("error"));
    expect(screen.getByTestId("err").textContent).toBe("NetworkError");
  });

  it("goToLogin sends the browser to the existing /login page", async () => {
    const assign = vi.fn();
    vi.stubGlobal("location", { ...window.location, assign, pathname: "/app/home", search: "" });

    function Trigger() {
      const s = useSession();
      return <button onClick={s.goToLogin}>login</button>;
    }
    render(
      <SessionProvider loader={() => Promise.reject(new UnauthenticatedError())}>
        <Trigger />
      </SessionProvider>,
    );
    screen.getByText("login").click();
    expect(assign).toHaveBeenCalledWith(expect.stringContaining("/login?next_path="));
  });
});
