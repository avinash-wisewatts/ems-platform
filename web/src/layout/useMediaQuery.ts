import { useEffect, useMemo, useState } from "react";

/** Narrow screens (phones, small tablets): the shell's navigation becomes a
 *  drawer and the Analytics filter panel an overlay (D82) -- one breakpoint
 *  for both. */
export const NARROW_SCREEN_QUERY = "(max-width: 900px)";

/** Compact screens (tablets, small laptops): the shell's navigation starts as
 *  the icon rail so the content keeps the width. */
export const COMPACT_SCREEN_QUERY = "(max-width: 1199px)";

/** Whether `query` matches, following changes (resize, rotation). False where
 *  matchMedia is unavailable (e.g. the test DOM), i.e. the desktop layout. */
export function useMediaQuery(query: string): boolean {
  const list = useMemo(
    () => (typeof window !== "undefined" && typeof window.matchMedia === "function" ? window.matchMedia(query) : null),
    [query],
  );
  const [matches, setMatches] = useState(list?.matches ?? false);
  useEffect(() => {
    if (!list) return;
    setMatches(list.matches);
    const onChange = (event: MediaQueryListEvent) => setMatches(event.matches);
    list.addEventListener("change", onChange);
    return () => list.removeEventListener("change", onChange);
  }, [list]);
  return matches;
}
