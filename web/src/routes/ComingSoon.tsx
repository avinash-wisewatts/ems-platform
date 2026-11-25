import { Link } from "react-router-dom";
import type { ComingSoonInfo } from "../layout/navigation";

/**
 * Coming Soon page for a primary-navigation area that is not built yet
 * (navigation.ts `comingSoon`). Says plainly that the area is not available,
 * what it will be for, and links to what the user can already do -- no
 * engineering phase names, no dates, no fabricated content.
 */
export function ComingSoon({ title, info }: { title: string; info: ComingSoonInfo }) {
  return (
    <div className="page page--coming-soon" data-testid="page-coming-soon">
      <h1>
        {title} <span className="coming-soon-tag">Coming soon</span>
      </h1>
      <p>{info.purpose}</p>
      <p className="coming-soon__note">This area is not available yet.</p>
      {info.availableNow && info.availableNow.length > 0 ? (
        <>
          <h2>Available now</h2>
          <ul className="coming-soon__links">
            {info.availableNow.map((link) => (
              <li key={link.to}>
                <Link to={link.to}>{link.label}</Link>
              </li>
            ))}
          </ul>
        </>
      ) : null}
    </div>
  );
}
