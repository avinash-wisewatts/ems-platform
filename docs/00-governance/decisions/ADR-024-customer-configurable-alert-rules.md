# ADR-024: Customer-configurable alert rules, acknowledgement, and placeholder delivery in the EMS Web Application — replacing MVP-7 Basic Alerts

Status: Decided (Product Owner, 2026-11-18, including the final Phase 0
decisions on staff access, audit actor type, equality tolerance, telemetry
unavailability, the per-site rule limit and — final scope amendment — the
**complete replacement and retirement of the MVP-7 Energy Attention
alerts**; final Phase 0 approval decisions on 90-day history retention,
the Resolved/Ended history view and `GLOBAL` `OPERATOR` acknowledgement);
**DDS classification APPROVED** (2026-11-18 — § "DDS change-control
note"); Phase 0 complete; **implemented** (Phase 1, PR #179, migrations
320–326) and **deployed to staging 2026-11-18**, where migration 320
deleted the 79 legacy alert records; **Amendment 1** (D-1 timing grace,
D-2 rule-wide previous occurrences — migration 327) approved 2026-11-18;
**not on production** (separate approval,
[production plan](../../09-release-and-deployment/production-release-alerts-adr-024.md)).
Date: 2026-11-18
Decision owners: Product Owner (product decisions, §1–§13, §17–§18);
Architecture (the write-path architecture in §14–§16, which applies the
existing Reports-export pattern and the platform's existing audit
mechanism, and the retirement inventory in §19)
Related requirements: [functional-requirements.md §Alerts](../../02-requirements/functional-requirements.md#alerts)
— `EMS-REQ-082` (unblocked by this ADR), `EMS-REQ-084`, `EMS-REQ-117`–`EMS-REQ-127`
(retired or amended where noted), `EMS-REQ-140`–`EMS-REQ-152` (new)
Related features: [Alerts](../../07-features/alerts/README.md)
Supersedes: [ADR-016](ADR-016-q77-mvp7-basic-alerts.md) **as a product**
— the automatic Energy Attention alert experience is retired and replaced
(§17); only the lifecycle rules this ADR explicitly re-adopts survive, and
they apply to rule-based alerts. In particular ADR-016 decisions 1
(scope), 2 (automatic Attention-generated alerts), 4 (data-gap ending —
replaced by §4A), 12 (delivery wording — see §9), 13 (Attention-condition
filtering), 14 (configuration location and permission model) and 15 (no
acknowledgement) no longer describe the product. Workshop Q67 as it
applies to **alert configuration**. The A1 evaluator *instance* and the
server-side ±15% single-source-of-truth function of
[ADR-017](ADR-017-mvp7-alert-architecture.md) (§19).
Amends: [ADR-006](ADR-006-ems-web-app-vs-admin-portal.md) (Amendment 2),
[ADR-007](ADR-007-analytics-api-boundary.md) (Amendment 1),
[ADR-017](ADR-017-mvp7-alert-architecture.md) (scope note — the `Alert`
concept and the TimescaleDB-job mechanism are retained),
[ADR-010](ADR-010-mvp3-attention-materiality-policy.md) (note — its
server-side alerting qualification falls away; the Attention display is
unchanged).

## Context

MVP-7 (ADR-016/ADR-017) shipped automatic, read-only alerts generated
from one existing condition (Site-level Energy Attention, ±15%). Its
configuration was decided to live only in the Administration App
(ADR-016 decision 14, Workshop Q67), acknowledgement was excluded
(decision 15), and delivery was in-product only (decision 12). ADR-006
recorded that the customer EMS is read-only and that any future customer
write routes through an Administration-App-owned mechanism; ADR-007
recorded the Analytics API as a read-only `GET /api/v1/*` boundary.

The Product Owner has now approved an Alerts release in which customer
site administrators (and WiseWatts `GLOBAL` `ADMIN` staff) configure alert
rules **inside the customer EMS application**, authorised users
acknowledge Active alerts, and Email and WhatsApp appear only as
"Coming Soon" options. This explicitly supersedes the earlier workshop
decision Q67 for alert configuration. The new experience **replaces**
MVP-7 Basic Alerts entirely: the fixed Energy Attention alert mechanism,
its evaluator and job are retired, and its existing records are deleted
(§17–§18).

Repository facts this decision builds on (verified on `origin/staging`
`8abd023`, 2026-11-18):

- `analytics.alerts` (migrations 238/242) has `asset_id` (reserved,
  unpopulated), a stable `condition_key` identity, the
  Active/Resolved/Ended lifecycle, the controlled `ended_reason_code`
  (`CONFIGURATION_CHANGED` | `DATA_UNAVAILABLE`) and the one-Active-per-
  condition unique index `ux_alerts_one_active_per_condition`. Every row
  that exists today is a legacy Energy Attention row (`condition_key`
  `ENERGY_ATTENTION:…`, `metric` `ENERGY_CONSUMPTION`).
- `analytics.evaluate_alerts()` (migration 242) and the TimescaleDB job
  running `analytics.run_alert_evaluation_job` (job 1127 on staging)
  implement the 5-minute qualification / 1-minute resolution timers
  (`analytics.alert_evaluation_candidates`). The job was registered by a
  separate manual step (`postgres/jobs/238_alert_evaluation_job.sql`), so
  its id — and whether it exists at all — differs by environment.
- `analytics.evaluate_energy_attention_materiality` (migration 239) is
  called only by `evaluate_alerts()` and alert tests. The Energy Attention
  shown on Site Overview, Main Dashboard and the Site Performance Report
  is computed in the browser (`web/src/attention/`, ADR-010) and does not
  use it.
- A customer-initiated write path already exists: the Reports export jobs
  (ADR-014 Amendment 2, migrations 309/312, `app/src/routers/report_exports.py`)
  — route-level permission (`report.export`), `application/json` only,
  cross-site (`Sec-Fetch-Site`) rejection, writes only through
  SECURITY DEFINER functions that re-check site access. It writes **no**
  `admin.audit_events` row.
- The platform audit mechanism is `admin.audit_events` written by
  `admin.write_audit_event(...)` (baseline migration 001), callable only
  from inside SECURITY DEFINER functions (revoked from `ems_app`).
- `PortalPermission.ALERT_ACKNOWLEDGE` (`alert.acknowledge`) already
  exists and is held by `ADMIN` and `OPERATOR` (`app/src/auth/authorization.py`;
  `config.portal_role_permissions`), unused so far. No alert-configuration
  permission exists.
- `required_permission_for_request` maps **every** `/api/v1/*` request,
  of any HTTP method, to `dashboard.view`; anything stronger must be
  enforced by the route itself and by the database function.
- The customer API connects as `ems_customer_api` (migration 313,
  **staging/test only** — the role does not exist on production), which
  may execute only an enumerated function list.
- `scripts/apply_migrations.sh`: a migration **not listed** in
  `postgres/migration_environment_scope.csv` runs in every environment; a
  listed one runs only in its `|`-separated environments
  (`staging`, `production`, `test`).

## Decision

### Product decisions (Product Owner, 2026-11-18)

**1. Configuration location.** Alert rule configuration is part of the
customer-facing EMS Web Application (Alerts → Create Alert subtab), not
the Administration App. This supersedes ADR-016 decision 14's
"Configuration remains exclusively in the Administration App" and
Workshop Q67 for alert configuration. Q67 is unchanged for every other
kind of configuration (functional categories, tariffs, onboarding — see
ADR-006).

**2. Who may do what.**

| Action | Customer site administrator (`ADMIN`, ORGANIZATION / SELECTED_SITES scope covering the site) | Customer operator (`OPERATOR`, scope covering the site) | Other authorised customer user (`VIEWER`, scope covering the site) | WiseWatts staff — `GLOBAL` `ADMIN` | WiseWatts staff — `GLOBAL` `OPERATOR` | WiseWatts staff — `GLOBAL` `VIEWER` |
|---|---|---|---|---|---|---|
| View alerts (Active and Resolved/Ended history), acknowledgement information and rules | Yes | Yes | Yes | Yes, every customer site | Yes, every customer site | Yes, every customer site |
| Acknowledge an Active alert | Yes | Yes | No | Yes, every customer site | **Yes, every customer site** | **No** (read-only) |
| Create, edit, enable/disable, delete rules | Yes | **No** | No | Yes, every customer site | **No** | **No** (read-only) |

**WiseWatts staff exception.** A `GLOBAL`-scope `ADMIN` (WiseWatts staff,
ADR-023 decision 4) may create, edit, enable/disable, delete and
acknowledge on **any** customer site; a `GLOBAL` `OPERATOR` may
acknowledge (but not configure) on any customer site; a `GLOBAL`
`VIEWER` is **read-only**. No additional support authorisation (ticket,
customer consent, time-boxed elevation) is required for now. This needs
no special-case code: `admin.portal_user_can_access_site` already grants
`GLOBAL` scope every site, `ADMIN` holds every permission and `OPERATOR`
holds `alert.acknowledge` but not the new configuration permission. Staff
reach the EMS Web App on the customer host only where
`EMS_CUSTOMER_ALLOW_STAFF` is on (ADR-023 Amendment 3). Every staff action
is audited as a staff action (§16).

This replaces ADR-016 decision 14's "no alert-specific permission"
statement: alert configuration gets its own dedicated permission (§15).

**3. Rule definition.** A rule belongs to one site and one asset of that
site, and has: a name; one parameter (data point) available for that
asset; a condition — greater than, less than, or equal to (explicit
tolerance, not for cumulative counters, §5); a comparison target — a
fixed value, or the mean of the parameter over a configurable time window
(delivered in a later increment, §12); a schedule — a daily time range
and either every day or selected weekdays, interpreted in the **site's
timezone**; a reminder frequency (§10); delivery preferences for Email
and WhatsApp (§9); and an enabled/disabled state. Rules are the **only**
source of alerts once the legacy mechanism is retired (§17).

**4. Qualification and resolution.** A rule's condition must be
continuously true for **5 minutes** before an alert occurrence is
created, and an Active occurrence resolves after the condition is
continuously false for **1 minute** on valid data; a gap in evaluation or
data resets the running timer (the periods and gap-reset rule re-adopted
from ADR-016 decisions 2–3). A gap never resolves or ends an Active
occurrence (§4A). The once-a-minute evaluation applies a 2-second
run-jitter grace to both periods (Amendment 1, D-1).

**4A. Telemetry unavailable.** When the telemetry a rule evaluates
becomes unavailable while an occurrence is Active, the occurrence **stays
Active and keeps its acknowledgement** (who/when) — it is neither
Resolved nor Ended, and the customer sees that it cannot currently be
evaluated ("Unable to evaluate — data unavailable"). Evaluation resumes
when valid data returns: if the condition is still true the **same**
occurrence simply continues (no new occurrence, no re-qualification, no
new reminder cycle); it becomes **Resolved only when the condition is
confirmed clear** — continuously false for 1 minute on valid data. A gap
during the 1-minute resolution window resets that window; a gap during
the 5-minute qualification window resets qualification. This replaces
ADR-016 §4's "still material on recovery → Ended `DATA_UNAVAILABLE`"
rule: rule-based alerts **never** end with `DATA_UNAVAILABLE`.

**5. Equal-to requires an explicit tolerance.** "Equal to" means the
observed value is within a tolerance of the target
(`|observed − target| ≤ tolerance`), never exact equality. The rule's
author **must enter the tolerance explicitly**, in the selected
parameter's unit; it is required (≥ 0) and there is **no default — silent
or pre-filled**. "Equal to" is **not offered for cumulative counters** in
the initial release. See "Equality tolerance" below.

**6. Schedule closes while an alert is Active.** The alert **stays
Active** until its condition resolves (or a rule configuration change
ends it). The end of a schedule window never resolves or ends an alert.
Outside the schedule window a rule does not create new occurrences.

**7. Acknowledgement.** Acknowledgement records that an authorised user
has seen an Active alert. It records **who** acknowledged and **when**.
It is **not** resolution: an acknowledged alert remains **Active** until
its condition resolves (→ Resolved) or a rule configuration change ends it
(→ Ended, `CONFIGURATION_CHANGED`). Acknowledgement is never a path to
Resolved or Ended, and the customer-visible states remain exactly Active,
Resolved and Ended; "acknowledged" is an attribute of an occurrence, not
a fourth state. Telemetry unavailability never removes an acknowledgement
(§4A). This supersedes ADR-016 decision 15.

**8. Rule edit, disable, delete.** Editing, disabling or deleting a rule
ends any associated Active occurrence as **Ended** with
`ended_reason_code = CONFIGURATION_CHANGED` (the configuration-transition
rule re-adopted from ADR-016 decision 8). `CONFIGURATION_CHANGED` is the
only Ended cause for rule-based alerts. Disabling stops new occurrences.
Re-enabling or saving an edit starts fresh evaluation under the new
configuration with a new condition identity (fresh 5-minute
qualification). Deletion is a **soft delete**: the rule no longer appears
in the rule list and is never evaluated again, and every historical
occurrence it produced is preserved with its own recorded name, asset,
parameter, condition and values. Editing, disabling or deleting never
erases or rewrites historical occurrences (immutability, re-adopted from
ADR-016 decision 9). **Retention (decided 2026-11-18): 90 days** —
a Resolved or Ended rule-based occurrence remains visible for 90 days
from its resolved/ended time; an Active occurrence is kept while it is
Active. Soft deletion of a rule does not shorten this.

**9. Email and WhatsApp — "Coming Soon" only.** The rule form shows Email
and WhatsApp as delivery options marked **Coming Soon**. The selected
preferences may be stored with the rule. **No email or WhatsApp message
is sent, no delivery integration or outbound messaging is authorised, and
the UI must not show any delivery status, "sent" or success indication.**
Alerts reach the customer only in-product (header indicator and Alerts
area). Actual multi-channel delivery remains `EMS-REQ-084`, deferred.

**10. Reminders.** A rule may carry a reminder frequency. The policy is:
reminders repeat at that frequency while an occurrence is Active and
**unacknowledged**; acknowledgement stops reminders; acknowledgement does
not resolve the alert. Because no delivery channel exists in this
release, **no reminder is delivered**; the stored frequency must be
presented so it does not imply reminders are being sent (shown with, and
as applying to, the Coming Soon channels). Reminder generation is a later
phase that depends on a delivery channel (see "Later-phase
dependencies").

**11. Customer Alerts UI — three views (decided 2026-11-18).**
- **Active Alerts** — for the selected site: Name, Asset, Status and an
  Acknowledge action; selecting an alert opens its detail — triggered
  time, triggering condition, asset, parameter, threshold/value, current
  status and acknowledgement information (who, when).
- **Create Alert** — the site's rules (Name, Asset, Parameter,
  Value/condition, enabled toggle, Edit, Delete) and Create New Alert.
- **Resolved/Ended history** — the site's rule-based occurrences that
  were Resolved or Ended within the 90-day retention window (§8), with the
  same detail plus resolved/ended time, Ended reason and acknowledgement
  information; read-only. Occurrences of soft-deleted rules remain listed
  with their recorded name and condition.

Only rule-based alerts exist; there is no Energy Attention alert and no
legacy view (§17). The header Active-alert indicator counts rule-based
Active alerts for the selected site.

**12. Delivery sequence.** Fixed-value comparisons are delivered first;
mean-over-time comparisons follow in a later increment, behind the same
rule model.

**13. Evaluator performance and monitoring.** Rule evaluation must be
bounded and set-based (no per-rule round trips). Initial limit: **at most
25 active (enabled, non-deleted) rules per site**, enforced server-side
when a rule is created or enabled — a target subject to staging
performance validation, adjustable only by a later decision. The
evaluator must be monitored: its job is registered and checked by the
deployment verification suite (`scripts/verify/verify_jobs.sh` pattern),
and each run's outcome, duration and rules evaluated are observable so a
stalled or slow evaluator is detected. The release must pass staging
performance checks; the staging host's headroom is small (see the Phase 0
baseline in
[alerts/README.md](../../07-features/alerts/README.md#staging-baseline-2026-11-18)).

**17. Complete replacement of the MVP-7 Basic Alerts.** The new
customer-configurable Alerts experience **replaces the existing Alerts
UI entirely** (the Active/Resolved/Ended Energy Attention area,
`web/src/routes/alerts/AlertsArea.tsx`). The fixed Energy Attention alert
mechanism (±15%), its automatic evaluator and its scheduled job are
**retired**. **All existing legacy Energy Attention alert records are
deleted.** No separate historical or legacy Alerts experience is
retained. Rule-based alerts have their own lifecycle (§4–§8) and their
historical records are preserved. The **Energy Attention display itself
is not retired**: Site Overview, Main Dashboard and the Site Performance
Report keep their ADR-010 client-side Attention exactly as today — only
its alerting layer is removed.

**18. Legacy record deletion and release behaviour.** Not executed by
this decision; nothing has been deleted.

- **Staging:** the legacy records are deleted by a migration that ships
  with the replacement feature, in the same release.
- **Production:** the same migration performs the same deletion
  automatically as part of the **separately approved** production
  deployment of the replacement feature — never as a separate manual
  operation, and never ahead of the replacement UI/API.
- **Scope:** the migration is **explicitly listed** in
  `postgres/migration_environment_scope.csv` as
  `staging|production|test` (not staging-only), with its reason.
- **Retire before delete:** the legacy evaluator job is removed and its
  procedures retired in the same migration, before the deletion, so
  nothing can recreate the deleted records.
- **Legacy only:** the deletion targets legacy Energy Attention records
  only (§20) and can never affect a rule-based alert.
- **Recorded outcome:** the migration records its outcome and deletion
  counts (per table and per state) durably in the database and in the
  release record for each environment (§20).

### Architecture decisions

**14. Customer writes go through the API and database write functions —
never direct frontend database writes.**

1. The EMS Web Application makes authenticated, same-origin JSON requests
   to the customer API (`/api/v1`), using the existing session.
2. The API route enforces the dedicated permission for the action,
   rejects non-JSON bodies and cross-site requests (the Reports-export
   `_require_same_site_json` pattern, on top of the existing same-origin
   check for unsafe methods in `customer_middleware.py`), and resolves the
   acting user only from the server-side session — identifiers from the
   browser are never trusted for authorisation.
3. A SECURITY DEFINER database function performs each write. It
   independently re-checks the actor's permission
   (`admin.portal_user_has_permission`) and site access, and validates the
   relationships: the asset belongs to the site, the parameter is
   available for that asset, and (for acknowledgement) the occurrence
   belongs to an accessible site and is currently Active. An inaccessible
   or unknown site, asset, rule or alert is indistinguishable from a
   missing one (ADR-007).
4. The write and its audit event are committed in **the same transaction**
   (§16) — a write never commits without its audit row.
5. Rule evaluation runs server-side only (§13; ADR-017's TimescaleDB-job
   mechanism, as a new job — §19).
6. The frontend never writes to the database, never sees MQTT/telemetry
   internals, and its permission checks are UX-only.

**15. Dedicated permissions — `dashboard.view` is not sufficient.**
Configuration needs a new, dedicated permission (proposed code
`alert.configure`, granted to `ADMIN` only); acknowledgement uses the
existing `alert.acknowledge` (`ADMIN`, `OPERATOR`). Both are enforced at
the route **and** in the database function, together with site access —
which is how the §2 staff exception works (`GLOBAL` `ADMIN` = both
permissions + every site; `GLOBAL` `OPERATOR` = `alert.acknowledge` +
every site; `GLOBAL` `VIEWER` = neither). Implementation
notes: `ADMIN`'s database permissions were seeded as the complete
catalogue at the time, so a new permission must be explicitly granted to
`ADMIN` in `config.portal_role_permissions` by its migration; the API's
`ROLE_PERMISSIONS` gives `ADMIN` every `PortalPermission` automatically;
`required_permission_for_request` should name the new write routes
explicitly rather than rely on the blanket `/api/v1/*` → `dashboard.view`
rule; every new function must be granted to `ems_app` and — where the
role exists — to `ems_customer_api` (migration 313 pattern; the grant
must be guarded so the same migration also applies on production, where
the role does not exist yet).

**16. Audit — every action, actual actor, customer vs. staff.** Every rule
creation, edit, enable, disable, deletion and every acknowledgement writes
one `admin.audit_events` row via `admin.write_audit_event` in the same
transaction as the change. The row records the **actual acting identity**
(`actor_portal_user_id` — the signed-in user, never a shared or service
identity), `actor_role`, and an **actor type** that distinguishes a
**customer user** (ORGANIZATION / SELECTED_SITES scope) from **WiseWatts
staff** (`GLOBAL` scope), derived server-side from the actor's access
scope at the time of the action — never supplied by the browser. It also
records organisation, site, entity type and id, action, `previous_values`
/ `new_values` (secrets/PII redacted by the existing
`admin.redact_audit_json` convention) and result. `admin.audit_events`
has no actor-type column today; whether it becomes a column or a required,
validated audit field is a Phase 1 implementation detail, but the
distinction is mandatory. Occurrences ended `CONFIGURATION_CHANGED` by a
rule change are ended in that same audited transaction. Exact
action/entity codes are a Phase 1 detail. Unlike the Reports-export
precedent, alert writes may not skip auditing.

**19. Legacy component inventory — retire, replace, reuse, keep.**
Verified by repository search (2026-11-18). Not every legacy object can
simply be dropped; each has a disposition:

| Component | Where | Disposition |
|---|---|---|
| TimescaleDB job running `analytics.run_alert_evaluation_job` | registered manually from `postgres/jobs/238_alert_evaluation_job.sql`; job 1127 on staging; production unknown | **Retire** — removed by the retirement migration, located by procedure name (never by id), no error if absent |
| `postgres/jobs/238_alert_evaluation_job.sql` | repository | **Retire** — removed so the legacy job cannot be re-registered |
| `analytics.run_alert_evaluation_job`, `analytics.evaluate_alerts()` | migrations 239/241/242 | **Retire** — dropped (or replaced) in the retirement migration, before the deletion |
| `analytics.evaluate_energy_attention_materiality` | migration 239 | **Retire** — only callers are the legacy evaluator and its tests; the ADR-010 client Attention does not use it |
| `analytics.alerts` legacy rows | migrations 238/242 | **Delete** (§18, §20) |
| `analytics.alerts` table, constraints, unique index, retention indexes | migrations 238/242 | **Reuse (recommended)** as the rule-based occurrence store, extended in Phase 1 with a rule reference, acknowledgement and history snapshot; a guard then prevents legacy-shaped rows. Replacing it with a new table is the alternative; either way legacy rows are deleted first. Final choice in Phase 1 design. |
| `analytics.alert_evaluation_candidates` | migration 238 | **Clear legacy rows**; reuse or replace for rule timers in Phase 1 design |
| `analytics.get_portal_site_alerts`, `analytics.get_portal_alert_detail` | migrations 239/240/242; granted to `ems_customer_api` (313) | **Replace** with rule-aware versions (a changed row shape needs DROP/CREATE, which drops the grants — the new migration must re-grant, guarded per §15) |
| `GET /api/v1/sites/{site_id}/alerts`, `GET /api/v1/alerts/{alert_id}`, `AlertSummary`, `fetch_site_alerts`, `fetch_alert_detail` | `app/src/routers/analytics_api.py`, `app/src/analytics_api_service.py` | **Replace** — same paths may be kept with the new contract (ADR-007: a contract change needs this decision, recorded here) |
| `AlertsArea.tsx` (+ test), `Alert`/`AlertState`/`AlertListResponse` types, `getSiteAlerts`/`getAlertDetail`, `conditionLabel`/`ENDED_REASON_LABELS`/`energyAttentionConditionKey` | `web/src/routes/alerts/`, `web/src/api/` | **Replace** with the new Active Alerts / Create Alert UI |
| Header indicator `useActiveAlertCount`, nav entries, `/features/alerts` route | `web/src/alerts/`, `web/src/layout/`, `web/src/router.tsx` | **Reuse** — point at rule-based alerts |
| `scripts/verify/verify_jobs.sh` MVP-7 section; `post_deploy_verify.sh` note | `scripts/` | **Replace** — must assert the legacy job is **absent** and the new rule job is healthy |
| Legacy tests: `test_alert_evaluation_contract.py`, `test_alert_evaluation_transaction_control_fix_contract.py`, `test_alert_date_filter_state_keying_contract.py`, `test_mvp7_alert_data_unavailable_lifecycle_contract.py`, `test_analytics_api_v1_alerts_routes.py`, alert cases in `test_customer_api.py` and `test_pipeline_five_minute_batch_schedule.py`, `scripts/test/assert_mvp7_alert_*` | `app/tests/`, `scripts/test/` | **Replace or retire** with the legacy objects — never weakened to pass |
| Migrations 238–242 files and ledger rows | `postgres/migrations/` | **Keep** — applied history is never edited or removed; retirement is a new forward migration |
| `postgres/restructure_manifest.csv` | repository | **Extend** — register the new migrations |
| ADR-010 `MVP3_MATERIALITY_POLICY`, `web/src/attention/*`, Site Overview / Main Dashboard / Site Performance Report Attention, `analytics.energy_consumption_daily`, `get_portal_site_energy_typical_reference` | web + DB | **Keep — not part of the alerting layer** |

**20. Proposed retirement migration scope (Phase 1 design input; not
implemented).** One forward migration (or an ordered pair in the same
release), explicitly scoped `staging|production|test`, idempotent, and
safe on an environment where the job was never registered:

1. **Pre-check (abort on anything unexpected):** count `analytics.alerts`
   and `analytics.alert_evaluation_candidates` rows by state; classify
   each as legacy (predicate below) or rule-based; **abort** if any row
   is neither — the migration never deletes a row it cannot classify.
2. **Retire the evaluator:** remove every TimescaleDB job whose procedure
   is `analytics.run_alert_evaluation_job` (looked up in
   `timescaledb_information.jobs`; zero jobs is not an error), then drop
   (or replace with a non-writing stub) `run_alert_evaluation_job`,
   `evaluate_alerts` and `evaluate_energy_attention_materiality`.
3. **Delete legacy rows only:** legacy predicate =
   `condition_key LIKE 'ENERGY_ATTENTION:%'` **and**
   `metric = 'ENERGY_CONSUMPTION'` **and** (once the rule reference
   exists) no rule reference. Delete from
   `analytics.alert_evaluation_candidates` first (it references alerts),
   then `analytics.alerts`.
4. **Prevent reappearance:** add a constraint so no legacy-shaped row can
   be inserted again (for example, every occurrence must reference a
   rule).
5. **Record the outcome:** per-table and per-state deletion counts and
   the removed job ids, written durably (proposed: one
   `admin.audit_events` row with a system actor role and the counts in
   `new_values`, plus `RAISE NOTICE` lines captured in the deployment
   log) and copied into the environment's release record.
6. **Post-check:** zero legacy rows remain, zero legacy jobs remain,
   rule-based rows unchanged.

Order within the release: the retirement migration runs no later than the
first migration that creates rule-based occurrences, and the replacement
API and UI deploy in the **same release** (same SHA), so production never
runs without a working Alerts area. Deletion is irreversible: rolling the
application back afterwards cannot restore legacy records, and an older
frontend against the new schema must fail safely (empty, not erroring).
Production backup availability must be confirmed at production-release
time (the last session record, 2026-11-08, noted no production database
backup; not re-verified in Phase 0).

### Lifecycle (consolidated, rule-based alerts)

1. **Rule created** (enabled by default unless saved disabled; refused
   beyond 25 active rules per site) → audited.
2. **Evaluation** (server-side job) — inside the rule's schedule window
   only, for enabled, non-deleted rules: condition true continuously for
   5 minutes → an **Active** occurrence is created (one Active occurrence
   per rule at a time — existing unique-index pattern).
3. **Acknowledgement** (optional; customer site administrator, customer
   operator, or `GLOBAL` `ADMIN` / `GLOBAL` `OPERATOR` staff) → records
   who/when, stops reminders; occurrence stays **Active**; audited.
4. **Telemetry unavailable** — occurrence stays **Active**, keeps its
   acknowledgement, shows "data unavailable"; evaluation resumes on valid
   data (§4A).
5. **Resolution** — condition confirmed clear, continuously false for 1
   minute on valid data → **Resolved**. Evaluation of an Active occurrence
   continues after its schedule window closes, so it can still resolve
   (§6).
6. **Configuration change** — edit, disable or delete while Active →
   **Ended** (`CONFIGURATION_CHANGED`) in the same audited transaction.
7. **Soft deletion** — the rule disappears from configuration and
   evaluation; its historical occurrences are preserved, immutable.
8. **History and retention** — Resolved/Ended occurrences appear in the
   Resolved/Ended history view for 90 days from their resolved/ended
   time, then are removed by the retention routine; Active occurrences
   are never aged out.

### Equality tolerance

Inspected (2026-11-18): parameter metadata is `metadata.logical_points`
(`name`, `unit_id` → `config.engineering_units.symbol`, `data_type`). All
seeded logical points are `data_type = 'numeric'`, with units including
kW, kWh, kvar, kvarh, kVA, kVAh, V, A, Hz, %, degC, lux, m3, `count` and
`none` (power factor). Stored values are PostgreSQL `NUMERIC`
(`normalized_points.numeric_value`, live-state `numeric_value`); 1-minute
aggregates are `DOUBLE PRECISION`. **No precision, resolution, scale or
decimal-places metadata exists for any parameter or unit**, and the UI
has no per-unit precision table (individual screens hard-code
`toFixed(1)`/`toFixed(2)`).

**Decided (Product Owner, 2026-11-18):** the tolerance is an **absolute
value in the selected parameter's own unit**, stored per rule, required
(≥ 0) when the condition is "equal to", entered explicitly by the rule's
author, and shown next to the target ("equal to 50.0 Hz ± 0.1 Hz").
**There is no default of any kind** — no platform-wide value, no
pre-filled value, no value inferred from display precision; the source
has no precision metadata to support one, and units differ by orders of
magnitude (Hz vs. kWh).

**Cumulative counters excluded from "equal to" initially.** A cumulative
counter is a point whose value only accumulates — the meter energy
registers defined in `config.energy_register_semantics` (counter
direction, rollover/reset behaviour) and `PULSE_COUNT`. For these, "equal
to" is not offered (greater than / less than remain available where the
parameter is offered at all). The exact eligibility source the API uses —
register semantics vs. the Analytics catalogue's category, noting that
catalogue Energy series are interval energy rather than raw registers — is
a Phase 1 implementation detail; the rule itself is decided.

### Remaining items (not reopened product decisions)

*Closed 2026-11-18 by the final Phase 0 approval:* DDS classification
(approved), `GLOBAL` `OPERATOR` (acknowledge on every site, no
configuration), retention of rule-based history (90 days) and the
Resolved/Ended history view (included). Still open — Phase 1 design
items, none of them product decisions:

- **Evaluator data source and "unavailable" definition** — which read
  serves the current value (live-state cache vs. the 1-minute tier) and
  when telemetry counts as unavailable; Phase 1 design, proven by staging
  performance checks.
- **Production path** — `ems_customer_api` and customer-api exist on
  staging only; production serves `/api/v1` from admin-portal as
  `ems_app`. Because the feature and the retirement migration now ship to
  production, every new migration must apply cleanly where that role is
  absent (guarded grants). Production promotion itself is separately
  approved.
- **Cumulative-counter eligibility source** and **reuse vs. replacement
  of `analytics.alerts`** — Phase 1 design (§5, §19).

### Later-phase dependencies (not authorised here)

- Reminder generation and delivery require a delivery channel; when one
  is built, it must honour §10 (stop on acknowledgement, never resolve).
- Email/WhatsApp delivery (`EMS-REQ-084`) needs its own product,
  security (recipient data, consent) and operational decisions.
- Mean-over-window comparison (§12) needs a bounded aggregate read (the
  1-minute tier) and its own performance check.

## Amendment 1 (2026-11-18) — staging refinements D-1 and D-2

Approved by the Product Owner on 2026-11-18 after staging acceptance;
implemented by migration 327. Permissions, lifecycle semantics, audit and
the legacy retirement are unchanged.

- **D-1 — qualification and resolution timing (§4).** The evaluator runs
  once a minute; a run starts a few milliseconds either side of exactly
  60 s after the previous one. The exact test "first observation at least
  5 minutes (1 minute) before this run" therefore missed the intended run
  about half the time, so alerts qualified after 5–6 minutes and resolved
  after 1–2 minutes. The tests now allow a **2-second run-jitter grace**:
  an occurrence qualifies at the first run at least 4 min 58 s after the
  first true observation, and resolves at the first run at least 58 s
  after the first clear observation. The grace is far below the 1-minute
  run interval, so no earlier run can qualify or resolve; recorded
  triggered and resolved times remain the first observation. Gap reset and
  unavailability are unchanged.
- **D-2 — previous occurrences.** An occurrence's "Previous occurrences"
  count and most-recent time now cover **every earlier occurrence of the
  same rule** (its stable rule ID, across all rule versions), within the
  90-day retained history. Editing, disabling, re-enabling or soft-deleting
  a rule no longer resets them. Each occurrence keeps its own rule version
  and configuration snapshot. (Replaces, for rule-based alerts, the MVP-7
  recurrence identity of `EMS-REQ-123`, where any configuration change
  started a new identity.)

## Rationale

Product: customer site administrators are the users who know which
thresholds matter for their own assets; acknowledgement lets a team see
that someone has seen an alert without hiding that the condition
persists. One alert model is simpler for customers than a fixed Energy
Attention alert beside configurable rules, and the legacy alerts were
dominated by artificial daily Ended/re-trigger churn (staging baseline).
Architecture: the same pattern already protects Reports-export writes
(route permission, same-site JSON, SECURITY DEFINER functions re-deriving
scope from the session user) and the Administration App's writes (audited
`admin.*` functions), so customer configuration needs no new security
mechanism — only a dedicated permission and the mandatory audit row.

