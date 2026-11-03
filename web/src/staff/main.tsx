import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { StaffConsole } from "./StaffConsole";
import "../styles.css";

const container = document.getElementById("root");
if (!container) {
  throw new Error("Root container #root not found");
}

// Served by the Administration App at /admin/* (ADR-023 Amendment 3). The
// routes carry the full /admin/... path, so the Users pages' links are the
// same as in the EMS Web App (/app/admin/users...).
createRoot(container).render(
  <StrictMode>
    <BrowserRouter>
      <StaffConsole />
    </BrowserRouter>
  </StrictMode>,
);
