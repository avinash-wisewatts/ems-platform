# WhatsApp notifications — Phase 1 plan: staging-only configuration

Status: **PLAN — not authorised.** Design basis: ADR-024 Amendment 2,
**Decided 2026-11-23**. Implementation still needs its own approval. Implementing, merging or deploying any of
this needs separate, explicit authorisation. Phase 1 **sends no messages**.
Decisions: [README.md §2](README.md#2-confirmed-decisions-product-owner-2026-11-23)
(D1–D21). Architecture: [ADR-026](../../../00-governance/decisions/ADR-026-whatsapp-alert-notifications.md)
(Proposed). Basis: `origin/staging` `458c179`. Prepared 2026-11-23.

## 1. Scope

Phase 1 delivers, on **staging only**:

1. Saving and retrieving each alert rule's WhatsApp settings (on/off) and
   its recipient phone numbers.
2. Server-side authorisation (tenant, site, role) and an audit row for
   every configuration and consent change.
3. Validation: E.164 numbers, no duplicates per rule, at most 10
   recipients per rule (D15), and at least one consented recipient before
   WhatsApp can be on.
4. Consent capture: an explicit administrator opt-in confirmation per
   number, recording who confirmed it, when, and which Product-approved
   wording was shown (D4, D21). Whether this is legally sufficient is open
   (L-1); Phase 1 does not assume compliance (D19).
5. Tests proving that WhatsApp configuration changes do not affect:
   - occurrence state;
   - trigger and resolution timers;
   - acknowledgements;
   - rule versions;
   - existing notification behaviour (in-product only, with Email still
     "Coming Soon").
6. Removing the old "Coming Soon" WhatsApp checkbox (D20), behind the
   §3.3 safeguard and the §7.2 regression tests.

Only WiseWatts-controlled test numbers are ever entered on staging (D17).
Operators and Viewers see no recipient information at all (D16).

## 2. The three concepts

| Concept | Owner tables / functions | Phase 1 effect |
|---|---|---|
| 1. **Alert definition and operational lifecycle** | `analytics.alert_rules`, `analytics.alerts`, `analytics.alert_evaluation_candidates`; `evaluate_alert_rules` and the migration 323 write functions | **Behaviour unchanged.** Two small adjustments only: `whatsapp_requested` is neutralised (§3.3), and soft delete also removes the WhatsApp configuration (§3.4). `evaluate_alert_rules` is not modified. |
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
| `revision` | INTEGER NOT NULL DEFAULT 1 | Optimistic concurrency: stale saves are refused. A rule with no row has revision `0` (not configured). |
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
| `consent_statement_version` | TEXT NOT NULL, FK → consent register (§3.6, proposed R6) | Which version of the Product-approved confirmation wording was shown (D21). The wording must be approved before first use. |
| `opted_out_at`, `opted_out_source` | NULL in Phase 1 | Phase 2. |
| `created_at`, `created_by` | | |

There is no verification column (no OTP, D4) and no name or label column
(data minimisation). Removing a recipient deletes the row (A-3). A count
cap of **10** per rule is enforced in the save function (D15).

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
  build deployed separately keeps working. **Only for callers holding
  `alert.configure`**, they also gain a separate summary
  `whatsapp: {enabled, recipient_count}`. For every other role the field is
  `null` (D16). Full numbers never appear in rule responses.

### 3.4 Soft delete (A-5)

`delete_portal_alert_rule` is re-created, with the same signature, to also
delete the rule's WhatsApp settings and recipients in the same transaction.
Its audit row records the removed recipient ids, not phone numbers (proposed
R12). Occurrence handling is
unchanged.

### 3.6 Proposed items: included only if their owner approves

These are review recommendations, **not approved decisions**. Phase 1 is
designed so each can be added or left out without changing the rest.

| Item | Proposal | Owner | Status |
|---|---|---|---|
| R5 | Every WhatsApp function (get, save, summaries) refuses (`forbidden`) an actor who is the designated report automation account of **any** site, i.e. `analytics.site_report_profiles.automation_portal_user_id` (on staging, uid 17). This follows `analytics.site_report_can_generate` (migration 330). | Architecture | Proposed |
| R6 | **Versioned opt-in wording register.** A table `analytics.alert_whatsapp_consent_statements` with `version` (PK), `statement_text`, `approved_by_name`, `approved_at` and `retired_at`. Rows are added by migration only after Product approves the wording (D21). The save refuses new consent while no current approved version exists (`whatsapp_consent_statement_missing`). Each consent stores the version it was given under (FK). A docs mirror lives in [consent-wording-register.md](consent-wording-register.md). | Product (wording), Legal (sufficiency) | Proposed |
| R7 | **Retention while disabled:** switching WhatsApp off keeps the configured numbers. Disabling stops sending only; deleting a number is a separate, explicit action (removal, or rule deletion). Legal requirements may override this (L-3). This is assumption A-9. | Product, Legal | Proposed |
| R8 | **Staging-only allow-list:** a table `analytics.alert_whatsapp_test_number_allowlist (phone_e164, added_by, added_at)` and a migration-set flag. On staging and test, the save refuses any number not on the list (`whatsapp_number_not_allowed`). The migration ships the table **empty**. Real numbers are never committed to the repository. Populating the list is a staging data write that needs its own approval. | Product (policy), Architecture | Proposed |
| R12 | Audit holds recipient ids and consent metadata, with no phone number, full or masked, until Legal approves otherwise. Reflected in §3.5 as the recommended default. | Legal | Proposed |

### 3.5 Functions (SECURITY DEFINER, owner `ems_admin`, `search_path` pinned)

| Function | Rule |
|---|---|
| `analytics.alert_phone_mask(TEXT)` → TEXT | Country code plus the last 4 digits, e.g. `+91 ••••••3210`. IMMUTABLE. Used only for the configurer's masked display; **not** written to audit (proposed R12). |
| `analytics.get_portal_alert_rule_whatsapp(p_portal_user_id, p_rule_id)` | Returns settings and recipients with full numbers. Requires `alert.configure` (`admin.portal_user_has_permission`) and site access. An inaccessible, unknown or soft-deleted rule raises `not_found`, the same as a missing one (ADR-007). Without `alert.configure` it raises `forbidden`; Operators and Viewers never receive recipient information (D9, D16). |
| `analytics.save_portal_alert_rule_whatsapp(p_portal_user_id, p_rule_id, p_enabled, p_recipients JSONB, p_expected_revision)` | Replace-all save, as PRD §6.3 describes. Same permission and site checks. See the details below this table. |
| `analytics.get_portal_alert_rule_whatsapp_summaries(p_portal_user_id, p_site_id)` | Per rule: `enabled` and `recipient_count`; no numbers. Requires `alert.configure` and site access; raises `forbidden` otherwise (D16). Feeds the rule-list badge and the configurer-only summary in rule responses. |

**`save_portal_alert_rule_whatsapp` in detail:**
- **Locking and concurrency:** `INSERT … ON CONFLICT DO NOTHING` creates a
  settings row at revision 0 if none exists, then locks it
  (`SELECT … FOR UPDATE`). A `p_expected_revision` that does not match
  (revision 0 for a rule that was never configured) is refused with
  `whatsapp_config_stale`. Concurrent first saves therefore get a 409, never
  a 500 (review R1).
- **Validation:** E.164 format, duplicates, at most 10 recipients (D15), and enabled requiring
  at least one CONFIRMED recipient.
- **Recipient identity:** every supplied `recipient_id` must belong to
  **this rule**; otherwise the save is refused with
  `whatsapp_unknown_recipient`. A recipient's consent can never be carried
  to another rule (D4; review B2).
- **Consent:** a recipient that keeps its `recipient_id` and number keeps
  its consent. A new or changed number needs `opt_in_confirmed = true`; the
  function then records the confirmer, the time and the statement version
  (A-2). Removed recipients are deleted.
- **Audit:** writes **one** `admin.audit_events` row in the same
  transaction: action `ALERT_RULE_WHATSAPP_UPDATED`, entity
  `ALERT_RULE_WHATSAPP`, with the actor type derived server-side. Previous
  and new values hold `enabled` and, per recipient, the `recipient_id`
  and consent metadata (confirmer, time, statement version), plus the
  lists of added, removed and consent-confirmed recipient ids. **No phone
  number, full or masked, is written to the permanent audit log** (proposed
  R12, which replaces A-4's masked-number default). Recipient ids are
  random UUIDs and reveal nothing once the recipient row is deleted. The
  permitted audit content and retention stay open for legal review (L-2,
  D19).
- **A no-op save** writes nothing.
- **What it never touches:** `alert_rules`, `alerts` or
  `alert_evaluation_candidates`.

**Refusal codes**, mapped by the API: `whatsapp_invalid_phone`,
`whatsapp_duplicate_phone`, `whatsapp_too_many_recipients`,
`whatsapp_recipients_required`, `whatsapp_consent_required`,
`whatsapp_config_stale`, `whatsapp_unknown_recipient`, `not_found`,
`forbidden`.

**No full number leaves the save path in text:** none in log lines,
exception messages, error `detail` (the `/api/v1` validation handler is
already generic, `app/src/api_errors.py`) or audit values (review R2).

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
| Existing rule responses (`GET /sites/{id}/alert-rules`, `GET /alert-rules/{id}`) | unchanged (`dashboard.view` + site access) | For `alert.configure` holders only, gain `whatsapp: {enabled, recipient_count}` from the summaries function; for every other role `whatsapp` is `null` (D16). `delivery.whatsapp` is kept as `COMING_SOON` (§3.3). |

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
    (placeholder only: the exact wording must be defined and approved by
    WiseWatts Product before it is used, D21);
  - an unsaved-changes indicator, and a success or error message;
  - a fixed notice: **"WhatsApp messages are not sent yet."**
- **Coming Soon block:** the old WhatsApp checkbox is removed (D20). Email
  stays "Coming Soon", and the reminder text stays "not sent".
- **Rule list:** a "WhatsApp · N" badge where enabled, rendered **only for
  `alert.configure` holders** (D16). Operators and Viewers see no WhatsApp
  indicator, count or number anywhere.
- **Who sees the panel:** only users with `alert.configure`, consistent
  with today's rule form.

## 6. Phase 1 acceptance criteria

| ID | Criterion |
|---|---|
| P1-AC-1 | A customer site `ADMIN` can open a rule on an authorised site, enable WhatsApp, add up to 10 valid numbers with opt-in confirmed, and save. The configuration is returned unchanged on reload. |
| P1-AC-2 | Each rule's configuration is independent: saving rule A never changes rule B. |
| P1-AC-3 | A `GLOBAL` `ADMIN` can configure rules on any site. |
| P1-AC-4 | A customer `ADMIN` gets 404 for another organisation's or an unauthorised site's rule (read and save). Operators, Viewers, `GLOBAL` `OPERATOR` and `GLOBAL` `VIEWER` get 403 on GET/PUT. They receive no recipient information in any response or screen: no number, masked number, count or on/off indicator (D16). |
| P1-AC-5 | The save is refused, and the stored configuration left exactly as before, when the input has: an invalid number, a duplicate, too many recipients, enabled with no recipient, a new or changed number without opt-in confirmation, or a stale revision. |
| P1-AC-6 | Every effective save writes exactly one audit row in the same transaction: the actual actor, customer or staff actor type, recipient ids and consent who/when/statement version, and **no phone number, full or masked** (proposed R12). A refused or no-op save writes none. |
| P1-AC-7 | Saving WhatsApp settings while the rule has an Active occurrence leaves the occurrence, the rule and the timers exactly as they were. The occurrence keeps its state, triggered time, acknowledgement, `condition_key` and `rule_version`; the rule keeps its version; candidate rows are unchanged. The next evaluator run behaves exactly as for a control rule. |
| P1-AC-8 | Saving while the rule is still qualifying (condition true for less than 5 minutes) does not reset the qualification: the occurrence becomes Active at the same run as a control rule. The same holds during the 1-minute resolution window. |
| P1-AC-9 | A rule edit that sends `delivery.whatsapp` in either state, or omits it, never ends an Active occurrence, changes its acknowledgement or bumps the rule version, provided nothing else changed. Editing any operational field still ends it as today (`CONFIGURATION_CHANGED`, ADR-024 §8). |
| P1-AC-10 | No message is sent, and nothing exists that could send one: no outbox or delivery table, no worker, no outbound call, no callback route. `messages_active` is always false, and the UI shows "messages are not sent yet". In-product alerts, the header count and Email "Coming Soon" behave exactly as before. |
| P1-AC-11 | Every existing rule starts with WhatsApp off. Migration 331 refuses to run if any `whatsapp_requested` is true. |
| P1-AC-12 | Soft-deleting a rule deletes its WhatsApp settings and recipients, audited with recipient ids only; its occurrences are preserved as today. |
| P1-AC-13 | Grants match §3.5 exactly, and the tables are not directly readable by the application roles. The migration applies on a fresh test database and is idempotent. Its rollback script, which needs approval like any staging rollback: drops the `whatsapp_requested` CHECK and both new tables, which **deletes every stored number** with no copy kept; reports the deleted counts; and restores the migration 323 definitions of the create, update and delete functions (review B3). |
| P1-AC-14 | **Lifecycle regression (§7.2):** across every case in the regression matrix, WhatsApp saves and alert saves that change no operational field leave Active occurrence state, trigger and resolution timers, acknowledgements and rule versions byte-for-byte unchanged. Enable/disable, delete and acknowledge behave exactly as on `origin/staging` `458c179`. |
| P1-AC-15 | Only WiseWatts-controlled test numbers are entered on staging (D17), recorded in the staging verification record. If R8 is approved, this is also enforced by the allow-list. |
| P1-AC-16 | *(If R5 is approved)* a designated report automation account is refused by every WhatsApp function, even with `alert.configure` and site access. |
| P1-AC-17 | *(If R6 is approved)* new consent is refused while no approved wording version exists; every consent records an existing register version. |
| P1-AC-18 | *(If R8 is approved)* on staging and test, a number not on the allow-list is refused, and the stored configuration is unchanged. |

## 7. Test plan

### 7.1 Database tests — WhatsApp configuration

`app/tests/test_alert_whatsapp_config_db.py`, test DB, the
`test_alert_rules_db.py` fixtures:
- **Save and read:** a round trip; replace-all semantics; revision bump
  and stale refusal; no-op save.
- **Validation:** E.164 format; a duplicate after normalisation; 10
  accepted and 11 refused (D15);
  enabled with no consented recipient; a new number without consent; a
  changed number needing fresh consent; an unchanged number keeping its
  consent (A-2).
- **Recipient identity (review B2):** a `recipient_id` from another rule on
  the same site, from another site and from another organisation is
  refused (`whatsapp_unknown_recipient`), and no consent is copied.
- **Concurrency (review R1):** a first save with revision 0; two concurrent
  first saves (one succeeds, one gets `whatsapp_config_stale`, no error);
  a stale revision.
- **R5 (if approved):** uid-17-style automation account with `ADMIN` and
  site access is refused for get, save and summaries; an ordinary `ADMIN`
  on the same site is allowed; removing the designation restores access.
- **R6 (if approved):** consent refused with no approved version; a
  retired version cannot be used for new consent; existing consents keep
  their version.
- **R8 (if approved):** a non-listed number is refused; a listed number is
  accepted; the list is empty after migration.
- **No numbers in text (review R2):** for refused saves, assert the error
  text and the captured logs contain no submitted full number.
- **Permissions:** customer `ADMIN` own site / other organisation / an
  unselected site; `OPERATOR`; `VIEWER`; the `GLOBAL` roles; an
  inactive user; a soft-deleted rule. Read, save and summaries for each;
  the summaries are refused for non-configurers (D16).
- **Audit:** one row per effective save; no phone digits (asserts neither
  the full nor the masked number, nor the last 4 digits, appears in
  `previous_values` or `new_values`; proposed R12); actor type
  customer vs staff; no row on a refusal; rollback atomicity (a forced
  failure after the audit leaves both unchanged).
- **Migration 331:** the precondition refuses a seeded `true` flag; the
  CHECK is present; soft delete removes the configuration; the grant
  postconditions hold; idempotent re-apply; the rollback.

### 7.2 Lifecycle regression coverage (D6, D20; P1-AC-7, -8, -9, -14)

`app/tests/test_alert_whatsapp_lifecycle_regression_db.py`.

**Fixture:**
- one site with these rules:
  - **R-active:** an Active occurrence, acknowledged by a customer
    operator;
  - **R-active-unacked:** an Active occurrence, not acknowledged;
  - **R-qualifying:** condition true for 3 minutes;
  - **R-resolving:** an Active occurrence, condition clear for 30 seconds;
  - **R-control:** an identical twin of each, never touched by any save.

**Snapshot compared before and after each case:** the full rows of:
- `analytics.alerts`: state, triggered/resolved/ended times,
  `ended_reason_code`, `acknowledged_at/by/actor_type`, `condition_key`,
  `rule_version`;
- `analytics.alert_evaluation_candidates` (the timers);
- `analytics.alert_rules`: `version`, `enabled`, `updated_at`.

| Case | Action | Expected |
|---|---|---|
| RG-1 | WhatsApp save: enable with 1 recipient | Snapshot equal |
| RG-2 | WhatsApp save: add, edit and remove recipients; 10 recipients | Snapshot equal |
| RG-3 | WhatsApp save: disable | Snapshot equal |
| RG-4 | Refused WhatsApp save (invalid, 11 numbers, stale) | Snapshot and WhatsApp configuration equal |
| RG-5 | Rule update, nothing changed, `delivery.whatsapp` omitted (new form) | Snapshot equal; no audit row |
| RG-6 | Rule update, nothing changed, `delivery.whatsapp: true` (old client) | Snapshot equal; `whatsapp_requested` stays false |
| RG-7 | Rule update, nothing changed, `delivery.whatsapp: false` | Snapshot equal |
| RG-8 | Rule update, threshold changed (control for ADR-024 §8) | Occurrence Ended `CONFIGURATION_CHANGED`, version +1; WhatsApp configuration **unchanged** |
| RG-9 | Rule disable / enable | Same results as on `458c179`; WhatsApp configuration unchanged |
| RG-10 | Acknowledge R-active-unacked, then a WhatsApp save | Acknowledgement who/when unchanged by the save |
| RG-11 | Rule soft delete | Occurrences as on `458c179`; WhatsApp configuration and recipients deleted (A-5) |
| RG-12 | After RG-1 to RG-7, run `evaluate_alert_rules(t)` at fixed instants (qualification at 5 min, resolution at 1 min, the 2 s grace) | Every rule makes the same transitions, at the same times, as its R-control twin |
| RG-13 | Direct call: `create_portal_alert_rule` with `p_whatsapp_requested = true` | Stored false; the CHECK holds |

**Whole-file check:** a test confirms no new code path writes `alerts`,
`alert_evaluation_candidates` or `alert_rules` from the WhatsApp functions.
It does this by reading `pg_proc` definitions and checking that the
WhatsApp functions reference none of these tables.

### 7.3 API route tests

`app/tests/test_alerts_whatsapp_routes.py`:
- 200/403/404/409/415/422 mappings; the cross-site Origin refusal;
  non-JSON refusal;
- the permission map entry for the PUT path;
- rule responses include the summary for configurers, `null` for every
  other role, and never a number (D16);
- `messages_active` is always false.

### 7.4 Web tests

`web/src/routes/alerts/*.test.tsx`:
- the panel is hidden while WhatsApp is off;
- add, edit and remove;
- a field-level error for an invalid number and for a duplicate;
- the opt-in checkbox is required for new or changed numbers;
- the unsaved-changes indicator; the success and error states, with the
  stored configuration preserved after a failed save;
- the "not sent yet" notice;
- the old WhatsApp checkbox is gone and Email is still Coming Soon;
- the rule-list badge for configurers; no badge, count or indicator for an
  Operator or Viewer (D16);
- the 10-recipient limit message;
- saving the rule and saving WhatsApp are independent requests.

### 7.5 Full regression and CI

**Intentional changes to existing tests** (CLAUDE.md §12; review R3):
- `app/tests/test_customer_api_role_db.py`: the exact customer-API grant
  set gains the three WhatsApp functions.
- `app/tests/test_alerts_api_routes.py`: rule responses gain `whatsapp`
  (configurers) or `null`.
- `web/src/routes/alerts/AlertsArea.test.tsx`: the old
  `rule-whatsapp` checkbox is removed.
- `app/tests/test_alert_rules_db.py`: the existing `whatsapp=True` create
  case additionally asserts the stored value is `false`.

No other existing test changes. The full `test_alert_rules_db.py` and
`test_alerts_api_routes.py` suites; the full pytest suite on a fresh test
database; vitest, tsc, eslint and the build; CI on the PR.

### 7.6 Staging verification

After an authorised deployment. Read-only, apart from the authorised test
saves:
- the 331 ledger row and the post-deploy gate;
- grants, read-only;
- no change to existing rules or occurrences;
- WhatsApp off everywhere;
- with authorisation, one test save by a test admin using WiseWatts test
  numbers only (D17), then its audit row (recipient ids, no numbers);
- an Operator and a Viewer test user see no WhatsApp information (D16).

## 8. Dependencies

- **Authorising record (review B1): done.** ADR-024 Amendment 2 (§2A–§2E)
  was Decided on 2026-11-23. It amends §8 (the WhatsApp flag no longer
  counts as a change) and §9 / `EMS-REQ-146` (the WhatsApp Coming Soon
  option is removed) for Phase 1, staging only.
- **Deploy order (review R4):** customer API, then web, back to back. In
  between, the old form's Coming Soon tick is ignored. That is harmless,
  because the flag never sends.

- **Implementation authorisation** for Phase 1. After that, separate
  authorisations for the PR merge, the staging migration and deployment,
  and any staging test write.
- **Product:** the exact opt-in confirmation wording, defined and approved
  before use (D21). This blocks shipping the UI to staging.
- **Legal (not blocking Phase 1 on staging with test numbers only):** L-1 to
  L-3. The Phase 1 audit content may need changing before any production
  use.
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
- Real customer phone numbers on any environment (D17).
- Any recipient information for Operators or Viewers, including masked
  delivery history (D16; reconsidered in Phase 2/3).
- A per-site message cap (D18, Phase 2).
