# Phase 8 frontend — deployment & rollback

The Phase 8 web shell (`web/`) is an **independent, immutably git-SHA-tagged
artifact**. It is deployed and rolled back **separately** from the
`admin-portal` / `live-telemetry` application image, and has **zero effect** on
the admin portal, Grafana, energy pipelines, Phase 6, or the Phase 7 backend
contract.

This document records the mechanism that is now wired into the repository.
**Status (2026-10-26):** the bind-mounted bundle mechanism below is deployed
on staging (5 `-web` deploys recorded 2026-10-24…25); production serves no
frontend (API-only, release plan D6). The dedicated-container mode in the
next section is **implemented on `feature/ems-web-container`, not merged, not
deployed**.

---

## Dedicated container mode — `ems-web` (implemented, not deployed)

Approved 2026-10-26 ("Option A"; ADR-006 Amendment 1). The same `-web:<sha>`
image runs as the `ems-web` compose service, and `admin-portal` proxies
`/app/*` to it **after** its existing authentication/authorization
middleware.

```
browser ── :8080 ── admin-portal ──(session + DASHBOARD_VIEW)──▶ /app/* ──▶ ems-web:80 (nginx, no host port)
                        └── /login /logout /api/v1/* /api/live/* /administration/* (unchanged)
```

| Concern | Behaviour |
|---|---|
| URL / origin / cookie | Unchanged: `/app` on the admin-portal origin, `ems_admin_session`, no CORS, no new public port |
| Unauthenticated `/app/*` (incl. assets) | Unchanged: 303 → `/login?next_path=…`; never reaches `ems-web` |
| Permission | Unchanged: `/app/*` GET/HEAD requires `DASHBOARD_VIEW` |
| Forwarded to `ems-web` | GET/HEAD only; `Accept`, `If-None-Match`, `If-Modified-Since` only — **no Cookie, Authorization or X-Forwarded-***; dot-segment paths rejected (404) |
| Returned from `ems-web` | Status + `Content-Type`, `Cache-Control`, `ETag`, `Last-Modified`, `Expires`, `X-Robots-Tag`, relative `Location` only |
| Caching | Entry document / client routes: `no-store`. Hashed `/app/assets/*`: `public, max-age=31536000, immutable`; missing asset → 404 |
| `ems-web` down | `/app/*` → 502 (`no-store`); `/login`, `/api/v1/*`, admin routes unaffected; recovers when `ems-web` is back |
| Hardening | No host port, no env file/secrets, read-only root fs (tmpfs for nginx paths), `no-new-privileges`, `server_tokens off`, `absolute_redirect off` |

**Switch.** `EMS_WEB_UPSTREAM` in the host **root** `.env` (compose passes it
to `admin-portal`; empty by default):

```
EMS_WEB_UPSTREAM=http://ems-web:80
```

`admin-portal` reads it at process start, so turning container mode on or
off is a host `.env` edit plus one `admin-portal` recreate
(`docker compose -f <path>/compose.yaml up -d --no-build --no-deps --force-recreate admin-portal`).
This is a one-time, separately authorized step per host; after it, frontend
deploys never touch `admin-portal`.

**Web-only deploy / rollback.** One operation, either direction:

- GitHub: `deploy-web.yml` → `target_environment=staging`,
  `web_git_sha=<40-char sha>` (must be in `staging`'s history; resolved to
  its digest).
- Host: `EMS_WEB_IMAGE=ghcr.io/<owner>/<repo>-web:<sha>@sha256:<digest> PROJECT_PATH=<path> ENVIRONMENT_NAME=staging <path>/scripts/release/deploy_web.sh`

`deploy_web.sh` checks the deployed `compose.yaml` defines `ems-web`; pulls;
refuses an image whose `org.opencontainers.image.revision` label disagrees
with its tag or that lacks `/usr/share/nginx/html/app/index.html`; recreates
**only** `ems-web` (`--no-deps --no-build`); waits for health and, if the new
image is unhealthy, restores the previously running image and fails;
appends `<PROJECT_PATH>/.deploy-history/<env>-web-container.log`
(`…|<ref>|<repo digest>|previous=<ref>`). It never runs migrations, never
moves the host checkout, never edits a `.env`, never names another service.

