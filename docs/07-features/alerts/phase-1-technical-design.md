# Alerts — Phase 1 technical design (Step 0)

Status: PROPOSED for review · Not implemented · Written 2026-11-18 · Owner: Engineering
Decision record: [ADR-024](../../00-governance/decisions/ADR-024-customer-configurable-alert-rules.md) ·
Plan: [phase-1-implementation-plan.md](phase-1-implementation-plan.md) ·
Requirements: `EMS-REQ-082`, `EMS-REQ-140`–`EMS-REQ-152`
([functional-requirements.md §Alerts](../../02-requirements/functional-requirements.md#alerts))

This document proposes *how* to build ADR-024. It changes no product
decision; where a design choice could look like one, it is listed in §9
for the user's decision. Every fact marked **[V]** was verified in the
repository on `origin/staging` `8abd023` (2026-11-18, read-only); **[I]**
is inferred; nothing here was checked against staging or production.

## 0. Constraints carried from ADR-024 (unchanged)

Permissions (§2): configure = customer site `ADMIN` + `GLOBAL` `ADMIN`;
acknowledge = those + customer `OPERATOR` + `GLOBAL` `OPERATOR`; view =
every authorised site user; `GLOBAL` `VIEWER` read-only. 5-minute
qualification, 1-minute resolution, gap reset (§4). Telemetry gap keeps an
Active alert Active **and acknowledged**; Resolved only when confirmed
clear (§4A). Equal-to needs an explicit tolerance; not for cumulative
counters (§5). Site-timezone schedules; schedule close keeps Active (§6).
Acknowledgement ≠ resolution, stops reminders (§7, §10). Edit/disable/
delete → Ended `CONFIGURATION_CHANGED`; soft delete; 90-day history (§8).
Coming Soon delivery, nothing sent (§9). Three views (§11). Fixed value
first (§12). ≤ 25 active rules per site, bounded set-based monitored
evaluator (§13). Audited same-transaction writes with actor type (§14–§16).
Complete legacy replacement and deletion (§17–§20). DDS: rules and
occurrences within `Alert` (approved).

## 1. Database design

### 1.1 Recommendation: reuse `analytics.alerts` for occurrences; add `analytics.alert_rules`

**`analytics.alert_rules`** (new; one row per rule, soft-deletable)

| Column | Type | Rule |
|---|---|---|
| `rule_id` | UUID PK | `gen_random_uuid()` |
| `organization_id`, `site_id`, `asset_id` | UUID NOT NULL, FKs to `metadata.organizations/sites/assets` | asset must belong to site and organisation (validated in the write function; composite check trigger optional) |
| `name` | TEXT NOT NULL | 1–120 chars, trimmed; unique per site among non-deleted rules (case-insensitive) — §9 Q8 |
| `parameter_code` | TEXT NOT NULL | `config.parameters.code` (the Analytics catalogue's `data_point`) **[V]** |
| `qualifier` | TEXT NULL | `metadata.logical_points.qualifier` (phase/axis), as in the catalogue **[V]** |
| `comparator` | TEXT NOT NULL | `GT` \| `LT` \| `EQ` |
| `comparison_mode` | TEXT NOT NULL DEFAULT `FIXED` | `FIXED` \| `MEAN`; `MEAN` refused by the write function until the mean increment |
| `mean_window` | INTERVAL NULL | required iff `MEAN` (future) |
| `threshold` | NUMERIC NOT NULL | in the parameter's canonical unit |
| `tolerance` | NUMERIC NULL | **required and ≥ 0 iff `EQ`**, NULL otherwise (CHECK) — no default |
| `unit_symbol` | TEXT NULL | snapshot of the unit shown when the rule was saved |
| `schedule_start`, `schedule_end` | TIME NOT NULL | site-local; `start = end` refused; `start > end` = window crossing midnight (§9 Q6) |
| `weekdays` | SMALLINT NOT NULL | ISO-weekday bitmask 1–127 (127 = every day) |
| `reminder_interval` | INTERVAL NULL | stored only; from an enumerated list (§9 Q7) |
| `email_requested`, `whatsapp_requested` | BOOLEAN NOT NULL DEFAULT false | preferences only — no delivery |
| `enabled` | BOOLEAN NOT NULL DEFAULT true | |
| `version` | INTEGER NOT NULL DEFAULT 1 | +1 on every edit and on re-enable (new condition identity) |
| `created_at/by`, `updated_at/by`, `deleted_at/by` | TIMESTAMPTZ / BIGINT FK `admin.portal_users` | `deleted_at` NOT NULL ⇒ `enabled = false` (CHECK) |

Indexes: `(site_id) WHERE deleted_at IS NULL` (rule list);
`(site_id) WHERE enabled AND deleted_at IS NULL` (evaluator, 25-limit
count); unique `(site_id, lower(name)) WHERE deleted_at IS NULL`.

The **25 active rules per site** limit cannot be a plain constraint; the
create/enable functions take `pg_advisory_xact_lock(hashtext('alert_rules:'||site_id))`,
count enabled non-deleted rules and refuse the 26th (`rule_limit_reached`).

**`analytics.alerts`** (existing **[V]**; reused, extended after legacy
rows are deleted — §6):

| Addition | Purpose |
|---|---|
| `rule_id` UUID **NOT NULL** FK `alert_rules` | every occurrence comes from a rule; NOT NULL is possible only because the retirement migration has emptied the table |
| `rule_version` INTEGER NOT NULL | the version that produced it (`condition_key = 'RULE:' || rule_id || ':v' || rule_version`) |
| snapshot: `rule_name`, `parameter_code`, `qualifier`, `parameter_name`, `unit_symbol`, `comparator`, `threshold`, `tolerance`, `asset_name` | immutable history after edits, soft deletion or asset rename (ADR-024 §8) |
| `acknowledged_at` TIMESTAMPTZ, `acknowledged_by` BIGINT FK `admin.portal_users`, `acknowledged_actor_type` TEXT | both-or-none CHECK; set only while ACTIVE (function), retained after resolution |
| `last_value`, `last_value_at` | latest evaluated value for the detail view |
| CHECK `ended_reason_code IN ('CONFIGURATION_CHANGED')` when ENDED | rule alerts never end `DATA_UNAVAILABLE` (§4A) |
| CHECK `condition_key LIKE 'RULE:%'` | guard against legacy-shaped rows |
| unique `(rule_id) WHERE state = 'ACTIVE'` | one Active occurrence per rule (alongside the existing `ux_alerts_one_active_per_condition`) |
| index `(site_id, state, resolved_at)` / `(site_id, state, ended_at)` | history view (existing `ix_alerts_site_state_time` covers Active) |

Existing columns reused as-is **[V]**: `organization_id`, `site_id`,
`asset_id` (now populated), `state` + `ck_alerts_state_fields`,
`triggered_at`, `trigger_value`, `resolved_at/value`, `ended_at`,
`ended_reason`/`ended_reason_code`, `data_unavailable`,
`last_evaluated_at`, retention indexes. `space_id` stays NULL; `metric`
holds `parameter_code`.

**`analytics.alert_evaluation_candidates`** (existing): reused for
qualification/resolution timers, keyed by `(site_id, condition_key)`
**[V]**; legacy rows cleared by §6.

**`analytics.alert_evaluation_runs`** (new, monitoring): one row per run —
`started_at`, `finished_at`, `rules_evaluated`, `unavailable`, `created`,
`resolved`, `error`; pruned after 7 days.

**`admin.migration_outcomes`** (new, small): `migration_id`, `recorded_at`,
`outcome JSONB` — durable record of the retirement counts (§6), because
`admin.write_audit_event` requires a real portal user **[V]**.

### 1.2 Alternatives

| Option | For | Against |
|---|---|---|
| **A. Reuse `analytics.alerts` (recommended)** | Keeps proven state CHECKs, retention indexes and the unique-Active pattern; one occurrence table; read functions keep their names | Inherits `space_id`/`metric`; requires legacy deletion before `rule_id NOT NULL` (which ADR-024 mandates anyway) |
| B. New `analytics.alert_occurrences`, drop `analytics.alerts` later | Clean names/columns | Two occurrence tables during the release; more retirement work (drops, grants, tests); no product benefit |
| Rules in JSON on the occurrence | Fewer tables | No soft delete, no per-rule limit, no audit target — rejected |

### 1.3 Dependencies and risks

`ems_customer_api` (staging/test only **[V]**) must be granted the new
functions with a guard (`IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname =
'ems_customer_api')`), so the same migrations apply on production.
`alert.configure` must be inserted for `ADMIN` in
`config.portal_role_permissions` explicitly (ADMIN's catalogue rows were
seeded once **[V]**) and added to `PortalPermission`.

## 2. Evaluator design

### 2.1 Telemetry source — recommendation: `telemetry.normalized_points`, bounded window

Resolution of a rule to telemetry **[V]**: rule (asset, `parameter_code`,
qualifier) → `metadata.asset_points` binding whose `effective_range`
contains the evaluation instant → `(device_id, logical_point_id)` →
samples in `telemetry.normalized_points` (`event_time`, `numeric_value`,
`quality_code`), converted to the canonical unit with
`analytics.analytics_point_source_scale(device_id, logical_point_id)`
(profile/device field-mapping scale and offset, migration 292).

| Option | For | Against |
|---|---|---|
| **`normalized_points`, last *W* minutes (recommended)** | Canonical store for every commissioned device; sample timestamps support gap detection; same source the 1-minute Analytics read and the later mean increment use; recent chunks uncompressed (compression after 7 days **[V]**); index `(device_id, event_time DESC)` **[V]** | Needs the scale/offset conversion; depends on the ingestion pipeline's latency |
| `telemetry.device_live_point_state` (latest-value cache) | One row per point; already canonical units (migration 025) | Fed by the separate live-telemetry service; only the latest value (no continuity evidence); population on every environment unverified |
| 15-minute / 1-hour tiers | Cheap | Too coarse for 5-min/1-min timers |

Only samples with `quality_code = 'GOOD'` count as valid (`GAP`,
`INVALID_NUMERIC`, `INITIAL` do not) **[V codes in use]**.

### 2.2 "Telemetry unavailable" definition

At evaluation instant *t*, a rule is **UNAVAILABLE** when it has no
current asset-point binding, or no valid sample with
`t − W < event_time ≤ t`. Recommended *W* = **5 minutes** (§9 Q2): long
enough to tolerate ingestion latency and 1–2 missed reports, short
relative to the 5-minute qualification. To be validated in Step 1 by a
read-only measurement of per-device reporting intervals on staging.

Behaviour (ADR-024 §4A): UNAVAILABLE while qualifying → candidate reset;
UNAVAILABLE while Active → occurrence stays ACTIVE, `data_unavailable =
true`, acknowledgement untouched, any resolution timer reset; valid data
again → `data_unavailable = false`, evaluation continues on the **same**
occurrence. Never Ended `DATA_UNAVAILABLE`.

### 2.3 Cumulative-counter identification

A parameter is a **cumulative counter** for a rule when any device bound
to (asset, parameter, qualifier) has an active
`config.energy_register_semantics` row for that logical point **[V]**, or
the logical point is `PULSE_COUNT` **[V]**. Exposed as an
`equal_allowed` flag by the parameters endpoint and re-checked by the
write function. Alternative (catalogue category) rejected: categories
describe meaning, not accumulation. Whether greater/less on raw registers
should be offered at all is §9 Q3.

### 2.4 Set-based evaluation (one statement pipeline per run)

Every minute, under `pg_try_advisory_lock` (skip if a run is still going):

1. **rules** — enabled, non-deleted rules joined to `metadata.sites.timezone`;
   `in_schedule` = local time of *t* within `[schedule_start,
   schedule_end)` (wrapping past midnight) and ISO weekday bit set.
2. **binding** — current `asset_points` row per rule (latest
   `effective_from`).
3. **sample** — `LATERAL (… WHERE device_id = b.device_id AND
   logical_point_id = b.logical_point_id AND event_time > t − W AND
   event_time <= t AND quality_code = 'GOOD' ORDER BY event_time DESC
   LIMIT 1)`, scaled.
4. **observation** — `UNAVAILABLE` / `TRUE` / `FALSE` (`GT`: v > threshold;
   `LT`: v < threshold; `EQ`: |v − threshold| ≤ tolerance).
5. **transitions** — data-modifying CTEs or a few set statements:
   qualification candidates (start / continue / reset on FALSE,
   UNAVAILABLE, out-of-schedule or a run gap > 3 minutes); create ACTIVE
   occurrences after 5 continuous minutes (`triggered_at` = candidate
   start, snapshot columns filled); resolution candidates for ACTIVE
   occurrences (FALSE on valid data, reset on TRUE/UNAVAILABLE/gap);
   Resolved after 1 continuous minute; `data_unavailable` flag refresh;
   `last_value`.
6. **run log** — one `alert_evaluation_runs` row.

Retention (once per hour inside the same job): delete Resolved/Ended
occurrences older than 90 days, candidates of deleted/disabled rules, and
run rows older than 7 days.

Observation grain: the latest valid sample per run (as MVP-7 did). A
sub-minute excursion between runs can be missed; checking every sample in
the minute is a later refinement if needed.

Configuration changes are **not** handled by the evaluator: the write
functions end the Active occurrence and clear its candidates in the same
audited transaction (ADR-024 §8, §16).

### 2.5 Scheduling, budget, monitoring

- New TimescaleDB job `analytics.run_alert_rule_evaluation_job`, 1-minute
  schedule, `max_runtime` 50 s, registered by a `postgres/jobs/` file and
  verified by `scripts/verify/verify_jobs.sh` (ADR-017 pattern) **[V]**.
- Budget (proposed): p95 run ≤ 2 s and ≤ 50 MB work memory at 25 rules ×
  every staging site; `SET LOCAL statement_timeout = '30s'`. Measured on
  staging with `EXPLAIN` (no `ANALYZE` first) before merge — the host has
  745 MiB available of 1,905 (Phase 0 baseline).
- Monitoring: `verify_jobs.sh` checks registration, schedule, last success
  < 3 minutes ago and no recent errors; `alert_evaluation_runs` gives
  duration and counts; the legacy job must be **absent**.

### 2.6 Unresolved / risks

*W* value (Q2); counter policy (Q3); per-sample vs. per-run grain
(recommend per-run); ingestion latency on production unknown; scale
lookup per rule must be folded into the statement (not per-row calls).

## 3. API design

All routes under `/api/v1`, in a new router mounted in both
`src.main` and `src.customer_main` (like the Analytics router **[V]**).
Every route resolves the actor from the session; site/asset/rule/alert
access is re-derived in the database; inaccessible = 404.

### 3.1 Endpoints

| Method + path | Permission (route **and** DB) | Purpose |
|---|---|---|
| `GET /sites/{site_id}/alerts?state=ACTIVE\|RESOLVED\|ENDED&from&to&before&limit` | `dashboard.view` + site access | Active list and Resolved/Ended history (replaces the MVP-7 contract) |
| `GET /alerts/{alert_id}` | `dashboard.view` + site access | Detail |
| `GET /sites/{site_id}/alert-rules` | `dashboard.view` + site access | Rule list (non-deleted) |
| `GET /alert-rules/{rule_id}` | `dashboard.view` + site access | One rule |
| `GET /sites/{site_id}/alert-rules/parameters?asset_id=` | `dashboard.view` + site access | Parameters available for an asset: code, name, qualifier, unit, `equal_allowed` |
| `POST /sites/{site_id}/alert-rules` | `alert.configure` | Create (201) |
| `PATCH /alert-rules/{rule_id}` | `alert.configure` | Edit; body carries `version` (409 `version_conflict` on mismatch) |
| `POST /alert-rules/{rule_id}/enable`, `/disable` | `alert.configure` | Toggle (idempotent) |
| `DELETE /alert-rules/{rule_id}` | `alert.configure` | Soft delete (204) |
| `POST /alerts/{alert_id}/acknowledge` | `alert.acknowledge` | Acknowledge an Active alert |

`required_permission_for_request` names each write path/method explicitly
(today `/api/v1/*` → `dashboard.view` for every method **[V]**).
Writes require `application/json` (except `DELETE`, which has no body) and
reject `Sec-Fetch-Site: cross-site` (`_require_same_site_json` **[V]**),
on top of the middleware's same-origin check for unsafe methods **[V]**.

### 3.2 Contracts (sketch)

- **Rule:** `rule_id`, `site_id`, `name`, `asset {asset_id, name}`,
  `parameter {code, name, qualifier, unit}`, `condition {comparator,
  threshold, tolerance, comparison_mode}`, `schedule {start_time, end_time,
  weekdays[], timezone}`, `reminder {interval_minutes}`,
  `delivery {email {requested, status: "COMING_SOON"}, whatsapp {…}}`,
  `enabled`, `version`, `created_at`, `updated_at`.
- **Alert:** `alert_id`, `rule_id`, `rule_name`, `state`, `asset`,
  `parameter`, `condition` (snapshot), `triggered_at`, `trigger_value`,
  `last_value`, `last_value_at`, `data_unavailable`, `resolved_at/value`,
  `ended_at`, `ended_reason_code`, `acknowledgement {acknowledged_at,
  acknowledged_by {display_name, actor_type}} | null`,
  `previous_occurrence_count`, `most_recent_previous_triggered_at`.
- Delivery `status` is always `COMING_SOON`; no field implies sending.

### 3.3 Validation (422 unless noted, flat `{error, detail}` envelope **[V]**)

`invalid_name`, `name_taken` (409), `asset_not_found` (404),
`parameter_not_available`, `invalid_comparator`, `tolerance_required`,
`tolerance_not_allowed`, `equal_not_allowed_for_counter`,
`mean_not_available`, `invalid_threshold`, `invalid_schedule`,
`invalid_weekdays`, `invalid_reminder`, `rule_limit_reached` (409),
`version_conflict` (409), `alert_not_active` (409),
`already_acknowledged` (409), `forbidden` (403 — permission missing on an
accessible site), `unsupported_media_type` (415).

### 3.4 Role matrix (enforced, tested)

| Role / scope | GET | Acknowledge | Configure |
|---|---|---|---|
| Customer `ADMIN` (ORGANIZATION / SELECTED_SITES) | own sites | yes | yes |
| Customer `OPERATOR` | own sites | yes | 403 |
| Customer `VIEWER` | own sites | 403 | 403 |
| `GLOBAL` `ADMIN` | all sites | yes | yes |
| `GLOBAL` `OPERATOR` | all sites | yes | 403 |
| `GLOBAL` `VIEWER` | all sites | 403 | 403 |

### 3.5 Alternatives / trade-offs

`PATCH {enabled}` instead of enable/disable endpoints — rejected: separate
audit actions and idempotency are clearer. Hard 404 for every refusal —
rejected for permission-only refusals on an accessible site (403 is the
existing Reports pattern **[V]**).

## 4. Audit design

- Every successful create, edit, enable, disable, delete and acknowledge
  calls `admin.write_audit_event(...)` **[V signature]** inside the same
  SECURITY DEFINER function and transaction. Actions:
  `ALERT_RULE_CREATED`, `ALERT_RULE_UPDATED`, `ALERT_RULE_ENABLED`,
  `ALERT_RULE_DISABLED`, `ALERT_RULE_DELETED`, `ALERT_ACKNOWLEDGED`;
  entity types `ALERT_RULE`, `ALERT`. `previous_values`/`new_values`
  carry the changed rule fields; a rule change that ends an Active
  occurrence lists the ended `alert_id`s in `new_values`.
- `actor_portal_user_id` is the signed-in user; `actor_role` is derived by
  the function from `admin.portal_users` **[V]**.
- **Actor type — recommendation:** add `admin.audit_events.actor_type`
  (`CUSTOMER` \| `WISEWATTS_STAFF`, NULL for historic rows) and have
  `admin.write_audit_event` derive it from
  `admin.portal_users.access_scope_mode` (`GLOBAL` → staff) for **every**
  new event (same signature, so all existing callers keep working).
  Alternative: an alert-only key in `new_values` — not enforceable or
  queryable consistently. §9 Q5.
- **Refusals:** a permission refusal on an accessible site writes a
  `REJECTED` audit row (the function returns a status instead of raising,
  so the row commits); not-found/inaccessible cases are not audited (no
  existence leak). Validation errors are not audited.
- Display: the acknowledger is shown to customers by display name; how a
  staff acknowledger is shown is §9 Q4.

## 5. Frontend design

- `/features/alerts` keeps its route and nav entries **[V]**;
  `AlertsArea.tsx` is replaced by an Alerts page with three tabs —
  **Active Alerts** (default), **Create Alert** (rules) and
  **History** (Resolved/Ended) — selected by `?tab=`.
- **Active Alerts:** table Name, Asset, Status (Active / Active —
  data unavailable), Acknowledge (button, or "Acknowledged by … at …");
  row opens a detail panel (triggered time, condition, asset, parameter,
  threshold/value, latest value, status, acknowledgement).
- **History:** Resolved/Ended within 90 days, state filter and date range,
  "Load more" (cursor), same detail plus resolved/ended time and reason;
  occurrences of deleted rules shown with their recorded name.
- **Create Alert:** rule table (Name, Asset, Parameter, Value/condition,
  enabled switch `role="switch"`, Edit, Delete with an in-page confirm
  dialog) and Create New Alert. Form: asset (catalogue assets) →
  parameter (parameters endpoint) → condition (Equal to hidden when
  `equal_allowed` is false; tolerance field required for Equal to) →
  threshold with unit → schedule (start/end time, Every day or weekday
  checkboxes, site timezone shown) → reminder frequency → Email and
  WhatsApp checkboxes with a **Coming Soon** badge and "Not sent yet" help
  text. Server errors map to field messages.
- **Permissions (UX only):** controls rendered from `/api/v1/me`
  permissions **[V]** — `alert.configure` shows Create/Edit/Delete/toggle;
  `alert.acknowledge` shows Acknowledge; otherwise read-only.
- **Times:** `formatInTimeZone(…, site.timezone)` **[V helper]** (the MVP-7
  page used browser locale **[V]**).
- **Refresh:** Active list and header badge (`useActiveAlertCount`,
  reused **[V]**) refresh every 60 s and after any write.
- **Customer/staff integration:** one SPA. Staff use it on the customer
  host where `EMS_CUSTOMER_ALLOW_STAFF` is on (ADR-023 Amendment 3);
  production serves the bundle through admin-portal until ADR-023
  stage 5. The Administration App gains no alert screen.
- Removed: `energyAttentionConditionKey`, `conditionLabel`,
  `ENDED_REASON_LABELS` for `DATA_UNAVAILABLE`, the legacy `Alert` type.

## 6. Legacy retirement migration

Numbered **first** in the release (so `rule_id NOT NULL` can follow) and
listed `staging|production|test` in
`postgres/migration_environment_scope.csv`.

1. `SET LOCAL lock_timeout = '30s'`; create `admin.migration_outcomes` if
   absent.
2. **Classify:** count `analytics.alerts` / `alert_evaluation_candidates`
   by state. Legacy = `condition_key LIKE 'ENERGY_ATTENTION:%' AND metric
   = 'ENERGY_CONSUMPTION' AND asset_id IS NULL AND space_id IS NULL`
   (candidates: `condition_key LIKE 'ENERGY_ATTENTION:%'`). **Any other
   row → RAISE and abort** (nothing changed).
3. **Retire the evaluator:** `delete_job()` for every job with
   `proc_schema = 'analytics' AND proc_name = 'run_alert_evaluation_job'`
   (zero is fine; ids recorded); `LOCK TABLE analytics.alerts,
   analytics.alert_evaluation_candidates IN ACCESS EXCLUSIVE MODE` (waits
   for an in-flight run); `DROP PROCEDURE IF EXISTS
   analytics.run_alert_evaluation_job(integer, jsonb),
   analytics.evaluate_alerts()`; `DROP FUNCTION IF EXISTS
   analytics.evaluate_energy_attention_materiality(uuid, timestamptz)`.
4. **Delete legacy only:** candidates, then alerts, with the predicate.
5. **Post-check:** zero rows of any kind remain (the table held only
   legacy rows); zero legacy jobs.
6. **Record:** `admin.migration_outcomes` row with per-table, per-state
   before/deleted counts and removed job ids; `RAISE NOTICE` the same for
   the deployment log; copy into the environment's release record.

The next migration adds `rule_id NOT NULL`, the `RULE:%` CHECK and the
`CONFIGURATION_CHANGED`-only CHECK — the guard against reappearance.
Repository: delete `postgres/jobs/238_alert_evaluation_job.sql`; update
`verify_jobs.sh` (legacy job must be absent); retire legacy tests with the
objects (`test_alert_*`, `test_mvp7_*`, `assert_mvp7_alert_*`, alert cases
in `test_customer_api.py` / `test_pipeline_five_minute_batch_schedule.py`,
`test_customer_api_role_db.py`'s function list) **[V files]**.

Idempotency: the ledger prevents re-runs; the body is also safe to re-run
(`IF EXISTS`, zero-row deletes). Safety: abort-on-unknown, legacy-only
predicate, lock timeout, single transaction (all or nothing).

**Irreversible.** Production backup must be confirmed before promotion
(the last record, 2026-11-08, noted none — unverified now).

## 7. Testing and rollout

| Level | What | Pass criteria |
|---|---|---|
| Unit (pytest, Vitest) | request validation, contracts, permission helpers, form logic, Coming Soon rendering | all green; no weakened legacy test |
| DB integration (disposable DB) | write functions × §3.4 matrix; audit row per write with actor type; 25-limit under concurrency; soft delete; config-change ending; evaluator live runs (qualify 5 min, resolve 1 min, gap resets, schedule close, telemetry gap keeps Active + acknowledgement, EQ tolerance, 90-day retention); retirement migration on seeded legacy + unknown rows | every case asserted; unknown row aborts with no change |
| Security | cross-site POST (403), non-JSON (415), other tenant's rule/alert ids (404), VIEWER/OPERATOR writes (403), staff actor type recorded, no `ems_customer_api` grant beyond the new functions | all refused as specified |
| Performance (staging, read-only) | `EXPLAIN` of the evaluator statement and history read at 25 rules × staging sites | within §2.5 budget |
| Staging acceptance (after the release deploys; rule creation on staging needs explicit authorisation) | retirement counts recorded; real rule qualifies, is acknowledged, survives a gap, resolves, appears in History; audit rows; `verify_jobs.sh` | all observed; no job errors |

**Release dependencies:** retirement, schema, functions, API and frontend
must land on `staging` as **one** deployable change — every push to
`staging` deploys immediately **[V]** — see §9 Q1. Production then
promotes that SHA (staging-milestone mode **[V]**) on separate approval.

**Production prerequisites:** backup confirmed (or explicitly waived by
the user); read-only precheck of legacy counts and whether the legacy job
exists; guarded `ems_customer_api` grants verified to no-op; frontend
delivery path (admin-portal bundle) confirmed; `EMS_CUSTOMER_ALLOW_STAFF`
state known; release record template with deletion counts.

## 8. Proposed migration sequence (numbers from 320, re-check at branch time)

| # | Migration | Scope |
|---|---|---|
| 320 | Legacy retirement + `admin.migration_outcomes` (§6) | `staging\|production\|test` (explicit) |
| 321 | `alert_rules`, `alerts` extensions and guards, `alert.configure` + ADMIN grant | all |
| 322 | `audit_events.actor_type` + `write_audit_event` derivation | all |
| 323 | Write functions (rules, acknowledge) with audit | all |
| 324 | Read functions (alerts, history, rules, parameters) replacing `get_portal_site_alerts` / `get_portal_alert_detail` | all |
| 325 | Evaluator procedure, run log, retention; job file | all |
| 326 | Guarded `ems_customer_api` grants | all (no-op where the role is absent) |

## 9. Questions for the user's decision

| # | Question | Recommendation |
|---|---|---|
| Q1 | Staging merge strategy, given every `staging` push deploys | One integration branch (`feature/alerts-rules`), reviewed as stacked PRs, merged to `staging` once |
| Q2 | Telemetry-unavailable window *W* | 5 minutes, validated by a read-only staging measurement in Step 1 |
| Q3 | Greater/less on raw cumulative registers (energy registers, pulse counts) | Exclude cumulative counters from rule parameters entirely in the first release (thresholds on a register that only grows are not meaningful); revisit with interval energy |
| Q4 | How a staff acknowledger is shown to customers | "WiseWatts Support (name)" |
| Q5 | Actor type for **all** audit events (shared function) vs. alerts only | All events, derived in `write_audit_event` |
| Q6 | Schedules crossing midnight (e.g. 22:00–06:00) | Allow |
| Q7 | Reminder frequency options (stored only) | None, 15 min, 30 min, 1 h, 4 h, 24 h |
| Q8 | Rule name uniqueness | Unique per site among non-deleted rules, case-insensitive |

## 10. Key risks

| Risk | Mitigation |
|---|---|
| Irreversible deletion; production backup status unknown | Abort-on-unknown classification; legacy-only predicate; single transaction; recorded counts; backup confirmed before promotion |
| Staging capacity (1.9 GB; 745 MiB available) | Set-based single pipeline, advisory-lock skip, 25-rule limit, statement timeout, `EXPLAIN` before merge, run log |
| Production DB permissions (`ems_customer_api` absent; `ems_app` serves `/api/v1`) | Guarded grants; functions granted to `ems_app`; production precheck |
| Partial deployment to staging (auto-deploy) | Q1 — single merge |
| Recreated read functions lose grants | Re-grant in the same migration; role tests |
| Shared audit-function change affects every admin workflow | Same signature; derived column nullable; existing audit tests rerun |
| Ingestion latency makes alerts flap UNAVAILABLE | *W* validated on staging; `data_unavailable` never ends or resolves |
