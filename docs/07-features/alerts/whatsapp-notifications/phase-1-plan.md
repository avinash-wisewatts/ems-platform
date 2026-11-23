# WhatsApp notifications — Phase 1 plan: staging-only configuration

Status: **PLAN — not authorised.** Implementing, merging or deploying any of
this needs separate, explicit authorisation. Phase 1 **sends no messages**.
Decisions: [README.md §2](README.md#2-confirmed-decisions-product-owner-2026-11-23)
(D1–D13). Architecture: [ADR-026](../../../00-governance/decisions/ADR-026-whatsapp-alert-notifications.md)
(Proposed). Basis: `origin/staging` `458c179`. Prepared 2026-11-23.

## 1. Scope

Phase 1 delivers, on **staging only**:

1. Saving and retrieving each alert rule's WhatsApp settings (on/off) and
   its recipient phone numbers.
2. Server-side authorisation (tenant, site, role) and an audit row for
   every configuration and consent change.
3. Validation: E.164 numbers, no duplicates per rule, a recipient cap, and
   at least one consented recipient before WhatsApp can be on.
4. Consent capture: an explicit administrator opt-in confirmation per
   number, recording who confirmed it and when.
5. Tests proving that WhatsApp configuration changes do not affect:
   - occurrence state;
   - trigger and resolution timers;
   - rule versions;
   - existing notification behaviour (in-product only, with Email still
     "Coming Soon").

## 2. The three concepts

| Concept | Owner tables / functions | Phase 1 effect |
|---|---|---|
| 1. **Alert definition and operational lifecycle** | `analytics.alert_rules`, `analytics.alerts`, `analytics.alert_evaluation_candidates`; `evaluate_alert_rules` and the migration 323 write functions | **Behaviour unchanged.** Three small adjustments only: `whatsapp_requested` is neutralised (§3.3), and soft delete also removes the WhatsApp configuration (§3.4). `evaluate_alert_rules` is not modified. |
| 2. **WhatsApp notification configuration** | New `analytics.alert_rule_whatsapp_settings` and `analytics.alert_rule_whatsapp_recipients`, plus new functions | **New.** Keyed by the stable `rule_id`, so it survives rule edits and version bumps. Never read by the evaluator. |
| 3. **WhatsApp delivery records** | Proposed Phase 2 `analytics.alert_whatsapp_deliveries` (and outbox) | **Not created in Phase 1.** No table, function, worker or endpoint. |

Nothing in concept 2 is referenced by concept 1, so a WhatsApp save cannot
reach occurrence state by construction. The tests in §7 prove it.

## 3. Proposed data model: migration 331 (staging|test only)

Scoped `staging|test` in `postgres/migration_environment_scope.csv`, because
production waits for ADR-024 (D11). Registered in the restructure manifest
and in the scope-objects CSV, with LF line endings.

### 3.1 `analytics.alert_rule_whatsapp_settings`: one row per rule that has ever been configured

| Column | Type | Notes |
|---|---|---|
| `rule_id` | UUID PK, FK → `alert_rules(rule_id)` | Stable rule identity (not the version). |
| `organization_id`, `site_id` | UUID NOT NULL | Copied from the rule for scoping and audit; a CHECK trigger keeps them equal to the rule's. |
| `enabled` | BOOLEAN NOT NULL DEFAULT FALSE | D5. |
| `revision` | INTEGER NOT NULL DEFAULT 1 | Optimistic concurrency: stale saves are refused. |
| `created_at`, `created_by`, `updated_at`, `updated_by` | | `*_by` → `admin.portal_users`. |

No row means WhatsApp is off. That is the state of every existing rule (D5).

### 3.2 `analytics.alert_rule_whatsapp_recipients`

| Column | Type | Notes |
|---|---|---|
| `recipient_id` | UUID PK | |
| `rule_id` | UUID NOT NULL FK → settings | |
| `phone_e164` | TEXT NOT NULL | CHECK `^\+[1-9][0-9]{7,14}$`; UNIQUE (`rule_id`, `phone_e164`). |
| `consent_state` | TEXT NOT NULL | CHECK IN (`CONFIRMED`, `OPTED_OUT`). Phase 1 writes only `CONFIRMED`; `OPTED_OUT` is reserved for Phase 2 STOP handling (D4). |
| `consent_confirmed_at`, `consent_confirmed_by` | TIMESTAMPTZ, BIGINT NOT NULL | The administrator who confirmed opt-in (D4). |
| `consent_statement_version` | TEXT NOT NULL | Which wording of the confirmation statement was shown (wording owned by Product, D8). |
| `opted_out_at`, `opted_out_source` | NULL in Phase 1 | Phase 2. |
| `created_at`, `created_by` | | |

There is no verification column (no OTP, D4) and no name or label column
(data minimisation). Removing a recipient deletes the row (A-3). A count
cap per rule is enforced in the save function (README Q-2; proposed 10).

Both tables: owner `ems_admin`, all privileges revoked from PUBLIC,
`ems_app` and `ems_customer_api`. Access is only through the functions in
§3.5. The postconditions assert this.

### 3.3 Neutralising the "Coming Soon" WhatsApp flag (D5, D6)

`AlertRuleIn.delivery.whatsapp` defaults to `false`, and
`update_portal_alert_rule` treats a change to `whatsapp_requested` as a
configuration change, which ends the Active occurrence. If the rule form
stops sending the old checkbox, a rule saved with it ticked would end its
alert. So migration 331:
- **Precondition:** it aborts if any `alert_rules` row has
  `whatsapp_requested = true`. Staging, read-only, 2026-11-23: 13 rows, 0
  true (1 has Email requested, which is untouched).
- **Constraint:** it adds a CHECK (`NOT whatsapp_requested`). The column is
  kept for rollback compatibility, and the column comment marks it
  retired.
- **Functions:** it re-creates `create_portal_alert_rule` and
  `update_portal_alert_rule` with the same signatures. They store `false`
  whatever `p_whatsapp_requested` says, and drop it from the "anything
  changed?" comparison. Every other field still ends the Active occurrence
  exactly as today (ADR-024 §8).
- **API:** `delivery.whatsapp` in rule requests is accepted for older
  clients but ignored. Rule responses keep
  `delivery.whatsapp = {requested: false, status: "COMING_SOON"}`, so a web
  build deployed separately keeps working, and gain a separate summary
  `whatsapp: {enabled, recipient_count}`. The full numbers never appear in
  rule responses.

### 3.4 Soft delete (A-5)

`delete_portal_alert_rule` is re-created, with the same signature, to also
delete the rule's WhatsApp settings and recipients in the same transaction.
Its audit row records the masked numbers removed. Occurrence handling is
unchanged.

### 3.5 Functions (SECURITY DEFINER, owner `ems_admin`, `search_path` pinned)

| Function | Rule |
|---|---|
| `analytics.alert_phone_mask(TEXT)` → TEXT | Country code plus the last 4 digits, e.g. `+91 ••••••3210`. IMMUTABLE. Used by audit and summaries. |
| `analytics.get_portal_alert_rule_whatsapp(p_portal_user_id, p_rule_id)` | Returns settings and recipients with full numbers. Requires `alert.configure` (`admin.portal_user_has_permission`) and site access. An inaccessible, unknown or soft-deleted rule raises `not_found`, the same as a missing one (ADR-007). Without `alert.configure` it raises `forbidden`; Operators and Viewers never receive numbers (D9). |
| `analytics.save_portal_alert_rule_whatsapp(p_portal_user_id, p_rule_id, p_enabled, p_recipients JSONB, p_expected_revision)` | Replace-all save, as PRD §6.3 describes. Same permission and site checks. See the details below this table. |
| `analytics.get_portal_alert_rule_whatsapp_summaries(p_portal_user_id, p_site_id)` | Per rule: `enabled` and `recipient_count`; no numbers. Requires site access (any role), feeding the rule-list badge. |

**`save_portal_alert_rule_whatsapp` in detail:**
- **Locking and concurrency:** locks the settings row and refuses a stale
  `p_expected_revision`.
- **Validation:** E.164 format, duplicates, the cap, and enabled requiring
  at least one CONFIRMED recipient.
- **Consent:** a recipient that keeps its `recipient_id` and number keeps
  its consent. A new or changed number needs `opt_in_confirmed = true`; the
  function then records the confirmer, the time and the statement version
  (A-2). Removed recipients are deleted.
- **Audit:** writes **one** `admin.audit_events` row in the same
  transaction: action `ALERT_RULE_WHATSAPP_UPDATED`, entity
  `ALERT_RULE_WHATSAPP`, with the actor type derived server-side. Previous
  and new values hold `enabled` and masked recipients with their consent
  metadata, plus the lists of added, removed and consent-confirmed
  recipient ids. No full numbers are written (A-4).
- **A no-op save** writes nothing.
- **What it never touches:** `alert_rules`, `alerts` or
  `alert_evaluation_candidates`.

**Refusal codes**, mapped by the API: `whatsapp_invalid_phone`,
`whatsapp_duplicate_phone`, `whatsapp_too_many_recipients`,
`whatsapp_recipients_required`, `whatsapp_consent_required`,
`whatsapp_config_stale`, `not_found`, `forbidden`.

**Grants:** the get, save and summaries functions to `ems_app` and, guarded,
to `ems_customer_api` (migration 313 pattern). The postconditions assert:
- the customer API's executable function set is exactly the previous set
  plus these three;
- the tables are not readable directly;
- no new function is executable by PUBLIC.

## 4. Proposed API (customer API, `/api/v1`, ADR-024 §14 pattern)

| Method and path | Permission | Behaviour |
|---|---|---|
| `GET /alert-rules/{rule_id}/whatsapp` | `alert.configure` + site access | `{enabled, revision, messages_active: false, recipients: [{recipient_id, phone_e164, phone_masked, consent: {state, confirmed_at, confirmed_by_name}}]}`. 403 without the permission, 404 when not found or not accessible. |
| `PUT /alert-rules/{rule_id}/whatsapp` | `alert.configure` + site access | Same-origin JSON only (415 / 403, `_same_origin_json`). Body: `{enabled, revision, recipients: [{recipient_id?, phone, opt_in_confirmed}]}`. Returns the GET body. 422 with `{error, detail}` for the refusal codes; 409 for a stale revision. |
| Existing rule responses (`GET /sites/{id}/alert-rules`, `GET /alert-rules/{id}`) | unchanged | Gain `whatsapp: {enabled, recipient_count}` from the summaries function; `delivery.whatsapp` is kept as `COMING_SOON` (§3.3). |

`messages_active: false` is fixed in Phase 1, so the UI can never imply that
sending is live.

`required_permission_for_request` names the PUT path explicitly
(`alert.configure`) instead of relying on the blanket `/api/v1/*` →
`dashboard.view` mapping. The GET path is also checked in the route and in
the database. Phone parsing uses a pinned library (proposed
`phonenumbers`, a new dependency recorded in `app/requirements.txt`), and
the database CHECK is the backstop.

## 5. Proposed UI (EMS → Alerts, staging only)

- **Rule form (edit an existing rule):** a separate **WhatsApp
  notifications** panel with its own **Save WhatsApp settings** button.
  It is a different concept from the rule, so saving it never saves or
  changes the rule. A new rule must be saved before WhatsApp can be
  configured.
- **Panel contents:**
  - an "Enable WhatsApp notifications" checkbox, off by default;
  - the recipient list, hidden while unchecked;
  - "+ Add phone number": country-code input plus number, with errors shown
    next to the field;
  - Edit and Remove buttons per row;
  - for each new or changed number, a required checkbox: "I confirm this
    person has agreed to receive WiseWatts alert messages on WhatsApp"
    (wording to be supplied by Product, D8);
  - an unsaved-changes indicator, and a success or error message;
  - a fixed notice: **"WhatsApp messages are not sent yet."**
- **Coming Soon block:** the old WhatsApp checkbox is removed (Q-7). Email
  stays "Coming Soon", and the reminder text stays "not sent".
- **Rule list:** a "WhatsApp · N" badge where enabled (from the summaries).
  No numbers are shown.
- **Who sees the panel:** only users with `alert.configure`, consistent
  with today's rule form.

## 6. Phase 1 acceptance criteria

| ID | Criterion |
|---|---|
| P1-AC-1 | A customer site `ADMIN` can open a rule on an authorised site, enable WhatsApp, add several valid numbers with opt-in confirmed, and save. The configuration is returned unchanged on reload. |
| P1-AC-2 | Each rule's configuration is independent: saving rule A never changes rule B. |
| P1-AC-3 | A `GLOBAL` `ADMIN` can configure rules on any site. |
| P1-AC-4 | A customer `ADMIN` gets 404 for another organisation's or an unauthorised site's rule (read and save). Operators, Viewers, `GLOBAL` `OPERATOR` and `GLOBAL` `VIEWER` get 403 on GET/PUT and never receive a number in any response. |
| P1-AC-5 | The save is refused, and the stored configuration left exactly as before, when the input has: an invalid number, a duplicate, too many recipients, enabled with no recipient, a new or changed number without opt-in confirmation, or a stale revision. |
| P1-AC-6 | Every effective save writes exactly one audit row in the same transaction: the actual actor, customer or staff actor type, masked numbers only, and consent who/when. A refused or no-op save writes none. |
| P1-AC-7 | Saving WhatsApp settings while the rule has an Active occurrence leaves the occurrence, the rule and the timers exactly as they were. The occurrence keeps its state, triggered time, acknowledgement, `condition_key` and `rule_version`; the rule keeps its version; candidate rows are unchanged. The next evaluator run behaves exactly as for a control rule. |
| P1-AC-8 | Saving while the rule is still qualifying (condition true for less than 5 minutes) does not reset the qualification: the occurrence becomes Active at the same run as a control rule. The same holds during the 1-minute resolution window. |
| P1-AC-9 | A rule edit that sends `delivery.whatsapp` in either state never ends an Active occurrence. Editing any operational field still ends it as today (`CONFIGURATION_CHANGED`). |
| P1-AC-10 | No message is sent, and nothing exists that could send one: no outbox or delivery table, no worker, no outbound call, no callback route. `messages_active` is always false, and the UI shows "messages are not sent yet". In-product alerts, the header count and Email "Coming Soon" behave exactly as before. |
| P1-AC-11 | Every existing rule starts with WhatsApp off. Migration 331 refuses to run if any `whatsapp_requested` is true. |
| P1-AC-12 | Soft-deleting a rule deletes its WhatsApp settings and recipients, audited with masked numbers; its occurrences are preserved as today. |
| P1-AC-13 | Grants match §3.5 exactly, and the tables are not directly readable by the application roles. The migration applies on a fresh test database and is idempotent, and its rollback script restores the migration 323 definitions of the create, update and delete functions. |

## 7. Test plan

**Database tests** (`app/tests/test_alert_whatsapp_config_db.py`, test DB,
the `test_alert_rules_db.py` fixtures):
- **Save and read:** a round trip; replace-all semantics; revision bump
  and stale refusal; no-op save.
- **Validation:** E.164 format; a duplicate after normalisation; the cap;
  enabled with no consented recipient; a new number without consent; a
  changed number needing fresh consent; an unchanged number keeping its
  consent (A-2).
- **Permissions:** customer `ADMIN` own site / other organisation / an
  unselected site; `OPERATOR`; `VIEWER`; the `GLOBAL` roles; an
  inactive user; a soft-deleted rule. Read and save for each.
- **Audit:** one row per effective save; masked values only (asserts no
  full number appears in `previous_values` or `new_values`); actor type
  customer vs staff; no row on a refusal; rollback atomicity (a forced
  failure after the audit leaves both unchanged).
- **Lifecycle isolation (P1-AC-7/8/9):**
  - set up an Active occurrence, a qualifying candidate and a resolving
    candidate;
  - snapshot `alerts`, `alert_evaluation_candidates` and `alert_rules`;
  - save WhatsApp settings several times;
  - assert the snapshots are equal;
  - run `evaluate_alert_rules(t)` at fixed instants beside a control rule
    without WhatsApp, and assert identical transitions and times.
- **Rule edits:** an update with `p_whatsapp_requested = true` and `false`
  never ends the occurrence; a threshold edit still ends it.
- **Migration 331:** the precondition refuses a seeded `true` flag; the
  CHECK is present; soft delete removes the configuration; the grant
  postconditions hold; idempotent re-apply; the rollback.

**API route tests** (`app/tests/test_alerts_whatsapp_routes.py`):
- 200/403/404/409/415/422 mappings; the cross-site Origin refusal;
  non-JSON refusal;
- the permission map entry for the PUT path;
- rule responses include the summary and never a number;
- `messages_active` is always false.

**Web tests** (`web/src/routes/alerts/*.test.tsx`):
- the panel is hidden while WhatsApp is off;
- add, edit and remove;
- a field-level error for an invalid number and for a duplicate;
- the opt-in checkbox is required for new or changed numbers;
- the unsaved-changes indicator; the success and error states, with the
  stored configuration preserved after a failed save;
- the "not sent yet" notice;
- the old WhatsApp checkbox is gone and Email is still Coming Soon;
- the rule-list badge;
- saving the rule and saving WhatsApp are independent requests.

**Regression:** the full `test_alert_rules_db.py` and
`test_alerts_api_routes.py` suites; the full pytest suite on a fresh test
database; vitest, tsc, eslint and the build; CI on the PR.

**Staging verification**, after an authorised deployment, read-only apart
from the authorised test saves:
- the 331 ledger row and the post-deploy gate;
- grants, read-only;
- no change to existing rules or occurrences;
- WhatsApp off everywhere;
- with authorisation, one test save by a test admin using WiseWatts test
  numbers (README Q-4), then its audit row and the masked values.

## 8. Dependencies

- **Implementation authorisation** for Phase 1. After that, separate
  authorisations for the PR merge, the staging migration and deployment,
  and any staging test write.
- **Product:** the consent-statement wording (D8); the recipient cap
  (README Q-2); retiring the old checkbox (Q-7); whether real customer
  numbers may be entered before Phase 2 (Q-4).
- **Code:** a new pinned dependency, `phonenumbers`.
- **Platform:** ADR-024 on staging (it is). Production is out of scope
  (D11).

## 9. Out of scope for Phase 1

- Sending any message, by any channel; provider accounts, SDKs or HTTP
  calls (D1).
- The delivery queue/outbox, delivery records table, sender worker,
  delivery-receipt webhook, STOP handling and templates (D12, Phase 2).
- Infrastructure changes: containers, egress rules, public routes, env
  files and secrets (D12).
- Production migrations or deployment (D11).
- Changes to `evaluate_alert_rules`, the timers, the occurrence lifecycle,
  acknowledgement, reminders or Email.
- Groups, a contact directory, routing, escalation, recovery messages and
  reminders (D2, D7; PRD §3.3).
- Delivery-history UI and retention jobs (Phase 3).
- OTP or number verification (D4).