**Normal releases.** `deploy-staging.yml` now builds the `-web` image with
`--build-arg GIT_SHA=<sha>` (provenance label), captures its pushed digest,
and runs `deploy_web.sh` by digest **after** `deploy_web_bundle.sh` (kept, so
the fallback stays current) and **before** `deploy_release.sh`.
`rollback.yml` is unchanged (its `web_image_tag` still drives the bundle
fallback). `deploy-production.yml` deploys neither (contract-tested).

**Fallback.** Unset `EMS_WEB_UPSTREAM` and recreate `admin-portal`: `/app`
is served again from the bind-mounted bundle exactly as before. Rolling the
`-app` image back to a commit that predates this change has the same effect
(that `compose.yaml` has no `EMS_WEB_UPSTREAM`); a running `ems-web` is then
simply unused.

**Production.** Not a target of `deploy-web.yml` and not deployed by
`deploy-production.yml` — production stays API-only until a separately
authorized frontend rollout (D6). The Reports dependency is already handled
for that day: `GET /api/v1/me` advertises `report.export` only where
`EMS_REPORTS_ENABLED` is on, so the SPA hides the Reports tab and never
polls the (unmounted) report-export routes on production.

**Verification assets.** `scripts/test/assert_ems_web_container.sh <image>
[<sha>]` (also a CI step in `web-docker-build-validate`);
`app/tests/test_web_upstream_proxy.py`;
`app/tests/test_web_container_release_contract.py`.

---

## What was built in Phase 8

| Piece | Where |
|---|---|
| React/TS shell (Vite build → static bundle under base `/app/`) | `web/` |
| Independent artifact image — carries the built bundle **and** `/srv-spa.tgz` (a tarball of just the bundle) | `web/Dockerfile` |
| CI gate: typecheck / lint / unit-test / build the shell (no image push) | `.github/workflows/ci.yml` job `web-frontend` |
| CI gate: `web/Dockerfile` builds (validation only, not pushed) | `.github/workflows/ci.yml` job `web-docker-build-validate` |
| CI: **build + push** `…-web:<git-sha>` to GHCR, then place it on staging | `.github/workflows/deploy-staging.yml` jobs `build-and-push-web` + `deploy-staging` |
| Host-side bundle placement (pull `-web:<sha>` → extract `/srv-spa.tgz` → atomic swap into `${EMS_WEB_SPA_PATH}`) | `scripts/release/deploy_web_bundle.sh` |
| Read-only bind mount delivering the bundle into the running container | `compose.yaml` — `admin-portal` → `${EMS_WEB_SPA_PATH:-./web-spa}:/app/src/spa:ro` |
| Same-origin serving hook (inert until a bundle is present) | `app/src/main.py` — `/app` + `/app/assets` |
| Session echo for the SPA (additive; no Phase 7 contract change) | `GET /api/v1/me` in `app/src/routers/analytics_api.py` |
| Optional independent frontend rollback input | `.github/workflows/rollback.yml` — `web_image_tag` |
| Auth/permission E2E (staging only, not in unit CI) | `web/e2e/auth.spec.ts` |

---

## Serving model — same-origin, path-prefixed

The bundle is served from **`/app`** by the **existing admin-portal FastAPI
process**, so the browser sends the existing `ems_admin_session` cookie
automatically. No CORS, no second cookie, no parallel auth, no reverse proxy.

`app/src/main.py` registers the `/app` routes (and mounts `/app/assets`)
**only when `app/src/spa/index.html` exists at process start**. In the
application image as built, it does not — the block is a complete no-op
(verified by `app/tests/test_api_v1_me_and_spa.py`). The bundle is supplied at
runtime through the bind mount described below.

### How the bundle reaches the container — the corrected mechanism

