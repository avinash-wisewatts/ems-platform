import type { ReactNode } from "react";

/**
 * A legitimately empty collection (e.g. a user with zero accessible sites).
 * Distinct from NoDataYet (a time series with no points in the chosen range).
 */
export function EmptyState({
  title = "Nothing here yet",
  children,
}: {
  title?: string;
  children?: ReactNode;
}) {
  return (
    <div className="state state--empty" data-testid="state-empty">
      <p className="state__title">{title}</p>
      {children ? <div className="state__detail">{children}</div> : null}
    </div>
  );
}
