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

**D. Start the customer API** (internal only; no public effect): dispatch
`.github/workflows/deploy-customer-api.yml` with `target_environment=staging`
and `app_git_sha=<the staging commit to run>`. The GHCR packages are private
and the hosts hold no registry login, so the workflow (which has the
registry secrets) resolves the digest and runs
`scripts/release/deploy_customer_api.sh` over SSH. Rollback is the same
dispatch with the previous SHA.

Staging status: B and C done 2026-10-26 (~09:57 UTC; secrets generated on
the host, never displayed; `app/customer-api.env` mode 640). D pending the
workflow above.
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

## 3a. Interim staging setup without a custom domain (2026-10-26)

Custom domains are deferred. The customer application is reached on the
staging host itself; the Administration App stays on `:8080`, unchanged, and
is not routed through the edge (no `EMS_STAFF_HOST`).

**Certificate options** (`EMS_EDGE_TLS`):

| Mode | Site address | Browser | Notes |
|---|---|---|---|
| `acme_ip` (recommended) | the Elastic IP, e.g. `16.113.18.69` | Trusted, no warning | Let's Encrypt IP-address certificate (generally available since 2026-01-15), 6-day `shortlived` profile, renewed automatically by Caddy. Validation (http-01 on :80 / tls-alpn-01 on :443) needs those ports open to the whole internet; access is restricted by `EMS_CUSTOMER_ALLOWED_CIDRS`, which does not affect validation. If renewal fails the certificate expires within days -- monitored by `edge-certificate-check.yml` (section 3b). |
| `internal` | the EC2 hostname or the IP | Warning ("not private" / untrusted issuer) | Caddy's own CA; testers would have to click through or install Caddy's root certificate. Encrypted, but users learn to ignore warnings (phishing / interception risk). |
| `acme` | a hostname | Trusted | Not possible for `*.compute.amazonaws.com`: Let's Encrypt refuses those names by policy ("forbidden by policy"). For a future custom domain. |

**No-SNI clients (found on staging 2026-10-27)**: browsers send no SNI for
an `https://<ip>/` URL (RFC 6066). Without the Caddyfile's global
`default_sni`, Caddy aborts such handshakes with TLS alert 80 even though the
IP certificate was issued -- every browser fails. The first staging start
(02:12–02:14 UTC) hit this and was rolled back. Check with
`openssl s_client -connect <ip>:443 -noservername` (must complete) as well as
with `-servername`. The unused staff block now uses `EMS_STAFF_EDGE_TLS`
(default `internal`), so it never asks Let's Encrypt for `staff.invalid`.

**Controlled access**: `EMS_CUSTOMER_ALLOWED_CIDRS` (space-separated, e.g. the
office / VPN egress CIDRs) -- every other client gets 403 for every path.

**Root `.env` (edge only)**: `EMS_CUSTOMER_HOST=<site address>`,
`EMS_EDGE_TLS=acme_ip`, `EMS_CUSTOMER_ALLOWED_CIDRS=<approved CIDRs>`,
`EMS_EDGE_HSTS_MAX_AGE=<short interim value, e.g. 86400>`;
`EMS_STAFF_HOST` unset (defaults to `staff.invalid`, unreachable).

**Rollback**: `docker compose -f /opt/ems-platform/compose.yaml --profile edge stop edge`
(ports 80/443 stop answering; nothing else changes).

## 3b. Certificate renewal and its monitoring (staging, verified read-only 2026-10-28)