> **Correction.** An earlier draft of this document stated that "the
> admin-portal container mounts the repo checkout, so [a `docker cp` into]
> `app/src/spa` … is now at the container's `/app/src/spa`." **That is wrong.**
> `app/src` is **baked into the admin-portal image** (`app/Dockerfile`:
> `COPY src /app/src`); it is **not** a bind mount. Copying files into the host
> path `…/app/src/spa/` has **no effect** on the running container.

The bundle reaches `/app/src/spa` **inside the container** through **one new
read-only bind mount** on the `admin-portal` service (`compose.yaml`):

```yaml
volumes:
  - ./grafana/dashboards:/app/grafana-dashboards:ro          # existing
  - ${EMS_WEB_SPA_PATH:-./web-spa}:/app/src/spa:ro           # Phase 8
```

- `${EMS_WEB_SPA_PATH}` defaults to `./web-spa`, i.e. `<PROJECT_PATH>/web-spa`
  on the host. Override it only in the host root `.env`
  (`EMS_WEB_SPA_PATH=…`); `deploy_web_bundle.sh` reads the same value from
  that file so the extract target and the mount source cannot diverge.
- When the directory **does not exist**, `docker compose` creates it empty →
  `index.html` is absent → the `/app` hook stays inert → the admin portal is
  exactly as before. This is the **safe default** on any host — including
  production — that has not deployed the frontend.
- The mount is **`:ro`**. The application process never writes the bundle.

`scripts/release/deploy_web_bundle.sh` populates that host directory:

1. `docker pull` the exact `ghcr.io/<owner>/<repo>-web:<git-sha>` image.
2. `docker create` (never *start*) a container from it, `docker cp` its
   `/srv-spa.tgz` out, `docker rm` the container.
3. Unpack the tarball into a staging directory **on the same filesystem** as
   `${EMS_WEB_SPA_PATH}`; refuse to publish if it has no `index.html`.
4. Atomically swap it into place (`rename(2)`), keeping the previous bundle at
   `${EMS_WEB_SPA_PATH}.previous` for an emergency local rollback.
5. Append `<PROJECT_PATH>/.deploy-history/<env>-web.log`.

It names **no compose service** and never touches the database, migrations,
Grafana, telegraf or timescaledb.

### Restart semantics

The `/app` routes are registered at **process start**, so the `admin-portal`
container must be **(re)created once** after the bundle first appears:

```
docker compose -f <PROJECT_PATH>/compose.yaml up -d --no-build --no-deps admin-portal
```

In the normal pipeline this is not an extra step — `deploy_release.sh`
runs exactly this (`APP_SERVICES` default `admin-portal live-telemetry`,
`--no-deps`, services named explicitly so `timescaledb` / `grafana` /
`telegraf` are never touched) immediately after `deploy_web_bundle.sh`, and
the recreate is already implied by the new `-app` image tag on every release.

Once the container is running with the mount, the `/app/assets` `StaticFiles`
mount and the `/app/{path}` handler read from disk **per request**, so a
*frontend-only* redeploy that only swaps files under the same
`${EMS_WEB_SPA_PATH}` is picked up without a restart — with the caveat that
`deploy_web_bundle.sh`'s atomic directory swap moves the directory inode, so a
no-restart frontend-only update still needs a `docker compose up -d --no-deps
--force-recreate admin-portal` to re-bind. The pipeline always recreates, so
this only matters for a manual out-of-band bundle swap.

Access is gated exactly as Grafana and the admin portal are today: bound to
`127.0.0.1`, reachable only through the EC2 host or an SSH tunnel. No public
exposure until the platform-wide reverse proxy + TLS + auth review lands
(tracked separately; see `compose.yaml` comments).

---

## Deploy (staging) — wired pipeline

Triggered by advancing `origin/staging` to the Phase 8 commit (fast-forward),
which fires `deploy-staging.yml`:

1. **`ci`** — all existing gates, including `web-frontend` (typecheck / lint /
   58 unit tests / production build).
