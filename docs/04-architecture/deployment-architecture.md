# Deployment Architecture

Status: PARTIAL · Last reviewed: 2026-10-26 · Owner: Architecture
Source of truth: platform manual chapters 03 & 04 (archived), consolidated here. Process detail: [../09-release-and-deployment/](../09-release-and-deployment/).

## Topology

A single Docker Compose stack (`compose.yaml`, project name
`ems-platform-prod`), used unchanged for both staging and production. Five
running services: `timescaledb`, `telegraf`, `grafana`, `live-telemetry`,
`admin-portal`. `admin-portal` and `live-telemetry` are two `command:`
variants of the same built application image (`app/Dockerfile`) — see
[../06-platform/README.md](../06-platform/README.md). A sixth service,
`ems-web` (the EMS Web App's own nginx container, see below), is defined in
`compose.yaml` on the `feature/ems-web-container` branch — **implemented,
not merged, not deployed** anywhere as of 2026-10-26.

**Host topology** (read-only SSH inspection, 2026-10-26): staging and
production are each a single AWS EC2 host in `ap-south-2`, project checkout
at `/opt/ems-platform`, one compose bridge network
(`ems-platform-prod_default`). Staging ran `-app:a32921a`, production
`-app:7e3da57` (digest-pinned). Both hosts: ~1.9 GB RAM.

## Networking / exposure

All five services default to `127.0.0.1`-only binding
(`GRAFANA_BIND_HOST`/`ADMIN_PORTAL_BIND_HOST` overridable via an untracked
root `.env`). **Verified 2026-10-26: both staging and production override
this** — their root `.env` sets `ADMIN_PORTAL_BIND_HOST=0.0.0.0` and
`GRAFANA_BIND_HOST=0.0.0.0`, so `admin-portal` (`:8080`) and `grafana`
(`:3000`) listen on all interfaces over **plain HTTP**; whether the EC2
security group restricts them was not inspected. Both hosts set
`EMS_APP_SESSION_HTTPS_ONLY=false` (the code default is `true`), so the
`ems_admin_session` cookie is not `Secure`. **Reverse proxy / public TLS is
still not implemented** — verified: no nginx/caddy/traefik/haproxy/apache
service, no `:443` listener, no `/etc/letsencrypt` on either host;
`compose.yaml`'s own comment: "Caddy and public TLS exposure will be
configured only after authentication and tenant isolation have been
validated."

## Independent EMS Web Application deployment

The EMS Web Application is treated as an **independently deployable
application** — releasable and rollbackable without changing the
Administration App, Grafana, the database, or the energy subsystem (see
[ADR-006](../00-governance/decisions/ADR-006-ems-web-app-vs-admin-portal.md)).
Current (deployed) staging delivery mechanism: an independently versioned
`ghcr.io/<repo>-web:<sha>` artifact carrying only the static bundle,
extracted read-only into the admin-portal container at `/app/src/spa` and
served same-origin under `/app` by the existing FastAPI hook. Production
serves **no** frontend (its `web-spa` directory is empty, `/app` inert —
verified 2026-10-26; production stays API-only per release plan D6).

**Dedicated container (approved 2026-10-26 as "Option A"; implemented on
`feature/ems-web-container`, not merged, not deployed):** the same `-web`
image runs as its own `ems-web` compose service (nginx, no host port,
read-only root filesystem). When a host's root `.env` sets
`EMS_WEB_UPSTREAM=http://ems-web:80`, `admin-portal` proxies `/app/*` to it
**after** its existing authentication/authorization middleware — same
origin, same URL, same `ems_admin_session` cookie, no CORS, no new public
port, no new ingress component. GET/HEAD only; no cookie or credential is
forwarded to `ems-web`. Web-only deploy and rollback
(`scripts/release/deploy_web.sh`, `.github/workflows/deploy-web.yml`)
recreate **only** `ems-web`. With `EMS_WEB_UPSTREAM` unset the bind-mounted
bundle hook applies exactly as before and is the rollback fallback.
Trade-off: `/app` traffic still traverses `admin-portal` at runtime (it is
the auth gate and the origin). A front reverse proxy (Option B) was
deliberately not chosen: it would move the public port binding and add a
shared ingress before the planned TLS work. See
[../05-applications/ems-web/README.md](../05-applications/ems-web/README.md)
and [../operations/PHASE8_FRONTEND_DEPLOYMENT.md](../operations/PHASE8_FRONTEND_DEPLOYMENT.md).

## What is unknown

Instance type; EC2 security-group / network-ACL rules (whether `:8080` and
`:3000` are reachable from the internet); whether any AWS-side load balancer
or TLS termination sits in front of the hosts (none exists on the hosts
themselves — verified 2026-10-26).