**How renewal works.** Caddy 2.10.2 (`ems-edge`) manages the customer certificate (Let's Encrypt `YE1`, IP SAN `16.113.18.69`, 6-day `shortlived` profile, ~160 h lifetime) in the `edge-data` volume (`/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/16.113.18.69/`; account in `/data/caddy/acme/`). Its maintenance loop checks every 10 minutes and uses ACME Renewal Info (ARI): Let's Encrypt suggests a renewal window (for the certificate valid to 2026-11-02 17:14 UTC: 2026-10-30 08:08–11:18 UTC; Caddy picked 10:50 UTC), stored in the certificate's `.json` beside it. Without ARI it renews once a third of the lifetime remains (~53 h). Validation is http-01 on :80 or tls-alpn-01 on :443 from Let's Encrypt's validators, so **both ports must stay open to `0.0.0.0/0`** (the Caddy allowlist does not affect validation; a security-group restriction would). The internal `staff.invalid` certificate (local CA, 12 h) renews itself every ~8 h; its "stapling OCSP" warnings are expected.

**What happens on failure.** Caddy logs `renewing certificate` / an `error` from `tls.renew` / `tls.obtain` and retries with backoff on every maintenance pass, keeping the current certificate in service. If no renewal succeeds before expiry, browsers refuse the site and, with HSTS (1 day on staging), offer no click-through. Nothing restarts or alerts on the host.

**Alert.** `.github/workflows/edge-certificate-check.yml` runs every 3 hours on a GitHub-hosted runner: one TLS handshake to the customer endpoint (`scripts/verify/check_edge_certificate.sh`, no SNI, as browsers send for an IP URL), chain verified against the system trust store for the IP, and **fails when fewer than 48 h of validity remain** -- i.e. after both the ARI window and the fallback window have passed without a renewal, with two days still left to act. It also fails if :443 stops answering from the internet (which would also stop renewal). A failed run e-mails the user who last changed the schedule (GitHub notification settings). Manual run: Actions → *Edge certificate check* → Run workflow (optional `min_hours`), or locally `./scripts/verify/check_edge_certificate.sh 16.113.18.69`. GitHub disables scheduled workflows after 60 days without repository activity.

**Read-only investigation on the host** (never restart or reload Caddy to test):

```bash
docker logs ems-edge --since 24h 2>&1 | grep -E 'tls\.(renew|obtain)|renewal info|"level":"error"'
docker exec ems-edge cat /data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/16.113.18.69/16.113.18.69.json   # SANs + ARI window; no key material
```

Typical causes: :80/:443 not reachable from the internet (security group, network ACL, `EMS_EDGE_BIND_HOST`), Let's Encrypt rate limits or outage, the IP no longer pointing at this host. Forcing a renewal or restarting `edge` is an operational change and needs approval.

**Deployed and verified (2026-10-28).** PR #162 merged as `60a34a2`; workflow *Edge certificate check* active, schedule `23 */3 * * *` (UTC). Manual run `40698497854`: PASS (Let's Encrypt YE1, not after 2026-11-02 17:14:19 UTC, 123 h left). Deliberate failing run `40698516701` (`min_hours=200`): FAIL as designed, which sends the failure notification. Recipient: scheduled runs notify the user who last changed the schedule (commit `60a34a2`, `avinash-wisewatts`); a manually dispatched run notifies the user who dispatched it. If the schedule should alert someone else, that person changes the cron line (or the alert is moved to a channel) in a reviewed PR.

**Manual recovery when the check fails** (renewal has not happened and < 48 h remain). Steps 1–3 are read-only; steps 4–5 change the live endpoint and each need explicit approval.

1. Confirm: `./scripts/verify/check_edge_certificate.sh 16.113.18.69` from any machine; read the workflow log (issuer, not-after).
2. Find the cause in Caddy's own words: the `docker logs ems-edge` filter above (`tls.renew` / `tls.obtain` errors name the failing challenge and the CA's reason), and the certificate `.json` (ARI window). Note the next retry time Caddy logs; it retries on its own.
3. Check reachability: ports 80 and 443 must be open to `0.0.0.0/0` in the instance's security group **and** the subnet's network ACL (AWS Console, read-only); `docker ps` must show `ems-edge` publishing `0.0.0.0:80` and `0.0.0.0:443`; check Let's Encrypt's status page for an outage. Do not delete the `edge-data` volume: it holds the ACME account and the current certificate.
4. Fix the cause (approved change: e.g. restore the inbound rule). Caddy normally renews on a later maintenance pass without a restart; confirm with the log (`certificate obtained successfully` / `renewed`) and a manual workflow run.
5. Only if expiry is imminent and Caddy is still waiting out its retry backoff after the cause is fixed: an approved `docker compose -f /opt/ems-platform/compose.yaml --profile edge restart edge` (a few seconds without the customer endpoint; Caddy re-checks and renews managed certificates at start-up). Switching `EMS_EDGE_TLS` to `internal` is **not** a fallback for customers: browsers that saw the HSTS header refuse an untrusted certificate without a click-through until `EMS_EDGE_HSTS_MAX_AGE` (1 day on staging) has passed.

## 4. Verification checklist (staging)

- `https://<customer host>/` → 302 `/app/`; `/app/`, deep links and hashed assets 200; HSTS present; no `Server` header.
- `/login`, `/administration/*`, `/onboarding/*`, `/docs`, `/openapi.json`, `/health` on the customer host → 404.
- Customer sign-in sets `ems_session` (`Secure`, `HttpOnly`, `SameSite=Lax`, no `Domain`); `/api/v1/sites` returns only the account's sites; cross-tenant site → 404; sign-out → subsequent 401.
- Session revocation (migration 314, section 7): a cookie copied before sign-out → 401 afterwards; an open live WebSocket of that session closes with 4401 within `EMS_CUSTOMER_SESSION_RECHECK_SECONDS`.
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
| Migration 314 | Previous application image on customer-api **and** live-telemetry first (otherwise every customer request is 503), then drop the trigger, functions and table (migration header) |

## 6. Known residuals