2. **`build-and-push`** → `ghcr.io/<owner>/<repo>-app:<sha>` (unchanged).
3. **`build-and-push-web`** → `ghcr.io/<owner>/<repo>-web:<sha>`
   (`docker build --file web/Dockerfile ./web`), pushed with the same
   workflow `GITHUB_TOKEN` (`permissions: packages: write`). Runs in parallel
   with `build-and-push`.
4. **`deploy-staging`** (SSH to the staging host):
   - `git fetch` + `git checkout <sha>` (brings the new `compose.yaml` and
     `deploy_web_bundle.sh` onto the host);
   - `WEB_SPA_IMAGE=…-web:<sha> scripts/release/deploy_web_bundle.sh` — pull,
     extract, atomic-swap into `${EMS_WEB_SPA_PATH}`;
   - `scripts/release/deploy_release.sh` — its own `git checkout <sha>`
     (idempotent), `apply_migrations.sh` (**Phase 8 adds no migration → all
     SKIP**), `compose up -d --no-build --no-deps admin-portal live-telemetry`
     → `admin-portal` recreated **with the bind mount → the `/app` hook
     activates**, `health_check.sh`, `.deploy-history/staging.log`.
5. **`verify-staging`** — `post_deploy_verify.sh` (REQUIRED database + metadata
   gates; pipeline/jobs advisory, unchanged from the known baseline).

Post-deploy smoke (manual, over the SSH tunnel):
`GET /app/` returns the shell for an authenticated session; unauthenticated
`GET /app` 303-redirects to `/login`; `/administration/*`, `/static/*`,
`/api/v1/*` and Grafana are unchanged.

---

## Rollback — independent, no database impact

Roll the frontend from `-web:<sha-B>` back to `-web:<sha-A>`:

- **Pipeline:** run `rollback.yml` with `target_environment=staging`,
  `image_tag=<the -app tag currently deployed>`,
  `release_git_sha=<its sha>`, and **`web_image_tag=ghcr.io/<owner>/<repo>-web:<sha-A>`**.
  The workflow runs `deploy_web_bundle.sh` with `sha-A` before
  `deploy_release.sh`, so the `admin-portal` recreate binds the restored
  bundle. Leaving `web_image_tag` blank rolls only the `-app` image and leaves
  the frontend untouched.
- **Manual, on the host:**
  ```
  WEB_SPA_IMAGE=ghcr.io/<owner>/<repo>-web:<sha-A> PROJECT_PATH=<path> \
    scripts/release/deploy_web_bundle.sh
  docker compose -f <path>/compose.yaml up -d --no-build --no-deps --force-recreate admin-portal
  ```
- **Emergency (GHCR unreachable):** `mv ${EMS_WEB_SPA_PATH}.previous
  ${EMS_WEB_SPA_PATH}` and recreate `admin-portal`.

Rollback does **not** require a database rollback, a migration rollback, a
Phase 6 or energy intervention, a Grafana change, or an `-app` image rebuild.
GHCR retains every git-SHA-tagged `-web` image indefinitely, so any past Phase
8 release commit is a valid target. `.deploy-history/<env>-web.log` on the host
records exactly which `-web` image is live.

To remove the shell entirely: point `${EMS_WEB_SPA_PATH}` at an empty
directory (or delete its contents) and recreate `admin-portal`. The `/app`
routes vanish; nothing else changes.

---

## Production promotion — later, same immutable artifact

Not wired in Phase 8 (this change is limited to the staging mechanism), and
**safe by default**: `compose.yaml` is promoted unchanged to production, so a
future production deploy of the Phase 8 `-app` SHA gets the `:ro` mount with an
absent `${EMS_WEB_SPA_PATH}` → empty dir → `/app` hook inert → admin portal
unchanged.

When a production frontend rollout is separately authorized, `deploy-production.yml`
gains the exact mirror of the staging steps:

- resolve `ghcr.io/<owner>/<repo>-web:<release_git_sha>` and pin its digest
  (same `docker buildx imagetools inspect` pattern already used for the `-app`
  image);
