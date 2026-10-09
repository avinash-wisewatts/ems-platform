import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Route, Routes, useLocation } from "react-router-dom";
import { AppLayout } from "./AppLayout";
import { ADMIN_USER, SITES_ONE, renderWithProviders, stubFetch } from "../test-utils";

/** A matchMedia that answers max-width queries for a settable viewport width
 *  and notifies listeners on resize, like a real browser. */
function fakeViewport(initialWidth: number) {
  let width = initialWidth;
  const lists: { query: string; listeners: Set<(e: { matches: boolean }) => void> }[] = [];
  const matches = (query: string) => {
    const max = /max-width:\s*(\d+)px/.exec(query);
    return max ? width <= Number(max[1]) : false;
  };
  vi.stubGlobal(
    "matchMedia",
    vi.fn((query: string) => {
      const listeners = new Set<(e: { matches: boolean }) => void>();
      lists.push({ query, listeners });
      return {
        get matches() {
          return matches(query);
        },
        media: query,
        addEventListener: (_: string, l: (e: { matches: boolean }) => void) => listeners.add(l),
        removeEventListener: (_: string, l: (e: { matches: boolean }) => void) => listeners.delete(l),
      };
    }),
  );
  return {
    resize(next: number) {
      width = next;
      act(() => lists.forEach(({ query, listeners }) => listeners.forEach((l) => l({ matches: matches(query) }))));
    },
  };
}

function Probe() {
  return <p data-testid="probe-path">{useLocation().pathname}</p>;
}

async function renderShell(path = "/dashboard") {
  renderWithProviders(
    <Routes>
      <Route
        path="*"
        element={
          <AppLayout>
            <Probe />
          </AppLayout>
        }
      />
    </Routes>,
    { session: () => Promise.resolve(ADMIN_USER), sites: () => Promise.resolve(SITES_ONE), initialEntries: [path] },
  );
  await waitFor(() => expect(screen.getByTestId("shell-nav-analytics")).toBeInTheDocument());
  return screen.getByTestId("app-shell");
}

describe("AppLayout -- responsive navigation", () => {
  beforeEach(() => {
    stubFetch(() => ({ status: 404, jsonBody: { error: "not_found", detail: "unexpected" } }));
  });
  afterEach(() => vi.unstubAllGlobals());

  it("desktop (>= 1200 px): full sidebar, no menu button, the existing collapse toggle unchanged", async () => {
    fakeViewport(1440);
    const shell = await renderShell();
    expect(shell.className).toBe("app-shell");
    expect(screen.queryByTestId("shell-menu-toggle")).not.toBeInTheDocument();
    const toggle = screen.getByTestId("sidebar-collapse-toggle");
    expect(toggle).toHaveAttribute("aria-label", "Collapse sidebar");
    await userEvent.click(toggle);
    expect(shell).toHaveClass("app-shell--collapsed");
    expect(toggle).toHaveAttribute("aria-pressed", "true");
  });

  it("without matchMedia (older browsers, test DOM) the desktop layout is used", async () => {
    vi.stubGlobal("matchMedia", undefined);
    const shell = await renderShell();
    expect(shell.className).toBe("app-shell");
  });

  it("tablet (901-1199 px): starts as the icon rail and can still be expanded", async () => {
    fakeViewport(1024);
    const shell = await renderShell();
    expect(shell).toHaveClass("app-shell--collapsed");
    expect(screen.queryByTestId("shell-menu-toggle")).not.toBeInTheDocument();
    await userEvent.click(screen.getByTestId("sidebar-collapse-toggle"));
    expect(shell).not.toHaveClass("app-shell--collapsed");
  });

  it("mobile (<= 900 px): the sidebar is a closed drawer; the menu button opens it, moves focus in, Escape closes it", async () => {
    fakeViewport(390);
    const shell = await renderShell();
    expect(shell).toHaveClass("app-shell--narrow");
    expect(shell).not.toHaveClass("app-shell--collapsed");
    expect(shell).not.toHaveClass("app-shell--drawer-open");
    const menu = screen.getByTestId("shell-menu-toggle");
    expect(menu).toHaveAttribute("aria-label", "Open navigation");
    expect(menu).toHaveAttribute("aria-controls", "app-shell-sidebar");
    expect(menu).toHaveAttribute("aria-expanded", "false");

    await userEvent.click(menu);
    expect(shell).toHaveClass("app-shell--drawer-open");
    expect(menu).toHaveAttribute("aria-expanded", "true");
    const sidebar = document.getElementById("app-shell-sidebar")!;
    expect(sidebar).toHaveAttribute("role", "dialog");
    expect(sidebar).toHaveAttribute("aria-modal", "true");
    const close = within(sidebar).getByTestId("sidebar-collapse-toggle");
    expect(close).toHaveAttribute("aria-label", "Close navigation");
    expect(close).toHaveFocus();

    fireEvent.keyDown(document, { key: "Escape" });
    expect(shell).not.toHaveClass("app-shell--drawer-open");
    expect(menu).toHaveFocus();
  });

  it("mobile: the backdrop and the close button close the drawer", async () => {
    fakeViewport(390);
    const shell = await renderShell();
    await userEvent.click(screen.getByTestId("shell-menu-toggle"));
    await userEvent.click(screen.getByTestId("shell-nav-backdrop"));
    expect(shell).not.toHaveClass("app-shell--drawer-open");
    await userEvent.click(screen.getByTestId("shell-menu-toggle"));
    await userEvent.click(screen.getByTestId("sidebar-collapse-toggle"));
    expect(shell).not.toHaveClass("app-shell--drawer-open");
  });

  it("mobile: choosing a destination navigates, keeps the selected state and closes the drawer", async () => {
    fakeViewport(390);
    const shell = await renderShell("/dashboard");
    expect(screen.getByTestId("shell-nav-main-dashboard")).toHaveClass("active");
    await userEvent.click(screen.getByTestId("shell-menu-toggle"));
    await userEvent.click(screen.getByTestId("shell-nav-analytics"));
    expect(screen.getByTestId("probe-path")).toHaveTextContent("/features/analytics");
    expect(shell).not.toHaveClass("app-shell--drawer-open");
    expect(screen.getByTestId("shell-nav-analytics")).toHaveClass("active");
    // Choosing the current page also closes it.
    await userEvent.click(screen.getByTestId("shell-menu-toggle"));
    await userEvent.click(screen.getByTestId("shell-nav-analytics"));
    expect(shell).not.toHaveClass("app-shell--drawer-open");
  });

  it("follows the breakpoint: narrowing collapses, widening restores the desktop sidebar", async () => {
    const viewport = fakeViewport(1440);
    const shell = await renderShell();
    expect(shell.className).toBe("app-shell");
    viewport.resize(1000);
    expect(shell).toHaveClass("app-shell--collapsed");
    viewport.resize(700);
    expect(shell).toHaveClass("app-shell--narrow");
    expect(shell).not.toHaveClass("app-shell--collapsed");
    await userEvent.click(screen.getByTestId("shell-menu-toggle"));
    expect(shell).toHaveClass("app-shell--drawer-open");
    viewport.resize(1440);
    expect(shell.className).toBe("app-shell");
    expect(screen.queryByTestId("shell-menu-toggle")).not.toBeInTheDocument();
  });
});
