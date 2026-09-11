import { describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import { SpacesList } from "./SpacesList";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

describe("SpacesList (Slice 0)", () => {
  it("renders the accessible site's spaces as links, once the site auto-selects", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/spaces`)) {
        return {
          jsonBody: {
            site_id: SITE_ID,
            spaces: [{ space_id: "space-1", site_id: SITE_ID, space_code: "BANQUET_2", space_name: "Banquet Hall 2" }],
          },
        };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SpacesList />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("spaces-list")).toBeTruthy());
    expect(screen.getByText("Banquet Hall 2")).toBeTruthy();
  });

  it("renders EmptyState, not an error, when the site has zero spaces", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/spaces`)) {
        return { jsonBody: { site_id: SITE_ID, spaces: [] } };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SpacesList />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("state-empty")).toBeTruthy());
  });
});
