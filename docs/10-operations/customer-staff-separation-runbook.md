# Customer / staff separation — operator runbook (ADR-023)

Status: CURRENT · Last reviewed: 2026-10-26 · Owner: Engineering
Decision: [ADR-023](../00-governance/decisions/ADR-023-customer-staff-separation.md)

Everything below that changes an environment is a **separately approved step**. Nothing here has been executed on staging or production. Production is out of scope until explicitly approved (release plan D6).

## 1. What already exists after the stage 1–2 merge (no effect until activated)

| Item | State after merge to `staging` |
|---|---|
| Migration 313 (`ems_customer_api`, NOLOGIN, function grants only) | Applied by the normal staging deploy (staging/test scope only; production never applies it) |
| `customer-api` service | Defined (profile `customer`), **not started** |
| `edge` service | Defined (profile `edge`), **not started**, publishes nothing |
| `EMS_ADMIN_STAFF_ONLY` | Off — the Administration App behaves exactly as before |
| `/api/v1/me`, `/api/v1/*` on admin-portal | Unchanged |

## 2. Decisions and inputs needed before activation

| Input | Needed for | Default in code |
|---|---|---|
| Customer hostname per environment, e.g. `app-staging.<domain>`, `app.<domain>` | DNS, TLS, `EMS_CUSTOMER_HOST` | `customer.invalid` (unreachable) |
| Staff hostname, e.g. `admin-staging.<domain>`, `admin.<domain>` | DNS, TLS, `EMS_STAFF_HOST` | `staff.invalid` |
| TLS: Caddy + Let's Encrypt (recommended) or AWS ALB + ACM | `EMS_EDGE_TLS` (ACME account e-mail) | `internal` (Caddy's own CA; browsers warn) |
| Staff access restriction: office/VPN CIDRs | `EMS_STAFF_ALLOWED_CIDRS` | `127.0.0.1/32` (nobody) |
| May staff sign in to the customer app? | `EMS_CUSTOMER_ALLOW_STAFF` | `false` |
| Test customer account(s) on staging | stage 3 validation | none exist on staging today |

## 3. Staging activation steps (each requires explicit approval)

**A. External (owner: you / AWS account owner)**
1. DNS `A` records for the customer and staff hostnames → the staging Elastic IP.
2. Security group: allow inbound TCP 80 and 443 (Let's Encrypt HTTP-01 needs 80). Keep 22 as is.

**B. Database role login** (one-time, staging):
```
docker exec -i ems-timescaledb psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "ALTER ROLE ems_customer_api LOGIN PASSWORD '<new secret from the secret store>'"
```
Rollback: `ALTER ROLE ems_customer_api NOLOGIN PASSWORD NULL`.

**C. Customer API configuration**: create `/opt/ems-platform/app/customer-api.env` from `app/customer-api.env.example` (mode 640, owner as `app/.env`): the role password from B, a **new** session secret (≥ 32 characters, different from `app/.env`), `EMS_APP_SESSION_HTTPS_ONLY=true`, `EMS_APP_ENV=staging`, `EMS_REPORTS_ENABLED=true` (staging has Reports), `EMS_REPORT_EXPORT_WORKER_ENABLED=false`.

**D. Start the customer API** (internal only; no public effect):
```
EMS_CUSTOMER_API_IMAGE=ghcr.io/<owner>/<repo>-app:<sha>@sha256:<digest> \
PROJECT_PATH=/opt/ems-platform ENVIRONMENT_NAME=staging \
  /opt/ems-platform/scripts/release/deploy_customer_api.sh
```
Verify: `docker inspect ems-customer-api` healthy; its `/health` reports database user `ems_customer_api`.

**E. Stage 3** (frontend sign-in page `/app/sign-in`; live-telemetry accepts the customer session) must be merged and deployed first. Then, as one approved step, give live-telemetry the customer session secret and recreate only it (live updates blip for a few seconds; the admin path keeps working):
```
# on the host: copy the customer API's session secret, never print it
sed -n 's/^EMS_APP_SESSION_SECRET=/EMS_CUSTOMER_SESSION_SECRET=/p' app/customer-api.env >> app/live-telemetry.env
APP_IMAGE=<running live-telemetry image> docker compose -f /opt/ems-platform/compose.yaml up -d --no-build --no-deps --force-recreate live-telemetry
```
Rollback: remove the `EMS_CUSTOMER_SESSION_SECRET` line and recreate live-telemetry the same way. Do not activate the edge before E.

**F. Edge proxy** — root `.env`: `EMS_CUSTOMER_HOST`, `EMS_STAFF_HOST`, `EMS_STAFF_ALLOWED_CIDRS`, `EMS_EDGE_TLS=<acme e-mail>`; then
```
docker compose -f /opt/ems-platform/compose.yaml --profile edge up -d --no-build --no-deps edge
```
This publishes ports 80/443 — **the externally visible step**. Verify per section 4. Rollback: `docker compose -f /opt/ems-platform/compose.yaml --profile edge stop edge` (the old `:8080` path keeps working throughout).

**G. Lock down** (after customers are on the customer host): `EMS_ADMIN_STAFF_ONLY=true` in `app/.env` and recreate admin-portal with `APP_IMAGE` pinned to its running image (the root `.env` has no `APP_IMAGE`; a bare `docker compose up` would resolve `ems-platform-prod-app:local`):
```
APP_IMAGE=<running admin-portal image> docker compose -f /opt/ems-platform/compose.yaml up -d --no-build --no-deps --force-recreate admin-portal
```
then bind `ADMIN_PORTAL_BIND_HOST` / `GRAFANA_BIND_HOST` back to `127.0.0.1` (separate approval; staff then reach admin-portal only via the staff host / SSH tunnel).

## 4. Verification checklist (staging)

- `https://<customer host>/` → 302 `/app/`; `/app/`, deep links and hashed assets 200; HSTS present; no `Server` header.
- `/login`, `/administration/*`, `/onboarding/*`, `/docs`, `/openapi.json`, `/health` on the customer host → 404.
- Customer sign-in sets `ems_session` (`Secure`, `HttpOnly`, `SameSite=Lax`, no `Domain`); `/api/v1/sites` returns only the account's sites; cross-tenant site → 404; sign-out → subsequent 401.
- Cross-origin `POST /auth/login` → 403.
- Staff host from outside the allowlist → 403; from inside → admin `/login`.
- admin-portal access log shows no `/api/v1` or `/auth` request originating from the customer host.
- `deploy_customer_api.sh` roll-forward/rollback leaves admin-portal, ems-web and edge start time / image / restart count unchanged.
- Energy pipelines: job failures unchanged, freshest raw message < 1 min.

## 5. Rollback summary

| Change | Rollback |
|---|---|
| Edge started | Stop `edge`; customers/staff fall back to `:8080` |
| customer-api started | `docker compose --profile customer stop customer-api` |
| Role login enabled | `ALTER ROLE ems_customer_api NOLOGIN PASSWORD NULL` |
| `EMS_ADMIN_STAFF_ONLY=true` | Remove it, recreate admin-portal (pinned `APP_IMAGE`) |
| Migration 313 | `REVOKE ... FROM ems_customer_api; DROP ROLE ems_customer_api;` (only after customer-api is stopped) |

## 6. Known residuals

- `admin.list_accessible_asset_device_relationships` is `SECURITY DEFINER` and executable by `PUBLIC` (noted in migration 308); every role, including `ems_customer_api`, can call it. It is portal-scoped. Hardening it is a separate change.
- Login lockout counters are shared by both hosts (one identity store).
- Before any production rollout, verify the production Docker Compose version supports `env_file: required: false` (staging: v5.5.1).
