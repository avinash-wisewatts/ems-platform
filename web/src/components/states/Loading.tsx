export function Loading({ label = "Loading…" }: { label?: string }) {
  return (
    <div className="state state--loading" role="status" aria-live="polite" data-testid="state-loading">
      <span className="spinner" aria-hidden="true" />
      <span>{label}</span>
    </div>
  );
}