## Alternatives considered

- **Keep configuration in the Administration App (status quo, Q67)** —
  rejected by the Product Owner: customers configure their own alerts.
- **Keep the Energy Attention alerts beside rule-based alerts** —
  rejected by the Product Owner (§17).
- **Keep legacy records as a read-only history** — rejected by the
  Product Owner: no separate legacy experience, records deleted.
- **Direct frontend writes / a generic write endpoint** — rejected: no
  server-side authorisation or audit, violates ADR-007.
- **Reuse `dashboard.view` for configuration** — rejected: every
  signed-in role holds it, including `VIEWER`.
- **Acknowledgement as a fourth state** — rejected: acknowledgement is not
  resolution; the three-state model stays.

## Consequences

- ADR-006, ADR-007, ADR-010, ADR-016 and ADR-017 carry dated notes
  pointing here; their unrelated decisions are unchanged. ADR-016 is
  superseded as a product; ADR-017's `Alert` concept and job mechanism
  remain.
- `EMS-REQ-082` moves from `BLOCKED` to `READY-FOR-DESIGN`; the
  Attention-generated alert requirements (`EMS-REQ-117`, `-119`, `-126`
  in part) are retired; new requirements `EMS-REQ-140`–`EMS-REQ-152`
  record the rule, acknowledgement, schedule, reminder,
  delivery-placeholder, permission, audit, evaluator-limit,
  telemetry-unavailability and legacy-retirement behaviour.