- one SSH step running `deploy_web_bundle.sh` with that digest-pinned
  reference before `deploy_release.sh`.

No production-specific build. Production consumes the **identical**
`-web:<sha>` image that passed staging — the same "build once → test → promote
the same artifact" model already used for `-app`.

---

## Impact summary

| Area | Impact |
|---|---|
| `admin-portal` image | **None** — not rebuilt, byte-identical. Gains one `:ro` bind mount + one recreate per deploy (already the norm). |
| `admin-portal` app code | **None** — the `/app` hook already merged in the Phase 8 foundation; no change here. |
| Grafana | **None** — never named by any script; container/image/provisioning untouched. |
| Database / TimescaleDB | **None** — no migration (Phase 8 adds none); the frontend has no DB access; `deploy_web_bundle.sh` never connects to a database. |
| Phase 6 / jobs 1125·1126 / reconciliation | **None**. |
| Energy pipelines / schema / functions / routing | **None**. |
| Phase 7 `/api/v1` contracts | **None** — `GET /api/v1/me` is additive and already reviewed. |
| Ports / network | **None** — no new port; `admin-portal` stays `127.0.0.1:8080`. No new service. |
| Secrets | **None new** — build/push uses the workflow `GITHUB_TOKEN`; host pull reuses `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` (fallback `github.actor` + `GITHUB_TOKEN`). |

---

## Security residuals (`npm audit`)

`react-router-dom` is pinned to the patched **6.30.6**, which clears the
`@remix-run/router` high-severity advisory within the 6.x line (no breaking
bump). `npm audit` then reports:

| Package | Severity | Ships? | Assessment |
|---|---|---|---|
| `vitest` | critical | no | Test runner only. The critical (`@vitest/mocker` UI-server arbitrary file read/exec) requires `vitest --ui`, which is never invoked here or in CI. |
| `@vitest/mocker` | moderate | no | Test runner only (path traversal in the redirect-mock helper). |
| `react-router` / `react-router-dom` | moderate | yes | Residual RR6 open-redirect class ("backslash in `<Link>`", "same-origin `//` redirect"). **No reachable exploit path in this shell:** client-only (no SSR), every navigation target is a hardcoded literal, and the one URL-derived value (`next_path`) is consumed by the existing server `/login`, which already sanitises redirect paths (`safe_login_redirect_path`, `test_portal_redirects.py`). The only fix is a **React Router v7** major upgrade — a tracked follow-up, not a foundation blocker. |
| `vite` / `esbuild` (earlier) | — | no | Cleared by pinning `vite@7.3.6`. Any residual is the dev-server only (`vite dev` on a developer machine), never the static `dist/` served in staging. |

The shipped bundle depends only on `react`, `react-dom`, `react-router-dom`,
`recharts`. The CI `web-frontend` job runs `npm audit --omit=dev` for report
(non-blocking).

### Deferred hardening (not in this change)

- **Source maps.** `web/vite.config.ts` sets `sourcemap: true`; the `-web`
  image therefore ships `.js.map` files. Low risk for an internal,
  access-gated tool. Future: `sourcemap: false` for the published build, or
  upload maps to an error tracker instead of serving them.
- **`Content-Security-Policy` on `/app` responses.** Not part of the current
  deployment/security convention (no service sets a CSP today). Future: add a
  restrictive CSP in the `/app` hook or the eventual front proxy.

---

## Alternative serving models

- **Dedicated container behind admin-portal** — adopted 2026-10-26 as the
  target; see "Dedicated container mode" at the top of this document.
- **Dedicated container behind a front reverse proxy** (route `/app` →
  `ems-web` and everything else → `admin-portal`, with `auth_request` to keep
  the auth gate) — **not chosen**: it moves the public `:8080` binding off
  `admin-portal` and adds a shared ingress component ahead of the planned
  TLS work. Revisit together with that work; the `ems-web` image and
  `deploy_web.sh` would carry over unchanged.
