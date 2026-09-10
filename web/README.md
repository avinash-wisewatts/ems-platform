# EMS Web (Phase 8 frontend foundation)

React/TypeScript application **shell** — no feature dashboards. It consumes the
Phase 7 semantic API (`/api/v1`) only and reuses the existing admin-portal
session (served same-origin under `/app`).

## Commands

```bash
npm ci            # install exact lockfile
npm run typecheck # tsc --noEmit
npm run lint      # eslint, zero warnings
npm run test      # vitest (unit + component)
npm run build     # tsc --noEmit && vite build  -> dist/
npm run dev       # vite dev server on :5173, proxies /api,/login,/logout to :8080
npm run e2e       # Playwright auth/permission E2E -- staging only, see e2e/auth.spec.ts
```

## Boundaries

- No second authentication system. `GET /api/v1/me` echoes the existing signed
  session; unauthenticated visits redirect to the existing `/login` page.
- Frontend permission checks gate navigation/UX only. Tenant isolation stays
  server-side (Phase 7 SECURITY DEFINER functions + session middleware).
- One charting foundation (`ChartFrame`, Recharts). No other chart library.
- The frontend never queries PostgreSQL / TimescaleDB / Grafana / internal
  analytics objects — only the three approved Phase 7 endpoints (+ `/me`).

## Deployment

See `../docs/operations/PHASE8_FRONTEND_DEPLOYMENT.md`. The bundle is an
independent, SHA-tagged artifact, deployed and rolled back separately from the
admin-portal image, with zero effect on the admin portal or Grafana.