- The DDS "Alert" concept (ADR-017) changes its source from Attention
  conditions to customer rules; see the change-control note below.
- **Migrations are not staging-only.** The retirement migration is
  explicitly scoped `staging|production|test`; the feature migrations
  ship to production with it and must apply where `ems_customer_api` is
  absent. Production deployment remains separately approved.

### DDS change-control note (Alert Rule)

ADR-017 added `Alert` as the DDS's 11th core concept and defined its
identity as `condition_key` — "stable identity over {parameter/metric,
threshold/reference, scope/context}". A customer-defined rule is the
persisted configuration that produces that identity, so it is treated
here as part of the existing `Alert` concept (its condition definition),
not as a twelfth concept; with the legacy mechanism retired it becomes
the concept's only source. Against the five criteria
([04-architecture/README.md](../../04-architecture/README.md)): (1) a real
requirement not representable today — no table holds a user-defined
condition; (2) not a legacy-compatibility problem; (3) not expressible as
an Asset, Space, Point, Parameter, Relationship or Calculation — it
references an Asset and a Parameter but is neither; (4) simpler
alternatives — hard-coded conditions cannot be customer-configured;
(5) clear lifecycle (create/edit/enable/disable/soft-delete), ownership
(customer site administrators, with WiseWatts `GLOBAL` `ADMIN` staff able
to act on any site), tenant boundary (organisation → site → asset) and
purpose. **Status: APPROVED (2026-11-18)** — alert rules and alert
occurrences remain within the existing `Alert` DDS concept; no twelfth
core concept is added. Confirmed by the user in the final Phase 0
approval, recorded as the architecture decision. The former Phase 1
entry condition is closed.

