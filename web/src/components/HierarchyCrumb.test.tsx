import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { HierarchyCrumb } from "./HierarchyCrumb";

describe("HierarchyCrumb", () => {
  it("renders the site name only when there is no leaf", () => {
    render(
      <MemoryRouter>
        <HierarchyCrumb siteName="Radisson Blu" />
      </MemoryRouter>,
    );
    expect(screen.getByText("Radisson Blu")).toBeTruthy();
    expect(screen.queryByTestId("hierarchy-crumb-leaf")).toBeNull();
  });

  it("renders Site > leaf label, using the semantic label, never an ID", () => {
    render(
      <MemoryRouter>
        <HierarchyCrumb siteName="Radisson Blu" leaf={{ label: "Banquet Hall 2" }} />
      </MemoryRouter>,
    );
    expect(screen.getByTestId("hierarchy-crumb-leaf")).toHaveTextContent("Banquet Hall 2");
  });

  it("hides the Portfolio-level segment by default (Q62: single-site customers aren't taxed with portfolio ceremony)", () => {
    render(
      <MemoryRouter>
        <HierarchyCrumb siteName="Radisson Blu" />
      </MemoryRouter>,
    );
    expect(screen.queryByTestId("hierarchy-crumb-portfolio")).toBeNull();
  });

  it("shows a non-identifying 'Sites' Portfolio-level link when the user has more than one accessible site (Q69/Q101)", () => {
    render(
      <MemoryRouter>
        <HierarchyCrumb siteName="Radisson Blu" multiSite leaf={{ label: "Energy" }} />
      </MemoryRouter>,
    );
    const portfolio = screen.getByTestId("hierarchy-crumb-portfolio");
    expect(portfolio).toHaveTextContent("Sites");
    expect(portfolio.getAttribute("href")).toBe("/select");
    // Still Site, then the "what" leaf -- Portfolio never replaces either.
    expect(screen.getByText("Radisson Blu")).toBeTruthy();
    expect(screen.getByTestId("hierarchy-crumb-leaf")).toHaveTextContent("Energy");
  });
});
