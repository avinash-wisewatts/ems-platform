import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Staff user-administration console (ADR-023 Amendment 3): a second entry of
// the EMS Web App, served by the Administration App at /admin/* on the staff
// host (proxied to the ems-web container, which holds it under /admin/). It
// shares the source tree with the main bundle (web/src) but is built
// separately because its URL space differs (/admin/ vs /app/).
export default defineConfig({
  root: "staff",
  base: "/admin/",
  publicDir: false,
  plugins: [react()],
  build: {
    outDir: "../dist-staff",
    emptyOutDir: true,
    sourcemap: true,
  },
});
