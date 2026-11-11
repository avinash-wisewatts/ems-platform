import { describe, expect, it } from "vitest";
import { SERIES_COLORS } from "../../components/ChartFrame";
import { assignSeriesSlots, seriesKey, seriesStyles } from "./analyticsSeriesStyles";

describe("assignSeriesSlots -- a colour follows its series, never its position", () => {
  it("first assignment: slots in order", () => {
    expect([...assignSeriesSlots(new Map(), ["a", "b", "c"])]).toEqual([
      ["a", 0],
      ["b", 1],
      ["c", 2],
    ]);
  });

  it("a series keeps its slot when others are added, removed or reordered", () => {
    const first = assignSeriesSlots(new Map(), ["a", "b", "c"]);
    const second = assignSeriesSlots(first, ["c", "d", "a"]);
    expect(second.get("a")).toBe(0);
    expect(second.get("c")).toBe(2);
    // The new series takes the lowest slot no shown series uses (b's slot 1).
    expect(second.get("d")).toBe(1);
  });

  it("a series that comes back gets its colour back when the slot is free", () => {
    const first = assignSeriesSlots(new Map(), ["a", "b"]);
    const without = assignSeriesSlots(first, ["a"]);
    expect(assignSeriesSlots(without, ["a", "b"]).get("b")).toBe(1);
  });

  it("a remembered slot taken by another shown series is reassigned, never shared", () => {
    const first = assignSeriesSlots(new Map(), ["a", "b"]); // a 0, b 1
    const second = assignSeriesSlots(first, ["a", "c"]); // c takes 1
    const third = assignSeriesSlots(second, ["a", "c", "b"]); // b's 1 is taken
    const shown = ["a", "c", "b"].map((k) => third.get(k));
    expect(new Set(shown).size).toBe(3);
    expect(third.get("c")).toBe(1);
    expect(third.get("b")).toBe(2);
  });

  it("is idempotent for the same keys (safe under re-render)", () => {
    const first = assignSeriesSlots(new Map(), ["a", "b"]);
    expect([...assignSeriesSlots(first, ["a", "b"])]).toEqual([...first]);
  });
});

describe("seriesStyles / seriesKey", () => {
  it("maps slots to the palette", () => {
    const styles = seriesStyles(new Map([["a", 0], ["b", 9]]), ["a", "b"]);
    expect(styles.get("a")).toEqual({ color: SERIES_COLORS[0], pattern: 0 });
    expect(styles.get("b")).toEqual({ color: SERIES_COLORS[1], pattern: 1 });
  });

  it("the key is asset, data point and phase -- the chart's series identity", () => {
    expect(seriesKey({ asset_id: "a1", data_point: "ACTIVE_POWER", qualifier: "L2" })).toBe("a1:ACTIVE_POWER:L2");
  });
});
