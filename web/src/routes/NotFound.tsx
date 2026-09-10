import { Link } from "react-router-dom";

export function NotFound() {
  return (
    <div className="page page--message" data-testid="page-not-found">
      <h1>Page not found</h1>
      <p>
        <Link to="/home">Return to the home shell</Link>
      </p>
    </div>
  );
}
