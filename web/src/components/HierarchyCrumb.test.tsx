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
});
