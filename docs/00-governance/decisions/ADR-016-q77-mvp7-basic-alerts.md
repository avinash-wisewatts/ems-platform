# ADR-016: MVP-7 Basic Alerts (Q77) — full scope, lifecycle, and behavior

Status: Decided (product/UX scope, in full detail); implemented and
deployed to staging 2026-09-14. **Staging post-deploy validation performed
2026-09-14: FAIL** — the alert-evaluation TimescaleDB job was not
registered (a separate, explicitly-authorized manual step, deliberately
withheld — see [alerts/README.md](../../07-features/alerts/README.md)),
and the deployed frontend detail view omitted hierarchy context and
threshold/reference and showed resolved fields in the wrong order versus
decision 11 below; the date-range filter (decision 48) was also found to
key on triggered time unconditionally instead of per-tab. A same-day
corrective pass fixed the frontend gaps and a latent job-registration-
script defect and added deployment-verification coverage for the job's
registration state; a **second** same-day corrective migration (240)
then fixed decision 48's date-range keying, verified functionally
against a disposable local TimescaleDB container. **The job was then
explicitly authorized and registered on staging (2026-09-14) with
correct configuration, but every execution FAILED deterministically
(3/3 runs)** — root-caused to the per-site `COMMIT` (migration 239, file
line 404) inside `analytics.evaluate_alerts()`, illegal because that
procedure is `SECURITY DEFINER` with a `SET search_path` clause (either
alone is sufficient; PostgreSQL forbids transaction control inside such a
procedure regardless of nesting — an earlier pass's "nesting is the
cause" diagnosis was incomplete, corrected by isolated reproduction) —
confirmed live and pinpointed by local reproduction. **The job was then
explicitly authorized and disabled on staging** (still registered, config
intact, `scheduled = false`, confirmed no further executions) to stop the
recurring failures pending a fix. **A third same-day corrective migration
(241)** then removed `SECURITY DEFINER`/`SET search_path` from
`evaluate_alerts()` — implemented, tested locally, **deployed to staging
(PR #61, revision `a533773`)**, and **job 1127 has been explicitly
authorized, re-enabled, and confirmed executing successfully** — live
`job_stats` shows `Success`, and `job_errors` shows zero new errors since
re-enabling (still only the original 3 pre-fix `2D000` rows). MVP-7 is
still NOT functional as a released customer feature and NOT
lifecycle-validated — the running job's own qualification/resolution/
recurrence behavior over time has not yet been observed or validated —
see [alerts/README.md](../../07-features/alerts/README.md) for full
detail and current status.
See [ADR-017](ADR-017-mvp7-alert-architecture.md) for the architecture that
resolves the two questions this ADR originally left open.
Date: 2026-09-14
Decision owners: Product Owner (via a Q77/MVP-7 discovery conversation
conducted outside this repository, in ChatGPT, and transferred into this
session as a structured handoff document — see Evidence) / Engineering
(repository inspection and architecture-gap identification only, this pass)
Related requirements: Workshop Q77, Q78 (delivery-channel statement
superseded — see "Source-of-truth correction"), Q67 (Administration App
configuration ownership, unchanged); [functional-requirements.md §Alerts](../../02-requirements/functional-requirements.md#alerts)
(`EMS-REQ-080`–`EMS-REQ-084`, `EMS-REQ-117`–`EMS-REQ-127`)
Related features: [Attention](../../07-features/attention/README.md);
[ADR-010](ADR-010-mvp3-attention-materiality-policy.md) (materiality
policy this alerting layer consumes); [ADR-011](ADR-011-insufficient-data-not-healthy.md);
[ADR-012](ADR-012-deferred-ai-recommendation-functionality.md)

## Context

The archived Product Owner Workshop baseline (§109–110,
[ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md))
established Q77 (basic customer alerts on clear, measurable analytical
conditions) and Q78 (in-product **and email** delivery) at a scope level
only. No lifecycle, state model, persistence behavior, retention policy,
recurrence definition, filtering, ordering, or content structure was ever
specified anywhere in this repository — every existing reference
(`functional-requirements.md` `EMS-REQ-080`–`084`,
`requirements-traceability.md`, `information-architecture.md`,
`navigation.md`) cites Q77/Q78 only as a resolved-scope pointer, not a
behavioral specification.

A subsequent Product discovery conversation — conducted in ChatGPT, outside
this repository — produced a full, detailed decision set for MVP-7 Basic
Alerts and was transferred into this Claude Code session as a structured
handoff document ("Q77 / MVP-7 Basic Alerts — Discovery Decision Handoff").
This ADR captures that handoff as the canonical decision record, the same
evidence-transfer pattern already used for this repository's other
workshop/decision-pack-sourced ADRs (e.g. [ADR-009](ADR-009-slice-c-historical-reference-methodology.md),
[ADR-010](ADR-010-mvp3-attention-materiality-policy.md)).

Before this ADR, two repository facts were verified directly (not assumed)
because the handoff's lifecycle model depends on them:

- **Attention has no server-side existence today.** `web/src/attention/energyAttention.ts`
  is a pure, stateless client-side function, re-evaluated at render time from
  whatever `TypicalReferenceResult`/`EnergyEvidenceSummary` the Analytics API
  happens to return at that moment — see
  [attention/README.md](../../07-features/attention/README.md) §"Data / API
  dependencies": "No dedicated Attention API endpoint exists, by design."
  `grep`-verified: no scheduler, cron, periodic job, or `BackgroundTasks`
  pattern exists anywhere in `app/src`.
- **No `Alert` entity exists in the frozen DDS conceptual model** (the ten
  concepts enumerated in [system-architecture.md](../../04-architecture/system-architecture.md)
  §"What is frozen") and no alert table exists anywhere in `postgres/`
  (`grep`-verified, `CREATE TABLE.*alert` — no matches). A pre-existing,
  unrelated `alert.acknowledge` RBAC permission for the `OPERATOR` role
  (`postgres/migrations/001_ems_platform_baseline_20260807.sql`) is part of
  an existing **operational/Administration-side** permission scaffold — it
  is not evidence of any customer-facing alert entity and must not be
  conflated with MVP-7.

These two facts are the basis of the "Architecture questions identified"
section below — they are repository-inspection findings, not part of the
Product decision itself, and are kept explicitly separate per the handoff's
own instruction ("If the repository cannot answer one of these... stop and
identify it rather than guessing").

## Decision

All items below are decided at the product/UX level, sourced verbatim/
near-verbatim from the Q77/MVP-7 discovery handoff. None of this is
implemented in code.

**1. Scope and delivery channel.** MVP-7 = basic customer alerts
communicating existing, already-computed Attention conditions — not a new
detection mechanism. In scope: customer-facing alerts from existing
Attention conditions, in-product delivery only, Active/Resolved/Ended
lifecycle, alert history, recurrence information, filtering/ordering, alert
detail, existing EMS terminology, Administration-App-only configuration.
Explicitly out of scope: email, SMS, WhatsApp, sharing, acknowledgement
workflow, alert-specific recipient configuration, a new severity taxonomy,
intelligent prioritisation, root-cause analysis, recommendations,
predictive/adaptive alerting, AI/LLM-generated content, new analytics
calculations, analytical deep links from an alert to other screens. **This
supersedes the archived Q78 statement that email is included** — see
"Source-of-truth correction" below.

**2. Triggering and qualification.** Every existing qualifying Attention
condition automatically generates an alert — there is no separate
alert-rule-selection layer in MVP-7; each distinct affected context
(Site/Space/Asset) gets its own alert. A condition must remain
**continuously true for 5 minutes** before an alert qualifies, timed from
the first observed evaluation where it becomes true. Any evaluation/data
gap during that 5-minute window **resets** the timer — elapsed wall-clock
time alone does not prove continuous qualification. The alert is generated
on the next normal evaluation cycle once qualified; there is no separate
scheduler implied and no customer-visible pending/monitoring state before
qualification.

**3. Active behavior and resolution.** Once created, an alert is Active
indefinitely while its condition remains continuously true — no repeated
alerts for the same continuously-true condition. An Active alert becomes
**Resolved** only after the condition has been continuously false for **1
minute**, timed from the first normal evaluation establishing the clear;
any gap during that window resets the timer. The first normal evaluation
establishing the clear supplies the resolution time and resolution value.

**4. Data unavailable while Active, and recovery.** If an Active alert's
underlying data becomes unavailable, the alert **remains Active** (not
auto-resolved); the customer sees "Unable to evaluate — data unavailable" /
"Latest value: Data unavailable." **When data returns (amended
2026-09-15, resolving the ambiguity a corrective-design review found in
the original wording below — see §7 and Evidence):**
- **if the condition is no longer material, the existing alert follows the
  normal resolution path (§3)** — unchanged from the original decision;
- **if the condition is still material, the existing alert becomes
  Ended** — a second, distinct Ended cause alongside §8's
  configuration-change cause (see §7) — **with a data-unavailable
  termination reason, and a fresh 5-minute qualification period starts
  from the observation that detected the recovery.** The old alert must
  not continue as the same occurrence, and no alert is immediately
  recreated merely because the condition is still true when data returns.
- Original wording, superseded by the above: ~~"the previous Active alert
  is resolved/ended per the applicable rule (§3 or §6 below as
  appropriate)"~~ — this left open which of Resolved/Ended applied when
  the condition was still true on recovery; neither §3 nor §6 actually
  covered that case. The amendment above is the resolution.

**5. Restart/deployment resilience.** Persisted alert records (Active,
Resolved, Ended) survive service restart/deployment — no disappearance, no
duplication. An in-progress 5-minute trigger timer or 1-minute resolution
timer resets on restart. An existing Active alert whose condition remains
true after restart is preserved, not duplicated.

**6. Persistence-failure handling.** If an alert qualifies but database
persistence fails, retry independently for that occurrence for **up to 30
minutes**, preserving the original trigger time/value; do not create
another occurrence while the first awaits persistence. If persistence
succeeds after the condition has already cleared, persist directly with
the appropriate resolved information (original trigger info + observed
resolution info; the normal 1-minute clear rule still determines
resolution). If persistence cannot succeed within 30 minutes: discard the
occurrence, record an operational/system error (condition, affected
context, original trigger time, discard reason), and do not expose the
failure as a customer-visible alert. The exact discard/operational-record
mechanism is explicitly an implementation detail, not decided here (see
"Not decided here").

**7. Alert states.** Exactly three customer-visible states — **unchanged,
still exactly three (amended 2026-09-15 to broaden Ended's cause list
only; no fourth state introduced — see §4)**: **Active** (condition
remains true), **Resolved** (condition cleared normally, satisfied the
1-minute continuous-clear requirement — the condition actually cleared;
this is the only case that produces Resolved), **Ended** (lifecycle
terminated for a reason **other than** normal condition clearing —
explicitly **not** Resolved). Ended currently has exactly two causes,
each with its own distinct, controlled termination reason (see §4, §8):
(a) the underlying Attention configuration was disabled or changed
(§8 — the original, only-documented cause); (b) the alert was Active
through a data-unavailable gap and, when data returned, the condition was
still material (§4, added by this amendment). The reason representation
distinguishing (a) from (b) is a controlled/enumerated value, not
arbitrary free text — exact representation is an implementation detail,
not decided here (see the implementation design this amendment
references in Evidence).

**8. Configuration-change transitions.** (One of Ended's two causes — the
other, data-unavailable-on-recovery, is §4, added by the 2026-09-15
amendment; the two are independent triggers and do not interact.)
- *Disabling* a condition: stop generating new alerts immediately; any
  existing Active alert becomes **Ended** (not auto-Resolved), recording
  when and why (reason: configuration disabled/changed).
- *Re-enabling*: evaluation restarts from fresh observations under the
  normal 5-minute qualification rule, even if the condition is already
  true at re-enablement (timer starts from the first post-re-enablement
  observation; no false→true transition is required); the resulting alert
  has a new identity.
- *Changing* a condition's threshold/reference or scope/context: treated
  as one configuration transition (multiple simultaneous field changes
  still count as one transition). Any existing Active alert is **Ended**
  (not Resolved); the new configuration applies immediately as a hard
  boundary — any in-progress 5-minute timer under the old configuration is
  discarded, evaluation begins fresh under the new configuration at the
  next available observation, and any resulting alert has a new identity.
  There is no customer-visible pending state during this transition.
- *Configuration change simultaneous with the condition clearing*: the
  existing alert is classified **Ended — configuration changed**, not
  Resolved; the configuration transition takes precedence.
- *Configuration change with no Active alert*: the new configuration takes
  effect immediately, no transition/history alert is created, and normal
  evaluation (including the 5-minute qualification rule, if the new
  condition is already true) applies going forward.

**9. Historical immutability and retention.** Historical alert records are
immutable — later configuration changes never rewrite a historical alert's
condition, metric, threshold/reference, context, trigger info, timestamps,
values, or recurrence information. Retention: **Resolved alerts remain
customer-visible for 90 days from resolution; Ended alerts for 90 days from
ending; Active alerts remain visible indefinitely** while the condition
remains true. Ended alerts appear in the same history/list as Resolved
alerts but remain explicitly labeled Ended, never silently presented as
Resolved; the Ended detail view shows the Ended status, ended timestamp,
and an explicit reason. Exact final copy for the Ended reason is an
implementation/content detail, not decided here.

**10. Recurrence.** A recurrence is an occurrence of the exact same
context + Attention condition/metric + threshold/reference — each
occurrence is its own alert record with a unique ID (never a shared record
with an incremented counter). **A configuration change creates a new
condition identity for recurrence purposes** — e.g. if Power Factor < 0.90
generates Alert #1, the configuration changes to < 0.95 (Ending Alert #1),
and the < 0.95 condition later generates Alert #2, Alert #2 does **not**
treat Alert #1 as a recurrence (same metric/context alone is insufficient;
the exact condition/threshold/reference identity matters). Ended alerts
count as genuine prior occurrences toward later alerts sharing the same
recurrence identity. Alert detail shows a concise recurrence summary —
exact label **"Previous occurrences: N"** / **"Most recent: <relative
time>"**, unvaried across Active/Resolved/Ended, never a list of individual
prior alerts. The count is limited to occurrences still within the 90-day
retention window; as older occurrences expire, the count decreases and
"Most recent" recalculates from what remains (the original count is not
permanently preserved). When there are no retained prior occurrences: show
"Previous occurrences: 0" and omit "Most recent" (never show the section
inconsistently). "Most recent" is based on the prior occurrence's
**triggered** time, never its resolved/ended time. An Ended alert retains
exactly the recurrence information that applied when it was generated; a
later configuration change never recalculates or rewrites it.

**11. Alert content.** Uses existing EMS terminology, metric/threshold
representation (operator, direction, threshold/reference exactly as EMS
currently shows it), and existing EMS number formatting — no alert-specific
terminology or number-formatting system. The alert explicitly identifies
its source as Attention (conceptually: "Attention: Power Factor < 0.90").
List summary shows only: Attention + condition, affected context, triggered
time (detail is in the detail view). Detail view field order: Attention
condition → hierarchy context → current state → triggered time → trigger
value → latest value → threshold/reference → resolution value (if
resolved) → resolved time (if resolved) → previous occurrences; Ended
alerts additionally show ended time and ending reason. Current-state
indicator is prominent (Active/Resolved/Ended). Triggered time shows exact
date/time + relative time; Resolved/Ended show exact date/time only. Trigger
value = value observed at trigger; latest value = latest available value at
time of viewing (Active and historical alike); resolution value = value at
the resolution event; any unavailable value shows "Data unavailable."
Hierarchy context shows full Site/Space/Asset levels explicitly, and never
exposes device IDs, logical point IDs, raw DB fields, or other internal
identifiers.

**12. Navigation and delivery.** In-product only (no email — see
"Source-of-truth correction"): a header notification indicator (count of
currently **Active** alerts, scoped to the user's currently selected
Site/context; the indicator remains visible with no number shown when the
count is zero; no count is shown when no Site/context is selected) and a
dedicated Alerts area in main navigation (Active/Resolved/Ended). There are
**no analytical deep links** from an alert to other analytical screens in
MVP-7 — this narrows `EMS-REQ-081`'s original "jump to the metric's screen"
framing; see the requirements-traceability correction.

**13. Filtering and ordering.** Cascading Site → Space → Asset filters
(not a single combined selector, absent repository/UX evidence requiring
reconsideration); a single-select (not multi-select) Condition/Metric
filter using existing Attention conditions as customer-facing labels; date
range filtering keyed to triggered time (Active), resolved time (Resolved),
or ended time (Ended), with defaults of the last 90 days (Active — but the
customer can expand beyond 90 days to find older still-Active alerts),
full 90-day window (Resolved), and the same 90-day window (Ended). Filters
default to the customer's currently selected context; changes require an
explicit "Apply filters" action; "Clear filters" restores the default
context and 90-day range; switching between Active/Resolved/Ended clears
filters; ordering is unchanged by filtering. Infinite scroll (no
pagination, no loading indicator while more results load, a subtle "End of
alerts" once exhausted). Ordering: existing Attention materiality first,
then most-recently-triggered within the same materiality — unchanged by
filters. Materiality is used for ordering only; it is **not** exposed as a
new alert severity taxonomy (no High/Medium/Low).

**14. Authorization.** Alert visibility follows existing EMS authorization
— no separate alert-specific recipient/permission configuration and no new
alert-specific Admin role. The typical user is Site-level; Attention
conditions may still be configured independently at Site, Space, or Asset
level by existing Admin users who already have permission to configure the
relevant Site/Space/Asset. Configuration remains exclusively in the
Administration App (Q67, unchanged) — MVP-7 introduces no customer-facing
alert configuration system.

**15. No acknowledgement.** No Acknowledge / Snooze / Dismiss-as-
acknowledged / assigned-to-user workflow in MVP-7, unless introduced by a
later, separate product decision.

## Source-of-truth correction

> **CURRENT IMPLEMENTATION:** every canonical reference to Q77/Q78 in this
> repository (`roadmap.md`, `product-definition.md`,
> `functional-requirements.md` `EMS-REQ-080`/`084`,
> `information-architecture.md`, `navigation.md`) states MVP-7 alert
> delivery is **"in-product + email."**
>
> **HISTORICAL / DOCUMENTED EXPECTATION:** this traces to the archived
> workshop baseline §110 ("Q78 — MVP Alert Delivery"): *"MVP alert delivery
> includes: In-product... Email... Email notifications are turned on for
> MVP... Keep MVP email alerting deliberately simple."*
>
> **CHANGE:** the Q77/MVP-7 discovery handoff (2026-09-14, transferred from
> a ChatGPT conversation) explicitly states: *"Existing archived Q78
> documentation reportedly says in-product + email. That is superseded by
> this decision: MVP-7 is in-product only; email is not in scope."* Email
> (and SMS, WhatsApp, sharing) is now explicitly **out of scope** for
> MVP-7, deferred without a committed later phase. Every current-repository
> reference above is corrected by this ADR to "in-product only."
>
> **VERIFICATION:** the correction is a direct, explicit Product statement
> in the handoff (§1 and §36 of the handoff document), not an inference —
> recorded here per this repository's no-silent-reconciliation rule
> ([source-of-truth.md](../source-of-truth.md)). The archived baseline
> file itself is left unedited, consistent with how ADR-014/ADR-015 treated
> other archived-baseline corrections — it remains the historical record;
> this ADR is the current canonical statement.

## Architecture questions identified — not resolved

These are repository-inspection findings from this documentation pass, kept
explicit and separate from the Product decision above per the handoff's own
instruction not to guess at implementation/architecture from a product
handoff.

**A. No server-side Attention/alert evaluation mechanism exists in any
form.** Attention today (`web/src/attention/energyAttention.ts`) is a
stateless, pure client-side computation re-run at render time from
API-fetched data — there is no persisted evaluation state, no continuous
"evaluation cycle," and no scheduler/job/worker of any kind in `app/src`
(verified by `grep` — no `add_job`/scheduler/cron/periodic/`BackgroundTasks`
pattern exists). Handoff §2–§8 (5-minute qualification with gap-reset,
1-minute resolution with gap-reset, restart-survival, 30-minute persistence
retry) all presuppose a continuously-running, stateful, server-side
evaluation process. **Where and how this runs — a new backend
service/worker, a TimescaleDB-native job analogous to the existing
routing/compression/retention/continuous-aggregate-refresh jobs, or some
other mechanism — is a genuine, unresolved architecture decision.** Per the
handoff's explicit instruction (§51, §53), this must not be guessed at in
this documentation-only pass.

**B. No `Alert` entity exists in the frozen DDS conceptual model, and none
exists in the schema.** The ten concepts frozen by the DDS
([system-architecture.md](../../04-architecture/system-architecture.md))
do not include an Alert/Notification entity; no alert table exists
anywhere in `postgres/` (verified by `grep`). Handoff §9, §16, §19–§28
require a new, persisted, immutable, stateful record type (states,
timestamps, trigger/resolution values, recurrence identity, 90-day
retention). Introducing this is a **new core entity** and must pass the
DDS's five-criteria change-control test
([04-architecture/README.md](../../04-architecture/README.md)) before
design/implementation proceeds — this test has not been run and is out of
scope for this documentation-only pass. (The pre-existing
`alert.acknowledge` RBAC permission in
`postgres/migrations/001_ems_platform_baseline_20260807.sql` is unrelated
operational/Administration-side scaffolding, not an existing Alert entity
— see Context.)

## Rationale

Not independently stated beyond the handoff's own decisions — the handoff
does not record why each specific numeric value (5 minutes, 1 minute, 90
days, 30 minutes) was chosen, only that it was decided. No rationale is
invented here.

## Alternatives considered

Not established in available source material — the handoff records
decisions, not the deliberation or alternatives weighed to reach them.

## Consequences

- MVP-7 Basic Alerts is now fully specified at the product/UX level —
  detailed enough to design against once the two architecture questions
  above are resolved. **No code exists yet**; nothing in this workstream
  changed application code, schema, or configuration.
- `EMS-REQ-081`'s original "alert → context navigation" framing is narrowed
  by decision §12 above (no analytical deep links in MVP-7) — corrected in
  `requirements-traceability.md` and `functional-requirements.md` via the
  standard contradiction-recording format, not silently.
- The archived Q78 "in-product + email" statement is superseded
  repository-wide (roadmap, product-definition, functional-requirements,
  information-architecture, navigation) — see "Source-of-truth correction."
- Implementation cannot proceed on the persistence/lifecycle-timer behavior
  (handoff §2–§8) until Architecture Question A is resolved, and cannot
  proceed on the persisted Alert entity itself (handoff §9, §16, §19–§28)
  until Architecture Question B's five-criteria test is run. The
  UI-only-facing decisions (content, filtering, ordering, navigation
  surfaces) do not depend on either open question and could, in principle,
  be designed independently, but building against them before an alert
  actually exists to display would be premature.

## Evidence / references

- **§4/§7 amendment (2026-09-15)**: a read-only corrective-design review
  identified that the original §4 wording ("resolved/ended per the
  applicable rule (§3 or §6 as appropriate)") did not actually specify an
  outcome for "condition still material when data returns" — neither §3
  nor §6 covers that case. Three options (Resolved / Ended / a new fourth
  state) were presented without a recommendation; **Ended was selected**,
  as recorded above. See `docs/07-features/alerts/README.md` and
  `docs/08-verification/mvp7-alerts-staging-lifecycle-validation.md` for
  the implementation-design/specified-vs-implemented status this
  amendment produced, and [ADR-017](ADR-017-mvp7-alert-architecture.md)
  for the corresponding conceptual-data-model addition
  (`data_unavailable`, controlled Ended-reason representation).
- Q77/MVP-7 Basic Alerts — Discovery Decision Handoff (this session,
  2026-09-14; transferred from a ChatGPT conversation not itself stored in
  this repository — same "cited decision source not present as a file"
  pattern already flagged in [ADR-009](ADR-009-slice-c-historical-reference-methodology.md)
  and [ADR-010](ADR-010-mvp3-attention-materiality-policy.md)).
- Archived workshop baseline §109–113 (Q77–Q81) —
  [ems-product-owner-workshop-baseline.md](../../99-archive/superseded-product/ems-product-owner-workshop-baseline.md).
- [attention/README.md](../../07-features/attention/README.md) §"Data / API
  dependencies" ("No dedicated Attention API endpoint exists, by design").
- [ADR-010](ADR-010-mvp3-attention-materiality-policy.md) (materiality
  computation this alerting layer consumes, unchanged by this ADR).
- [system-architecture.md](../../04-architecture/system-architecture.md)
  §"What is frozen" (ten-concept model, no Alert entity).
- [04-architecture/README.md](../../04-architecture/README.md) (five-criteria
  change-control test).
- `grep` verification (this session): no scheduler/cron/job pattern in
  `app/src`; no `CREATE TABLE.*alert` anywhere in `postgres/`; the one
  `alert.acknowledge` permission hit is RBAC seed data for `OPERATOR`,
  unrelated to a customer alert entity.

## Implementation references

None. No application code, schema, migration, or configuration was changed
in this workstream — documentation only, per explicit instruction.

## Validation references

None applicable — no code exists yet to validate.
