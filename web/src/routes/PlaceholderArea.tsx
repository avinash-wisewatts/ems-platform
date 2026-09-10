import { PLANNED_FEATURE_AREAS } from "../layout/navigation";

/**
 * Honest placeholder for the feature-route namespace. It deliberately does NOT
 * pretend any later-phase feature exists. Later phases replace this with real
 * screens without touching auth, tenant context, routing, or layout.
 */
export function PlaceholderArea() {
  return (
    <div className="page page--placeholder" data-testid="page-placeholder">
      <h1>Feature area</h1>
      <p>
        This is the foundation shell (Phase 8). Feature screens are delivered in later phases and are
        not implemented yet.
      </p>
      <h2>Planned areas</h2>
      <ul>
        {PLANNED_FEATURE_AREAS.map((area) => (
          <li key={area.key}>
            {area.label} — <em>not yet implemented</em>
          </li>
        ))}
      </ul>
    </div>
  );
}
