# ADR-023: Separate the customer EMS application from the staff Administration App

Status: Decided (user, 2026-10-26); stages 1–3 merged and deployed to staging (PRs #157–#161); staging customer endpoint live at `https://16.113.18.69/` since 2026-10-27 (interim IP address, Let's Encrypt IP certificate); the rest of stage 4 (staff-only Administration App, closing `:8080` / `:3000`) and stage 5 not started. Amendment 1 (server-side session revocation, migration 314) deployed to staging 2026-10-28 (PRs #163 + #164, `9b3e85d`; customer-api on the same SHA) and verified (runbook §7).
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
| 1 | Edge proxy definition (`edge`, profile-gated, not started) | On staging, not started |
| 2 | `customer-api`, customer auth, migration 313, staff-only switch (off), deploy script | On staging: 313 applied; customer-api running since 2026-10-26 (`deploy-customer-api.yml`, PR #158) |
| 3 | Frontend sign-in page (`/app/sign-in`, falls back to `/login` on the admin path) and `/auth` client; `GET /auth/session` probe; live-telemetry accepts the customer session (own secret, customer audience, same-origin WebSocket) | On staging (PR #159, 2026-10-26). Reports worker stays in admin-portal until stage 4 |
| 4 | Activate routing (DNS, TLS, security group), `EMS_ADMIN_STAFF_ONLY=true`, remove `/app` and `/api/v1` from admin-portal, close `:8080` / `:3000` | Partly: edge serving the customer host on staging since 2026-10-27 (interim `https://16.113.18.69/`, PRs #160–#161); staff-only switch and port closure not started — approval per step |
| 5 | Production | Not started — separate approval (release plan D6) |

## Alternatives considered

- **Keep `/api/v1` in admin-portal, put only a proxy in front** — rejected: customer requests would still pass through the Administration App.
- **A second identity store for customers** — rejected: duplicates accounts, lockout and scope administration; the access-scope model already distinguishes staff from customers.
- **Reuse `ems_app` for the customer API** — rejected: about 159 grants including administration writes.
- **AWS ALB + ACM instead of Caddy** — viable; Caddy chosen for no extra AWS dependency and automatic certificates. The routing is the same either way (switch `remote_ip` to `client_ip` + `trusted_proxies` behind a load balancer).

## Consequences

- The EMS frontend bundle is public on the customer host (all data still requires a customer session); previously `/app` itself required a session.
- Until stage 3 is deployed (and live-telemetry has the customer session secret), the frontend would send customers to `/login`, which does not exist on the customer host — routing must not be activated before then.
- Two processes serve `/api/v1` during the transition; they share code, and parity is tested.
- Customer sessions are revocable server-side (Amendment 1, migration 314): sign-out, deactivation and a password change end a session everywhere. Administration App sessions are still signed cookies only (unchanged; data access stops immediately for a deactivated user because the database checks `is_active`).

## Amendment 1 (2026-10-28): server-side revocation of customer sessions

**Context.** A customer session was only a signed cookie. `POST /auth/logout` cleared it in the browser, but a copy taken before sign-out (shared computer, proxy log, malware) stayed valid until `EMS_APP_SESSION_MAX_AGE_SECONDS` -- and Starlette re-signs the cookie on every response, so an active copy never expired. live-telemetry checked only the signature, and an open live WebSocket was never closed. A deactivated account lost data access (the database checks `is_active`) but kept its session and sockets, and re-activation would have revived old cookies.

**Decision.**

1. **A server-side session per sign-in** (`admin.portal_sessions`, migration 314). At sign-in the customer API generates a random 256-bit token, keeps it inside the signed `HttpOnly` cookie and stores only its SHA-256 in the database. The signed cookie alone is no longer sufficient.
2. **Checked on every authenticated request** (`admin.touch_portal_session`, from `CustomerAuthenticationMiddleware`): the session must exist, be unrevoked, be within its idle expiry (`EMS_APP_SESSION_MAX_AGE_SECONDS`, sliding, written at most once a minute) and its absolute expiry (`EMS_CUSTOMER_SESSION_ABSOLUTE_MAX_AGE_SECONDS`, default 7 days), belong to the identity in the cookie, and the account must be active. Otherwise the request is signed out (401). If the database cannot be reached, the request fails closed with 503 and the browser session is kept.
3. **Sign-out revokes** (`admin.revoke_portal_session`). `/auth/logout` is idempotent and does not depend on the session check, so it always clears the browser, even during a database outage (it then answers 503 and the server-side row expires on its own).
4. **Deactivation and password change revoke every session** of the account (trigger `portal_users_revoke_sessions` on `admin.portal_users`), whichever code path makes the change; re-activation does not revive them.
5. **live-telemetry** checks a customer session read-only (`admin.get_portal_session_user`, `ems_app`) at the WebSocket handshake and on the HTTP snapshot, and each open customer WebSocket re-checks every `EMS_CUSTOMER_SESSION_RECHECK_SECONDS` (default 30) and is closed with 4401 (the frontend stops reconnecting and asks for sign-in) once the session is signed out, expired or deactivated. A database error closes it with 1011 (the frontend reconnects with backoff). Administration App streams are unchanged.

**Consequences.**

- Revocation is immediate on the customer API and within `EMS_CUSTOMER_SESSION_RECHECK_SECONDS` on an already-open live stream; between those re-checks a revoked stream may still receive telemetry pushes for the assets it was authorised for.
- Every customer request does one indexed primary-key lookup (and at most one small update per session per minute); every open customer stream one lookup per re-check interval. Sign-in, every customer request and live-stream checks depend on the database -- as all data reads already do.
- Cookies issued before migration 314 carry no token: deploying signs every customer out once.
- Rows stay small (one per sign-in); a user's revoked and expired rows are removed at that user's next sign-in. There is no scheduled purge.
- Several concurrent sessions per account are allowed (one per device); sign-out ends only the current one. There is no "sign out everywhere" endpoint yet (a password change or deactivation does that).
- Migration 314 is staging/test only, like 313.

### Residual authentication risks (recorded 2026-10-29; not changed by Amendment 1)

| # | Limitation | Exposure | Recommended separate change (each needs its own approval) |
|---|---|---|---|
| R1 | An open customer live WebSocket is re-checked every `EMS_CUSTOMER_SESSION_RECHECK_SECONDS` (default 30, allowed 1–300), so after sign-out, password change or deactivation it can keep receiving telemetry pushes for up to that long. Measured on staging: closed 4401 after 30.0 s. Customer API requests are refused at once. | Read-only telemetry for assets the session was already authorised for; no writes, no new scope. | (a) Lower the interval (e.g. 10 s; one indexed lookup per stream per interval -- check the load at the expected stream count first), and/or (b) push revocation: `pg_notify` from `revoke_portal_session` and the `portal_users_revoke_sessions` trigger, with live-telemetry closing matching streams immediately and keeping the timed re-check as the fallback. |
| R2 | Administration App sessions are Starlette signed cookies only (`SessionMiddleware`, sliding `EMS_APP_SESSION_MAX_AGE_SECONDS`, default 8 h): no server-side record, so sign-out only clears the browser and a copied cookie stays valid while it is used. Data access stops at once for a deactivated user (the database checks `is_active`). | Staff/administrative sessions -- higher privilege than customer sessions -- and the Administration App is currently reachable from the internet on `:8080` (stage 4 not done). | Apply the Amendment 1 pattern to the Administration App (`admin.portal_sessions` with an audience column, or a sibling table; check on every request; revoke on sign-out/deactivation/password change). Independently, finish stage 4 (staff host IP-restricted), which shrinks who can present a copied cookie. Rotating the Administration App session secret is the only bulk invalidation available today. |
| R3 | No "sign out of all devices" for a customer: sign-out ends only the current session; ending every session needs a password change or deactivation (Administration App). | A user who suspects a lost device cannot end other sessions themselves without changing the password. | `POST /auth/logout-all` on the customer API revoking every unrevoked row of the account (same function family, audited), plus a UI control; optionally a staff action for the same in the Administration App. |

These are recorded, not accepted indefinitely: each is a scoped follow-up, independent of the network-exposure decisions (both endpoints stay publicly reachable for now by user decision, 2026-10-29).

## Implementation references

`app/src/customer_main.py`, `customer_config.py`, `routers/customer_auth.py`, `auth/customer_middleware.py`, `auth/customer_session.py`, `auth/server_session.py`, `auth/audience.py`, `live_main.py`, `live_config.py`, `api_errors.py`, `config.py` (`CoreSettings`), `postgres/migrations/313_customer_api_role.sql`, `314_customer_session_revocation.sql`, `edge/Caddyfile`, `compose.yaml` (`customer-api`, `edge`), `scripts/release/deploy_customer_api.sh`.

## Validation references

`app/tests/test_customer_api.py`, `test_customer_api_role_db.py`, `test_customer_session_revocation_db.py`, `test_live_customer_session.py`, `test_staff_only_admin.py`, `test_customer_separation_release_contract.py`; local end-to-end harness (edge TLS → customer-api → real Argon2 sign-in and database scoping through `ems_customer_api`), 53/53, 2026-10-26.