## Evidence / references

- Product Owner decisions transferred into this session, 2026-11-18
  ("WiseWatts EMS Alerts — Phase 0 Governance Alignment and Staging
  Baseline"; "Final Phase 0 Documentation Alignment" — staff access, audit
  actor type, explicit tolerance, cumulative-counter exclusion, telemetry
  unavailability, 25-rule limit, monitoring; "Final Phase 0 Scope
  Amendment" — complete replacement, legacy retirement and deletion,
  `GLOBAL` `VIEWER` read-only; "Final Phase 0 Approval & Phase 1
  Preparation" — 90-day retention, Resolved/Ended history view, `GLOBAL`
  `OPERATOR` acknowledgement, DDS classification approved), and the
  preceding read-only technical reconnaissance of `origin/staging`
  `8abd023`.
- `admin.portal_user_can_access_site` (baseline migration 001, final
  definition): `GLOBAL` scope → every site; ADR-023 decision 4: `GLOBAL`
  identities are WiseWatts staff.
- Legacy dependency search (2026-11-18): references to `analytics.alerts`,
  `alert_evaluation_candidates`, `evaluate_energy_attention_materiality`,
  `evaluate_alerts`, `run_alert_evaluation_job`, `get_portal_site_alerts`,
  `get_portal_alert_detail`, `AlertSummary`, `getSiteAlerts`,
  `AlertsArea`, `useActiveAlertCount` across `app/`, `web/src/`,
  `postgres/`, `scripts/` (§19).
