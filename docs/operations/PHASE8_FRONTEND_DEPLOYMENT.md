# Phase 8 frontend — deployment & rollback

The Phase 8 web shell (`web/`) is an **independent, immutably-taggable
artifact**. It is deployed and rolled back **separately** from the
`admin-portal` / `live-telemetry` application image, and has **zero effect** on
the admin portal, Grafana, energy pipelines, Phase 6, or the Phase 7 backend
contract.

Nothing in this document has been executed. It records the minimum steps a
future, separately-authorized staging deployment will take.

---

## What was built in Phase 8

| Piece | Where |
|---|---|
| React/TS shell (Vite build → static bundle under base `/app/`) | `web/` |
| Independent artifact image (nginx serving the bundle + a `/srv-spa.tgz` of just the bundle) | `web/Dockerfile` |
| CI: typecheck / lint / unit-test / build the shell | `.github/workflows/ci.yml` job `web-frontend` |
| Same-origin serving hook (inert until a bundle is present) | `app/src/main.py` — `/app` + `/app/assets` |
| Session echo for the SPA (additive; no Phase 7 contract change) | `GET /api/v1/me` in `app/src/routers/analytics_api.py` |
| Auth/permission E2E (staging only, not in unit CI) | `web/e2e/auth.spec.ts` |

## Serving model — same-origin, path-prefixed (preferred)

The bundle is served from **`/app`** by the **existing admin-portal FastAPI
process**, so the browser sends the existing `ems_admin_session` cookie
automatically. No CORS, no second cookie, no parallel auth.

`app/src/main.py` registers the `/app` routes **only when
`app/src/spa/index.html` exists**. In the application image as built today it
does not, so the block is a complete no-op (verified by
`app/tests/test_api_v1_me_and_spa.py`).

### Deploy (staging, when authorized)

1. **Build + push the frontend artifact** (in CI, on the release commit):
   ```
   docker build -f web/Dockerfile -t ghcr.io/<owner>/<repo>-web:<git-sha> ./web
   docker push  ghcr.io/<owner>/<repo>-web:<git-sha>
   ```
2. **Place the bundle in the staging admin-portal checkout** (no admin-portal
   image change):
   ```
   cid=$(docker create ghcr.io/<owner>/<repo>-web:<git-sha>)
   rm -rf /opt/ems-platform/app/src/spa && mkdir -p /opt/ems-platform/app/src/spa
   docker cp "$cid:/srv-spa.tgz" - | tar xzf - -C /opt/ems-platform/app/src/spa
   docker rm "$cid"
   ```
   The admin-portal container mounts the repo checkout, so the bundle is now at
   the container's `/app/src/spa`.
3. **Activate once** — the `/app` routes are registered at process start:
   ```
   docker compose -f /opt/ems-platform/compose.yaml up -d --no-build --no-deps admin-portal
   ```
   (Only `admin-portal` is named — `timescaledb`, `grafana`, `telegraf`,
   `live-telemetry` are untouched.)
   *Subsequent* frontend updates only replace files in `app/src/spa/` and
   **need no restart** (FastAPI serves the files and the `/app/assets`
   directory per request; new hashed asset names are picked up automatically).
4. **Verify**: `GET /app/` returns the shell HTML for an authenticated session;
   an unauthenticated `GET /app` still 303-redirects to `/login`; the admin
   portal's own routes, templates and `/static/*` are unchanged.

Access is gated exactly as Grafana and the admin portal are today: bound to
`127.0.0.1`, reachable only through the EC2 host or an SSH tunnel. No public
exposure until the platform-wide reverse proxy + TLS + auth review lands
(tracked separately; see `compose.yaml` comments).

### Optional steady-state: a read-only bind mount

To avoid the `docker cp` step on every deploy, `compose.yaml`'s `admin-portal`
service may later add:
```
volumes:
  - ${EMS_WEB_SPA_PATH:-/opt/ems-platform/web-spa}:/app/src/spa:ro
```
and the deploy step becomes "extract the tarball into `$EMS_WEB_SPA_PATH`".
This change is **not** made in Phase 8 (it edits shared deployment config); it
is documented here as the intended follow-up.

## Rollback

A rollback is just re-placing the previous bundle:
```
cid=$(docker create ghcr.io/<owner>/<repo>-web:<previous-git-sha>)
rm -rf /opt/ems-platform/app/src/spa && mkdir -p /opt/ems-platform/app/src/spa
docker cp "$cid:/srv-spa.tgz" - | tar xzf - -C /opt/ems-platform/app/src/spa
docker rm "$cid"
```
No admin-portal image change, no migration (Phase 8 adds none), no restart
after the first activation. GHCR retains every SHA-tagged `-web` image
indefinitely, so any past release commit is a valid rollback target. The
existing `rollback.yml` can also be pointed at a `-web` image tag once the
deploy step above is wired into `deploy-staging.yml`.

If the shell must be removed entirely: delete `app/src/spa/` and restart
`admin-portal`. The `/app` routes vanish; nothing else changes.

## Fallback serving model — sidecar + front proxy

If path-prefixed serving is ever unsuitable, run `web/Dockerfile`'s image as a
`web-frontend` compose service (`127.0.0.1:<port>`) and have a front proxy
route `/app` → `web-frontend` and `/api`,`/login`,`/logout` → `admin-portal`.
Same cookie (same host), still no CORS. This is heavier (a proxy) and is not
the Phase 8 choice; documented for completeness.

## Deploy-staging.yml wiring (documented, not changed in Phase 8)

`deploy-staging.yml` will need, alongside the existing app image build:
- a step building/pushing `ghcr.io/<owner>/<repo>-web:${{ github.sha }}`;
- a step in the SSH deploy that performs the "place the bundle + activate once"
  sequence above.
These are deployment-config changes and are out of scope for the Phase 8
implementation (which must not modify production/staging deployment config).

## Security residuals (`npm audit`)

`npm audit` on the dev/build toolchain reports findings that are **not shipped**
in the production bundle:
- **vite / esbuild dev-server** advisories — apply only to `vite dev` on a
  developer's machine, never to the static `dist/` served in staging;
- **vitest / @vitest/mocker** — test-runner only; the "UI server" critical
  requires `vitest --ui`, which is never invoked;
- **react-router (@remix-run/router)** open-redirect / SSR-hydration advisories
  — the shell is client-only (no SSR), every navigation target is a hardcoded
  literal, and the one URL-derived value (`next_path`) is consumed by the
  existing server `/login`, which already sanitises redirect paths
  (`safe_login_redirect_path`, `test_portal_redirects.py`). A React Router v7
  migration is the tracked follow-up.
The shipped bundle depends only on `react`, `react-dom`, `react-router-dom`,
`recharts`. The CI `web-frontend` job runs `npm audit --omit=dev` for report
(non-blocking).
