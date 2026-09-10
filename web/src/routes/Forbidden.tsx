export function Forbidden() {
  return (
    <div className="page page--message" data-testid="page-forbidden">
      <h1>Not permitted</h1>
      <p>Your account does not have permission to view this area.</p>
    </div>
  );
}
