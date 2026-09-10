/// <reference types="vitest/config" />
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

// The shell is served same-origin under /app by the existing admin-portal
// (see docs/operations/PHASE8_FRONTEND_DEPLOYMENT.md). All asset URLs and the
// client-side router therefore live under that prefix.
const BASE_PATH = "/app/";

// Local development: proxy the same-origin backend paths to the admin-portal
// dev server so the session cookie and the Phase 7 API behave exactly as in
// staging without any CORS configuration. Override with EMS_DEV_BACKEND.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, ".", "EMS_");
  const devBackend = env.EMS_DEV_BACKEND || "http://127.0.0.1:8080";

  return {
    base: BASE_PATH,
    plugins: [react()],
    server: {
      port: 5173,
      proxy: {
        "/api": { target: devBackend, changeOrigin: false },
        "/login": { target: devBackend, changeOrigin: false },
        "/logout": { target: devBackend, changeOrigin: false },
      },
    },
    build: {
      outDir: "dist",
      sourcemap: true,
    },
    test: {
      globals: true,
      environment: "jsdom",
      setupFiles: ["./vitest.setup.ts"],
      css: false,
      include: ["src/**/*.{test,spec}.{ts,tsx}"],
    },
  };
});
