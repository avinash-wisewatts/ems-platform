# ADR-023: Separate the customer EMS application from the staff Administration App

Status: Decided (user, 2026-10-26); stages 1–3 merged and deployed to staging (PRs #157–#161); staging customer endpoint live at `https://16.113.18.69/` since 2026-10-27 (interim IP address, Let's Encrypt IP certificate); the rest of stage 4 (staff-only Administration App, closing `:8080` / `:3000`) and stage 5 not started. Amendment 1 (server-side session revocation, migration 314) deployed to staging 2026-10-28 (PRs #163 + #164, `9b3e85d`; customer-api on the same SHA) and verified (runbook §7). Amendment 2 (EMS Web App Admin → Users, migration 315) merged and on staging (#171, 2026-11-04). Amendment 3 (staff on the customer host; the Administration App is the only user-management UI; admin-portal serves no `/app` on staging; migration 319) decided by the user 2026-11-04 — see below for its state.
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
| 4 | Activate routing (DNS, TLS, security group), `EMS_ADMIN_STAFF_ONLY=true`, remove `/app` and `/api/v1` from admin-portal, close `:8080` / `:3000` | Partly: edge serving the customer host on staging since 2026-10-27 (interim `https://16.113.18.69/`, PRs #160–#161); `/app` removed from admin-portal on staging (Amendment 3, dedicated-container mode only); `/api/v1` removal, staff hostname, staff-only switch and port closure not started — approval per step |
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

## Amendment 2 (2026-11-03): Admin → Users in the EMS Web App is served by the Administration App only

Status: implemented on branch `feature/web-admin-users` (migration 315), not merged, not deployed.

**Context.** The EMS Web App needed an Admin → Users section equivalent to the Administration App's Users pages, using the same identities, roles and audit, with no second user model or authentication. The customer API (this ADR, decision 2/5) holds no administration and its database role has no administration grants; the Analytics API is read-only (ADR-007).

**Decision.**

1. **One user-management implementation, exposed as JSON by the Administration App only.** `src.routers.user_management_api` (`/api/admin/v1/users…`, `/api/admin/v1/me/password`) is mounted in `src.main`, authenticated by `ems_admin_session` and gated on `user.manage` by `PortalAuthenticationMiddleware`; it calls the same controlled functions as the server-rendered `/administration/users` pages (`admin.*_managed_portal_user*`). It is never mounted in `customer-api`, never under `/api/v1`, and the edge's customer host does not route `/api/admin/*` (404).
2. **Visibility follows availability.** `GET /api/v1/me` advertises `user.manage` only in a process that mounts the router (as it already does for `report.export`), so on the customer host the SPA shows no Admin section; the role grant is unchanged.
3. **Database-enforced rules (migration 315).**
   - No actor may change their own role, access scope or status, or reset their own password.
   - An access-scope change requires the target to be inside the actor's current scope. This closes the cross-tenant move by an ORGANIZATION administrator.
   - Every actor/target function locks both user rows, in id order, before the scope check. A concurrent change therefore cannot slip between check and update, and two administrators acting on each other cannot deadlock.
   - Another ADMIN's password can be reset only by a WiseWatts staff (active GLOBAL) administrator. A tenant administrator cannot take over a peer administrator's account.
   - New audited functions:
     - details edit (`USER_DETAILS_CHANGED`);
     - administrator password reset (`USER_PASSWORD_RESET`; Argon2id only; clears the lockout);
     - own-password change after the current password is verified (`USER_PASSWORD_CHANGED`).
   - No password or hash is written to the audit trail.
   - EXECUTE `ems_app` only — never `ems_customer_api` or PUBLIC.

   **Own password, every role.** `POST /api/admin/v1/me/password` is open to every signed-in role (`dashboard.view`), not only `user.manage`:
   - It changes only the caller's own password.
   - It requires the current password; a wrong one counts towards the sign-in lockout.
   - It is refused while the account is locked, before the password is checked.
   - The EMS Web App offers it at `/account/password` (user menu → Change password) on the Administration App path only, never on the customer host.
4. **CSRF.** State-changing `/api/admin/v1` requests require an `Origin` naming the host and a JSON body.
5. **Initial administrator.** `python -m src.provision_portal_admin` creates an ADMIN / GLOBAL account through `admin.create_managed_portal_user` on behalf of an existing active GLOBAL administrator (audited), never modifies an existing account, and hands a generated password over once (new owner-only file or interactive terminal). Runbook: [../../10-operations/portal-user-provisioning.md](../../10-operations/portal-user-provisioning.md).

**Production scope of migration 315 (2026-11-04).** 315 is production-scoped (removed from `postgres/migration_environment_scope.csv`). Its database rules close a cross-tenant scope move that exists on production today, independently of the EMS Web App screen. The read-only exposure check of 2026-11-03 found no ORGANIZATION or SELECTED_SITES ADMIN on production and no such change in the audit trail. No tenant-level ADMIN may be created there before 315 is applied. **Production privilege exposure (2026-11-04, read-only):** production's `ems_readonly` login role holds bulk pre-baseline EXECUTE grants (98 of 110 `admin.*` functions, almost all SECURITY DEFINER) and SELECT on `admin.portal_users` including `password_hash`; staging has none. Migration 316 (production-scoped, after 315) revokes its EXECUTE on the 14 portal-user management and authentication functions; migration 317 revokes every other explicit `admin` function grant and all access to `admin.portal_users` (incl. `password_hash`), keeping its SELECT on analytics, telemetry, metadata, config and the other `admin` relations. Migration 318 revokes its EXECUTE on the ten write-capable SECURITY DEFINER routines outside `admin` (energy / environment tier refreshes, live ingest, three trigger functions), with a precheck that stops on any other such routine. Still open (inventory 2026-11-04): its SELECT on onboarding draft / audit payloads and contact details; a narrowly scoped change (column-level) needs evidence of operational use first (assessment in [../../09-release-and-deployment/production-release-311-315-to-318.md](../../09-release-and-deployment/production-release-311-315-to-318.md)).

**Consequences.**

- Admin → Users works where the EMS Web App is served **through the Administration App** (`/app` on the staff path, `ems_admin_session`). Stage 4 of this ADR removes `/app` and `/api/v1` from admin-portal; before that step, a decision is needed on where staff reach Admin → Users afterwards (e.g. keep `/app` on the staff host, or move tenant-administrator user management to the customer API with its own reviewed grants). **Resolved by Amendment 3 (2026-11-04):** the Administration App's own `/administration/users` pages are the user-management UI; the web screen is not offered on the customer host.
- With `EMS_ADMIN_STAFF_ONLY` on, only GLOBAL (staff) administrators can use it; tenant (ORGANIZATION / SELECTED_SITES) administrators manage their users only while that switch is off. The database rules hold either way.
- The Administration App's existing Users pages inherit the self-protection and the scope-containment fix (same functions).
- No forced password change at first sign-in (not supported by the portal); the provisioned temporary password is changed through Admin → Users → own account → Change my password. Administration App sessions remain signed cookies carrying the identity, role and scope captured at sign-in (residual risk R2). Deactivation stops database-checked data access at once (the database checks `is_active`) but does not end the session; a **password reset does not end or restrict an already-open session at all**; a role or scope change applies at once to database-enforced checks (including every user-management function) but in-app permission gates use the sign-in role until the session ends. Follow-up: issue #172 (server-side Administration App session revocation).

## Amendment 3 (2026-11-04): staff on the customer host; user management only in the Administration App; no `/app` on admin-portal (staging)

Status: decided by the user 2026-11-04 (staging only).
- Item 1 is applied on staging: `EMS_CUSTOMER_ALLOW_STAFF=true` for `customer-api` and `live-telemetry`, both recreated on their existing images, 2026-11-04 15:15 UTC.
- Items 2–5 are implemented on branch `feat/admin-app-user-management-complete` (migration 319) and reach staging through the normal pipeline once merged.

Production is unchanged: it has no edge, customer API or `ems-web` container, sets none of these switches, and keeps serving `/app` from the bind-mounted bundle.

**Context.** The user wants the EMS Web App reached only at the customer host (`https://16.113.18.69/app/`), not at `:8080/app`, and wants to use it as a WiseWatts staff administrator (GLOBAL ADMIN). Amendment 2's open question — where staff manage users once `/app` leaves admin-portal — has to be answered first. The customer host deliberately answers `/api/admin/*` with 404, so the EMS Web App's Admin → Users screen cannot work there, and routing admin calls through the customer host would undo decision 1.

**Decision.**

1. **Staff may use the customer web app on staging.**
   - `EMS_CUSTOMER_ALLOW_STAFF=true` is set for `customer-api` and `live-telemetry`. Both must agree, or live data would be refused.
   - Staff are **read-only** there by construction:
     - `ems_customer_api` has no table writes and no user-management EXECUTE (verified on staging 2026-11-04: 0 / 0);
     - `/api/v1/me` advertises no `user.manage`, so the SPA shows no Admin section;
     - every administration path on the customer host is 404.
   - Data access is still derived in the database per request: a GLOBAL identity sees what `admin.portal_user_can_access_site` allows it.
2. **The Administration App is the only user-management UI.** `/administration/users` gains everything the EMS Web App screen had:
   - **List** with search and role, status and organization filters (the organization filter is for staff only).
   - **Details:** identity, organization and site names, and audit history.
   - **Create**, using the shared account policy (`src.user_account_policy`). The initial password is generated and shown once, or chosen and policy-checked.
   - **Edit** display name and e-mail.
   - **Role, scope and status** changes (existing pages).
   - **Administrator password reset:** generated or chosen; never one's own; another ADMIN only by staff; clears the lockout.
   - **Change my password** for every signed-in role, at `/administration/account/password`. It runs through the same `src.own_password` helper as `POST /api/admin/v1/me/password`: current password required, refused while locked, failures counted.

   Rules shared by these pages:
   - Every page uses the same controlled database functions as the JSON API.
   - The pages need `user.manage` for reads as well as writes. Before this, GETs needed only `dashboard.view`, and the database refused instead.
   - Cross-origin form posts are refused (`Origin` check, in addition to the `SameSite=Lax` cookie).
   - Temporary passwords are only ever in a `no-store` response.
3. **Audit history through one controlled function (migration 319).** `admin.list_manageable_portal_user_audit(actor, target, limit)`:
   - **Function properties:** SECURITY DEFINER, STABLE, pinned `search_path`, owner `ems_admin`, EXECUTE `ems_app` only. `ems_app` still has no SELECT on `admin.portal_user_audit`.
   - **Access:** an active ADMIN is required, and the target must be inside the actor's scope.
   - **Tenant isolation:** tenant administrators see only their own organization's rows, without organization or site ids (a user may have been moved between organizations by staff). An actor is named only if the caller may see that actor. Payloads are redacted.
   - **Production:** 319 is production-applicable, so the next production release declares 311 and 315–319.
4. **admin-portal serves no `/app` in dedicated-container mode.**
   - With `EMS_WEB_UPSTREAM` set (staging), the `/app` forwarding to `ems-web` is removed.
   - `/app` and `/app/*` are a plain 404 before authentication. There is no `/login` redirect and no bundle fallback, and sign-in never returns to `/app`.
   - Without `EMS_WEB_UPSTREAM` (production) the bind-mounted bundle is served exactly as before.
   - The JSON user-management API stays mounted in admin-portal, so production's bundle and an emergency fallback (unset `EMS_WEB_UPSTREAM`) keep working.
5. **Not part of this amendment:**
   - closing `:8080`;
   - the staff hostname;
   - `EMS_ADMIN_STAFF_ONLY`;
   - removing `/api/v1` from admin-portal;
   - any production change.

   Each of these remains a separate stage-4 or stage-5 approval.

**Consequences.**

- **Staff use two entry points on staging:**
  - `https://16.113.18.69/app/` for the customer application (read-only);
  - `http://16.113.18.69:8080/administration/users` for user management and other administration.
- **The sessions are independent:**
  - two cookies, two sign-ins;
  - signing out of one does not end the other;
  - a password change or reset revokes customer sessions (Amendment 1) but not Administration App sessions (R2, issue #172).
- **Customers have no own-password change in the customer app yet** (unchanged: `/app/account/password` explains that it is unavailable there). An administrator resets the password in the Administration App. Follow-up: an own-password endpoint on the customer API with its own reviewed grant.
- **Rollback for staging `/app`:**
  - unset `EMS_WEB_UPSTREAM` and recreate admin-portal. The bundle fallback then serves `/app` on `:8080` again, if a bundle is deployed;
  - alternatively, roll back the admin-portal image.
- **Migration 319 needs no rollback:** it is read-only. If it is absent, the history section shows "not available".

## Implementation references

`app/src/customer_main.py`, `customer_config.py`, `routers/customer_auth.py`, `auth/customer_middleware.py`, `auth/customer_session.py`, `auth/server_session.py`, `auth/audience.py`, `live_main.py`, `live_config.py`, `api_errors.py`, `config.py` (`CoreSettings`), `postgres/migrations/313_customer_api_role.sql`, `314_customer_session_revocation.sql`, `edge/Caddyfile`, `compose.yaml` (`customer-api`, `edge`), `scripts/release/deploy_customer_api.sh`. Amendment 2: `app/src/routers/user_management_api.py`, `user_management_service.py`, `user_account_policy.py`, `provision_portal_admin.py`, `auth/authorization.py` (`/api/admin/` permission map), `postgres/migrations/315_portal_user_management_hardening.sql`, `web/src/routes/admin/`, `web/src/api/adminUsers.ts`. Amendment 3: `app/src/main.py` (`/administration/users*`, `/administration/account/password`, no `/app` in dedicated-container mode), `admin_request_guards.py`, `own_password.py`, `user_management_service.py` (`list_managed_user_audit`), `auth/authorization.py`, templates `users.html`, `user_create.html`, `user_detail.html`, `account_password.html`, `base.html`; `postgres/migrations/319_portal_user_audit_history_read.sql`.

## Validation references

`app/tests/test_customer_api.py`, `test_customer_api_role_db.py`, `test_customer_session_revocation_db.py`, `test_live_customer_session.py`, `test_staff_only_admin.py`, `test_customer_separation_release_contract.py`; local end-to-end harness (edge TLS → customer-api → real Argon2 sign-in and database scoping through `ems_customer_api`), 53/53, 2026-10-26. Amendment 2: `app/tests/test_user_management_api.py`, `test_user_management_db.py`, `test_provision_portal_admin.py`, `web/src/routes/admin/AdminUsers.test.tsx`. Amendment 3: `app/tests/test_user_administration_pages.py`, `test_portal_user_audit_history_db.py`, `test_admin_portal_app_removed.py`, `test_customer_api.py::test_allowed_staff_get_read_only_customer_access_and_no_administration`, `test_check_pending_migrations.py`.