- `scripts/apply_migrations.sh` (`in_scope`), `postgres/migration_environment_scope.csv`.
- `app/src/routers/report_exports.py` (`_require_exporter`,
  `_require_same_site_json`); `app/src/auth/authorization.py`
  (`PortalPermission`, `ROLE_PERMISSIONS`, `required_permission_for_request`);
  `app/src/auth/customer_middleware.py`; `postgres/migrations/309_report_export_jobs.sql`;
  `postgres/migrations/313_customer_api_role.sql`;
  `postgres/migrations/001_ems_platform_baseline_20260807.sql`
  (`admin.audit_events`, `admin.write_audit_event`,
  `admin.portal_user_has_permission`, `config.portal_role_permissions`);
  `postgres/migrations/238_*`–`242_*`; `postgres/ddl/04_metadata.sql`
  (`metadata.logical_points`); `postgres/ddl/03_01_reference_schema.sql`
  (`config.engineering_units`).
- Staging baseline 2026-11-18 (read-only):
  [alerts/README.md §Staging baseline](../../07-features/alerts/README.md#staging-baseline-2026-11-18).

## Implementation references

- Migrations `postgres/migrations/320_alert_legacy_retirement.sql` …
  `326_alert_customer_api_grants.sql` (PR #179, `e627298`) and
  `327_alert_timing_grace_rule_wide_history.sql` (Amendment 1).
- API `app/src/routers/alerts_api.py`, `app/src/alert_rules_service.py`;
  frontend `web/src/routes/alerts/`.
- Design: [phase-1-technical-design.md](../../07-features/alerts/phase-1-technical-design.md).

## Validation references

- Tests: `app/tests/test_alert_rules_db.py` (incl. D-1 boundary / jitter
  and D-2 lifecycle tests), `app/tests/test_alerts_api_routes.py`,
  `scripts/test/assert_alert_legacy_retirement.sh`,
  `web/src/routes/alerts/AlertsArea.test.tsx`.
- Staging release and acceptance record:
  [alerts/README.md](../../07-features/alerts/README.md) ("Staging release
  record").
