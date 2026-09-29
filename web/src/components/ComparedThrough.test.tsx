import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { ComparedThrough, comparedThroughText } from "./ComparedThrough";

describe("ComparedThrough -- site-local qualifier for a matched elapsed-portion comparison", () => {
  it("formats the cut-off in the site's timezone", () => {
    // Today's local midnight in IST (00:00, 15 Jun) and the last completed UTC hour.
    expect(comparedThroughText("2026-06-14T18:30:00.000Z", "Asia/Kolkata")).toBe("Compared through 00:00, 15 Jun");
    expect(comparedThroughText("2026-06-15T12:00:00.000Z", "Asia/Kolkata")).toBe("Compared through 17:30, 15 Jun");
    expect(comparedThroughText("2026-06-14T18:15:00.000Z", "Asia/Kathmandu")).toBe("Compared through 00:00, 15 Jun");
    expect(comparedThroughText("2026-10-24T23:00:00.000Z", "Europe/London")).toBe("Compared through 00:00, 25 Oct");
  });

  it("renders nothing when the whole period is compared", () => {
    expect(comparedThroughText(null, "Asia/Kolkata")).toBeNull();
    const { container } = render(<ComparedThrough comparedUntil={null} timeZone="Asia/Kolkata" />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders the qualifier text", () => {
    render(<ComparedThrough comparedUntil="2026-06-14T18:30:00.000Z" timeZone="Asia/Kolkata" />);
    expect(screen.getByTestId("compared-through")).toHaveTextContent("Compared through 00:00, 15 Jun");
  });
});
