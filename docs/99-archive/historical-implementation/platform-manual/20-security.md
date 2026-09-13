# Security

```
Status: PARTIAL
Last verified: 2026-08-24
Verification basis: Repository, Staging
```

## Tenant isolation — verified mechanisms

- **Database**: every tenant-owned row carries `organization_id` (and usually `site_id`) as a `NOT NULL` FK; several triggers cross-check that relationships (device↔gateway, asset↔device, asset↔space/floor/building) stay within one organization/site — `validate_tenant_site_ownership`, `validate_device_physical_location`, `validate_asset_physical_location` (all read live this session; see `08-device-onboarding.md` for the full trigger table).
- **Application**: `admin.portal_user_can_access_site(actor_id, site_id)` is called at the top of essentially every `admin.*` mutation and several read functions (`admin.list_accessible_devices`, `admin.list_accessible_assets`, `admin.list_accessible_gateways`) — access is site-scoped, not organization-scoped-only, meaning a user's grant could in principle be narrower than "their whole org."
- **Grafana**: `metadata.grafana_organization_map` + `${__org.id}` templating (see `12-grafana.md`, `14-authentication-and-tenancy.md`).

## What is NOT verified this session

- **Whether staging and production share MQTT broker credentials or routing.** This is an open question, not a conclusion. Evidence found this session is *suggestive but not proof*: real telemetry from physical Eniscope hardware began arriving in staging's `telemetry.energy_measurements` within minutes of creating the corresponding `metadata.device_identifiers` (MQTT_UID) rows for the Meenaxy Pharma devices — the same physical devices that also feed production. This is consistent with staging either (a) sharing the same MQTT broker/credentials as production, or (b) independently receiving the same physical devices' publish via a different broker/bridge, or (c) some other routing this session did not investigate. **Do not treat this as confirmed credential sharing** — it was explicitly out of scope to inspect MQTT broker configuration/credentials directly (see CLAUDE.md's secrets-handling rules below), so the mechanism remains unconfirmed. Flagged as a genuine open item worth deliberately investigating (with someone who owns MQTT infrastructure config) rather than left as an assumption either way.
- Grafana's own internal auth/session model.
- Network-level exposure (firewall rules, security groups) for either environment — not inspected this session.

## Secrets handling (repository policy, summarized from CLAUDE.md — not re-stated verbatim, no values reproduced)

The project's own operating rules (`CLAUDE.md`, sections 5, 17, 18) require: never commit secrets anywhere (code, tests, docs, Docker images, dashboards); never print secrets to the terminal unnecessarily; the live-telemetry service's dedicated MQTT credentials (`MQTT_HOST`, `MQTT_PORT`, `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_LIVE_CLIENT_ID`, `MQTT_TLS`, `EMS_GRAFANA_STREAM_TOKEN`) must never reach browsers, frontend JavaScript, Grafana dashboard variables, or public APIs — only the server-side live-telemetry path may hold them. **This manual follows the same rule: environment variable *names* are documented where relevant to explain architecture; no actual credential value has been or will be written into any file under `docs/platform-manual/`.**

One real incident from this session, recorded here as a documented lesson rather than hidden: an early diagnostic command (`od -c | grep`) intended to check line-ending format of `pgpass.conf` inadvertently printed a password fragment to tool output. No secret was committed to the repository, but it's a concrete example of how a seemingly-innocuous diagnostic (byte-inspecting a credentials file) can leak a secret — prefer `tr`/`sed`-only pipelines that never echo file contents when handling any credentials file.

## Database role separation as a security control

See `14-authentication-and-tenancy.md` for the verified `ems_readonly` vs `ems_admin` visibility difference. From a security-architecture standpoint this is a real hardening measure (read-only tooling literally cannot enumerate trigger-level business rules, reducing what a compromised read-only credential could learn about enforcement internals) — but it also means read-only-role-based documentation/audit work will systematically under-report the schema's actual constraint surface unless cross-checked with an admin-level read, as happened in this project.