- `admin.list_accessible_asset_device_relationships` is `SECURITY DEFINER` and executable by `PUBLIC` (noted in migration 308); every role, including `ems_customer_api`, can call it. It is portal-scoped. Hardening it is a separate change.
- Login lockout counters are shared by both hosts (one identity store).
- Administration App sessions are still stateless signed cookies (no server-side revocation); migration 314 covers the customer host only.
- Before any production rollout, verify the production Docker Compose version supports `env_file: required: false` (staging: v5.5.1).

## 7. Server-side customer sessions (migration 314, ADR-023 Amendment 1)

**What it does.** Customer sign-in stores the SHA-256 of a random session token in `admin.portal_sessions`; the token itself lives only in the signed `HttpOnly` cookie. Every customer API request and every customer live stream checks the row, so sign-out, deactivation and a password change end the session everywhere (open live WebSockets close with 4401 within `EMS_CUSTOMER_SESSION_RECHECK_SECONDS`, default 30 s).

**Deployment order (staging).** Normal staging release: merging applies migration 314 and deploys live-telemetry with the new image (`deploy-staging.yml`); then run `deploy-customer-api.yml` with the same SHA straight away. In between, the old customer-api issues cookies without a token, which the new live-telemetry refuses: live values show "sign in again" until customer-api is updated. Existing customer sessions end once (cookies from before 314 carry no token). No configuration change is required; the new settings have defaults.

**Settings.**

| Variable | Service | Default | Meaning |
|---|---|---|---|
| `EMS_APP_SESSION_MAX_AGE_SECONDS` | customer-api | 28800 | Idle lifetime; slides with use (cookie and server row) |
| `EMS_CUSTOMER_SESSION_ABSOLUTE_MAX_AGE_SECONDS` | customer-api | 604800 | Hard limit from sign-in; not shorter than the idle lifetime |
| `EMS_CUSTOMER_SESSION_RECHECK_SECONDS` | live-telemetry | 30 | How often an open customer WebSocket re-checks its session |

**Availability.** Customer sign-in and every customer request need the database (they already did for data). If the session check cannot reach it, requests answer 503 (`service_unavailable`) without signing anyone out; live streams close with 1011 and reconnect. Sign-out always clears the browser; if the revocation itself fails it answers 503 and the server row lapses at its idle expiry.

**Operations (read-only checks; run as `ems_admin` on the host).**

```sql
-- open sessions per account (no token material: hashes only)
SELECT portal_user_id, count(*) FILTER (WHERE revoked_at IS NULL AND idle_expires_at > now()) AS live,
       count(*) AS rows, max(last_seen_at) AS last_seen
FROM admin.portal_sessions GROUP BY 1 ORDER BY 1;
-- recent revocations by reason
SELECT revoked_reason, count(*) FROM admin.portal_sessions WHERE revoked_at > now() - interval '1 day' GROUP BY 1;
```

To end every session of one account immediately, deactivate it (or change its password) through the Administration App; the trigger revokes its sessions. Storage: one small row per sign-in; an account's dead rows are purged at its next sign-in (no scheduled job).

**Staging deployment and verification (2026-10-28).**

- First release (`e271f59`, run `40689330235`) failed on 314's own postcondition (`admin.portal_sessions is granted to a role`): staging's out-of-band read-only role `ems_investigator` holds default `SELECT` on new `admin` tables. The migration rolled back (ledger stayed 185 / `313`); app containers were not recreated. Fix PR #164 (`9b3e85d`) revokes that grant in 314 and reproduces the role's default privileges in the test database (`scripts/test/staging_role_parity.sql`).
- Release `9b3e85d` (run `40694827888`): `APPLIED 314_customer_session_revocation` at 13:28:31 UTC, ledger 186 / head `314`; table ACL owner-only; create/touch/revoke executable by `ems_customer_api` only, `get_portal_session_user` by `ems_app` only, nothing by PUBLIC; trigger enabled. `deploy-customer-api.yml` run `40697248703` with the same SHA (healthy after 10 s).
- Through `https://16.113.18.69/` with the test accounts: every cookie issued before the release → 401 (the one-time sign-out of all customers); new sign-in → `Secure; HttpOnly; SameSite=Lax`, no `Domain`, one server row each; tenant isolation (no shared sites between organisations, another organisation's site → 404, selected-sites account a subset). Open live stream (58 points) + sign-out → stream closed 4401 after 30.0 s; replay of the captured cookie → read 401, write 401, WebSocket 4401. Idle expiry of a server row → 401. Password change → old sessions 401, open stream 4401, new credentials 200. Deactivation → 401 at once, rows `ACCOUNT_DEACTIVATED`, sign-in refused, open stream 4401; after re-activation the old cookie stays 401 and a new sign-in works. No errors in customer-api / live-telemetry logs; ingestion freshness about 2 s.
- Database-outage handling (503 without sign-out; sign-out still clears the browser; streams close 1011) is covered by the automated tests and was not exercised on staging, to keep the customer endpoint up.
