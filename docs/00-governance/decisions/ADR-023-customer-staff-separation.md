# ADR-023: Separate the customer EMS application from the staff Administration App

Status: Decided (user, 2026-10-26); stages 1–2 implemented on `feature/customer-api-separation`, not merged, not deployed; stages 3–5 not started.
Date: 2026-10-26
Decision owners: Product Owner; Architecture
Related decisions: [ADR-006](ADR-006-ems-web-app-vs-admin-portal.md) (Amendment 1: dedicated `ems-web` container — the intermediate step this ADR completes), [ADR-007](ADR-007-analytics-api-boundary.md)
Runbook: [../../10-operations/customer-staff-separation-runbook.md](../../10-operations/customer-staff-separation-runbook.md)

## Context

After ADR-006 Amendment 1, the EMS frontend runs in its own `ems-web` container, but every customer request still passes through the Administration App (`admin-portal`): `/app` is proxied by it, `/api/v1/*` is served by it, sign-in is its server-rendered `/login`, and the live-data WebSocket is proxied by it. Both hosts serve plain HTTP on `:8080` with no TLS or reverse proxy, and any active portal user — customers included — can sign in to the Administration App (read-only investigation, 2026-10-26).

## Decision

1. **Two hostnames, one edge.** A Caddy edge proxy (`edge` service, `edge/Caddyfile`) terminates HTTPS for a customer hostname and a staff hostname. The customer host routes only `/app*` → `ems-web`, `/api/v1/*` and `/auth/*` → `customer-api`, `/api/live/*` → `live-telemetry`, `/` → `/app/`, and answers everything else 404. The staff host is restricted to an IP allowlist and routes to `admin-portal`.
2. **A dedicated customer API.** `customer-api` (`src.customer_main`, same artifact as admin-portal, different entrypoint) serves `/api/v1` with the *same* routers, services and database functions (no duplicated logic or data), plus JSON sign-in/sign-out (`/auth/login`, `/auth/logout`). It holds no administration, Grafana or MQTT configuration.
3. **Separate sessions.** The customer API uses its own cookie (`ems_session`) and its own signing secret; the cookie is host-only, `HttpOnly`, `SameSite=Lax`, `Secure` behind TLS. Neither host can verify the other's cookie.
4. **Same identities, explicit audiences.** `admin.portal_users` stays the single identity store. GLOBAL-scope identities are WiseWatts staff; ORGANIZATION / SELECTED_SITES identities are customers. The customer host accepts customers (staff only if `EMS_CUSTOMER_ALLOW_STAFF`); the Administration App accepts staff only when `EMS_ADMIN_STAFF_ONLY` is on. An identity outside the audience gets the same generic sign-in failure, and nothing is recorded against the account.
5. **Least-privilege database role.** `ems_customer_api` (migration 313): `USAGE` on `admin`, `analytics` and `EXECUTE` on exactly the 44 customer-facing `SECURITY DEFINER` functions; no table access. Tenant isolation remains in the database (`admin.portal_user_can_access_site` on every read, `is_active` required).
6. **CSRF.** Every state-changing request to the customer API must carry an `Origin` equal to its own host.
7. **Independent deploy/rollback** of `ems-web` (`deploy_web.sh`) and `customer-api` (`deploy_customer_api.sh`); neither touches `admin-portal`.

## Stages

| Stage | Content | Status |
|---|---|---|
| 1 | Edge proxy definition (`edge`, profile-gated, not started) | Implemented, not deployed |
| 2 | `customer-api`, customer auth, migration 313, staff-only switch (off), deploy script | Implemented, not deployed |
| 3 | Frontend sign-in page and `/auth` client; live-telemetry accepts the customer session; Reports worker to customer-api | Not started |
| 4 | Activate routing (DNS, TLS, security group), `EMS_ADMIN_STAFF_ONLY=true`, remove `/app` and `/api/v1` from admin-portal, close `:8080` / `:3000` | Not started — approval per step |
| 5 | Production | Not started — separate approval (release plan D6) |

## Alternatives considered

- **Keep `/api/v1` in admin-portal, put only a proxy in front** — rejected: customer requests would still pass through the Administration App.
- **A second identity store for customers** — rejected: duplicates accounts, lockout and scope administration; the access-scope model already distinguishes staff from customers.
- **Reuse `ems_app` for the customer API** — rejected: about 159 grants including administration writes.
- **AWS ALB + ACM instead of Caddy** — viable; Caddy chosen for no extra AWS dependency and automatic certificates. The routing is the same either way (switch `remote_ip` to `client_ip` + `trusted_proxies` behind a load balancer).

## Consequences

- The EMS frontend bundle is public on the customer host (all data still requires a customer session); previously `/app` itself required a session.
- Until stage 3, the frontend still sends unauthenticated users to `/login`, which does not exist on the customer host — routing must not be activated before stage 3.
- Two processes serve `/api/v1` during the transition; they share code, and parity is tested.
- Session revocation is unchanged (signed cookies, up to `EMS_APP_SESSION_MAX_AGE_SECONDS`); data access stops immediately for a deactivated user because the database checks `is_active`.

## Implementation references

`app/src/customer_main.py`, `customer_config.py`, `routers/customer_auth.py`, `auth/customer_middleware.py`, `auth/audience.py`, `api_errors.py`, `config.py` (`CoreSettings`), `postgres/migrations/313_customer_api_role.sql`, `edge/Caddyfile`, `compose.yaml` (`customer-api`, `edge`), `scripts/release/deploy_customer_api.sh`.

## Validation references

`app/tests/test_customer_api.py`, `test_customer_api_role_db.py`, `test_staff_only_admin.py`, `test_customer_separation_release_contract.py`; local end-to-end harness (edge TLS → customer-api → real Argon2 sign-in and database scoping through `ems_customer_api`), 53/53, 2026-10-26.
