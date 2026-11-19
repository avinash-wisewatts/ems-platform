# Create report — Radisson Blu Coimbatore staging configuration and automation-account plan

Status: **§2 configuration APPLIED to staging 2026-11-19 08:13 IST** (Product
Owner approval, with two amendments: Banquet 1 STANDBY removed; schedules
provisional), see §6. **§3 automation account CREATED 2026-11-19 08:19 IST**
(portal user 17, PO approval), validated (§7), **designated** on the Coimbatore
profile 08:25 IST (§8). Automatic schedules remain **paused**. No report generated. Production is out of scope (A106).

Authoritative specification: [README.md](README.md) revision 4.1
(§4.1 roster, §4.6 read identity, §5.1–5.3 settings). Runbook:
[create-report-runbook.md](../../10-operations/create-report-runbook.md).

## 1. Staging facts verified (read-only, 2026-11-19)

| Item | Staging value | Matches rev 4.1 |
|---|---|---|
| Organization | Radisson Blu (`RADISSON_BLU`, `0af32ef1-b517-46d0-b0eb-1546c082ab53`), 1 site | yes — no new organization or site is created |
| Site | Coimbatore (`COIMBATORE`, `870af241-abb4-4501-95dd-5c7508b72588`), ACTIVE, `Asia/Kolkata` | yes (§4.1) |
| Roster assets | all 23 present, ACTIVE, names identical to §4.1 | yes |
| Temperature-monitored (EMS catalogue, A15) | Lobby Area AHU-1, Seasons Restaurant AHU-1, Seasons Restaurant AHU-2, Banquet 2 AHU | yes — Banquet 1 AHU, Lobby Area AHU-2 and Pre Function Area AHU show "Not temperature-monitored" |
| Active Power + Energy points | present for all 23 assets | yes |
| Report profile / reports | 0 / 0 (not enrolled) | — |
| Radisson portal users | **none** on staging | see §5 |

## 2. Configuration to enter (Administration App, as a WiseWatts Admin)

### 2.1 Enrolment and schedules (A61, A62)

Site detail → Reporting → *Enrol site for reports*. Automatic weekly **on**,
automatic monthly **on**. No earlier period is ever generated automatically (A70).

**Timing (important).** Enrolment schedules the next closed period. The first
automatic weekly attempt is the week 15–21 Nov 2026 at **Sun 22 Nov 06:00 IST**,
and the first monthly attempt is November at **Tue 1 Dec 06:00 IST**. If the
automation account (§3) is not designated by then, that attempt fails with
`automation_not_authorized` and is not retried (A90). Either complete §3
first, or pause the automatic schedules at enrolment and resume them after §3
(pause and resume are audited, A62).

### 2.2 Reporting asset list (§4.1)

| Order | Asset | asset_id | Group | Area |
|---|---|---|---|---|
| 1 | Chiller1 | `219b9e72-9029-4ab8-9d7a-6ee680a4d686` | HVAC_CHILLERS | — |
| 2 | Chiller2 | `588a62f3-bb8e-4ba8-99ac-b85fe90f416b` | HVAC_CHILLERS | — |
| 3 | Primary Pump-1 | `fbb5e539-b8fc-4b80-9f71-7678831191bc` | HVAC_PUMPS | — |
| 4 | Primary Pump-2 | `2919afbd-4ffc-4b6c-a2a2-bff77057567b` | HVAC_PUMPS | — |
| 5 | Condenser Pump-1 | `59a0db13-a4ac-405c-8695-1f88687bd47a` | HVAC_PUMPS | — |
| 6 | Condenser Pump 2 | `77c7ffb3-fa1c-4a56-8e69-1b651c51b433` | HVAC_PUMPS | — |
| 7 | CoolingTower1 | `33ccef03-cb61-4290-85f1-f100cc42001c` | HVAC_COOLING_TOWERS | — |
| 8 | CoolingTower2 | `6a5b5cbc-9fdd-4a2d-a51a-caf4ff40ec91` | HVAC_COOLING_TOWERS | — |
| 9 | Lobby Area AHU-1 | `52a4e1de-a904-4d9f-8914-b1159c6be1a6` | HVAC_AHU | LOBBY |
| 10 | Lobby Area AHU-2 | `7cde2107-80ca-42fb-804a-f20510307fa6` | HVAC_AHU | LOBBY |
| 11 | Seasons Restaurant AHU-1 | `5f035456-fb79-45a2-ac3a-e7f652904e6f` | HVAC_AHU | RESTAURANT |
| 12 | Seasons Restaurant AHU-2 | `20595da7-9e8c-4115-a5c8-6fdea5ba47cd` | HVAC_AHU | RESTAURANT |
| 13 | Banquet 1 AHU | `c9732940-5a00-499f-85e9-f65cb94a850b` | HVAC_AHU | BANQUET_1 |
| 14 | Banquet 2 AHU | `28429855-758f-4d17-8592-d308cbac085b` | HVAC_AHU | BANQUET_2 |
| 15 | Pre Function Area AHU | `fbcf2f09-d211-4a58-b3f8-01c6cafbc1ef` | HVAC_AHU | PRE_FUNCTION |
| 16 | Kitchen GF Cold Serving Area | `f0c0e7a5-67d7-4e66-9671-631ae9837010` | KITCHEN | — |
| 17 | Kitchen GF Hot Food PickUp Ctr | `28280ff9-243c-45d3-9ef2-6a8bf36227ed` | KITCHEN | — |
| 18 | Kitchen GF Induction Ctr Tops | `d70b0b34-266d-48c4-b3b3-b2ee60a580ad` | KITCHEN | — |
| 19 | Kitchen GF Sandwich Toaster | `32b3676b-6dba-4117-ba75-7da3be6f5e35` | KITCHEN | — |
| 20 | Kitchen GF Under Counter Freezers | `5e7e566a-0b05-4678-ac27-d359fb1defcf` | KITCHEN | — |
| 21 | Kitchen GF Walkin Deep | `be0a5f57-c510-42d2-9109-5dd2f34bff3a` | KITCHEN | — |
| 22 | Kitchen GF WalkIn Freezer Fruits | `42ffdea8-a337-4dbf-a9b4-35e0b7abdf1e` | KITCHEN | — |
| 23 | Kitchen GF WalkIn Freezer | `b64d9bb9-a948-4a5c-9d2a-b2471e58bf5a` | KITCHEN | — |

### 2.3 Per-asset settings (A9; "effective now")

Values are the reference tool's (A9): setpoints are the tool's
`DEFAULT_SETPOINTS`, and schedules and thresholds are its saved
`ems_settings.json` (2026-11-02) and evidence-based AHU thresholds.

**Temperature setpoint** (temperature-monitored assets only):

| Asset | Setpoint |
|---|---|
| Lobby Area AHU-1 | 24.0 °C |
| Seasons Restaurant AHU-1 | 24.0 °C |
| Seasons Restaurant AHU-2 | 24.0 °C |
| Banquet 2 AHU | 24.0 °C |

**Operating schedule and thresholds** (the 7 AHUs). Every schedule is the same
interval on all 7 days; "calculate out-of-hours energy" is on; "confirmed by
hotel" is **off** (the tool's file records every schedule as unconfirmed).

| AHU | Schedule (daily) | OFF kW | STANDBY kW | ON kW | Runtime | Tool confidence |
|---|---|---|---|---|---|---|
| Lobby Area AHU-1 | 05:00–23:00 | 0.05 | — | 0.40 | on | High |
| Lobby Area AHU-2 | 05:00–23:00 | 0.05 | — | 0.40 | on | High |
| Seasons Restaurant AHU-1 | 06:00–22:00 | 0.05 | — | 0.45 | on | High |
| Seasons Restaurant AHU-2 | 06:00–22:00 | 0.05 | — | 0.45 | on | High |
| Banquet 1 AHU | 06:00–22:00 | 0.005 | — (removed, PO 2026-11-19) | 0.60 | on | High (ON/OFF) |
| Banquet 2 AHU | 06:00–22:00 | 0.05 | — | 0.85 | on | High |
| Pre Function Area AHU | 06:00–22:00 | 0.05 | — | 0.80 | on | High |

Data-quality thresholds are fixed in code and shown read-only (A11). They are
not configured here.

### 2.4 Post-configuration verification (read-only)

- 23 roster rows: 2 chillers, 4 pumps, 2 cooling towers, 7 AHUs with the areas above, 8 kitchen.
- 4 setpoint, 7 schedule and 7 threshold versions, ACTIVE, `effective_from` = save instant.
- One `admin.audit_events` row per write, with the WiseWatts Admin as actor.
- `analytics.get_site_report_worker_settings` returns the same values.

## 3. Automation account plan (A88–A90, A108 Option A) — created, see §7

| Attribute | Value |
|---|---|
| Username | `ww_report_automation_coimbatore` (confirmed by the PO) |
| Display name | `WiseWatts report automation (Coimbatore)` |
| Email | none (optional in EMS; the account receives no mail) |
| Role / scope | ADMIN / SELECTED_SITES |
| Organization | Radisson Blu (`0af32ef1-…`) |
| Sites | Coimbatore only (`870af241-…`) |
| Active | yes (required by the checks) |
| Password | **no usable password** (below) |
| Created by | `admin.create_managed_portal_user` with a WiseWatts Admin as actor (the standard audited path) |

**No usable password.** The account is not created through the user pages,
because they issue a temporary password that a person would see. Instead the
creation function is called from the admin-portal container, using an
Argon2id hash of 64 random bytes generated in memory and discarded
immediately. Nobody, including WiseWatts, ever knows a password that
verifies. The secret is never printed, logged, stored or committed.

**Designation:** Site detail → Reporting → *Automation account* (or
`analytics.set_site_report_automation_account`). This is audited and checked
by `site_report_automation_problem`.

**Documented trade-off (A108):** the account is a Radisson-organization
identity. It appears in Radisson's user list, which is accepted. ADR-023 is
unchanged.

## 4. Access validation plan (after §3, read-only and transaction-rolled-back checks)

1. `analytics.site_report_automation_problem(<uid>, Coimbatore)` returns NULL (accepted).
2. The account's shape is as in §3: one `portal_user_site_access` row, and a `password_hash` that is Argon2id (the value is never printed).
3. Every management function called with the account as actor is refused with `site_report_forbidden` (not GLOBAL). This is checked inside `BEGIN … ROLLBACK`.
4. The account cannot read any other organization's site (`portal_user_can_access_site` is false for every other site).
5. Its uid passed to the portal read functions returns Coimbatore data only.
6. A customer sign-in attempt with any password fails (no usable password).

## 5. Gaps found

- **No Radisson portal users on staging.** Customer acceptance (Admin,
  Operator and Viewer view/download, T-SEC-1/3) needs Radisson test users,
  whose creation also needs authorization.
- **Schedules unconfirmed.** Every AHU schedule is a WiseWatts assumption, so
  the PDF marks the working hours as "provisional" until a WiseWatts Admin
  records the hotel's confirmation (a new schedule version with "confirmed by
  hotel" on).
- **Banquet 1 STANDBY threshold** had Low–Medium confidence (tool evidence);
  removed by the Product Owner and not configured (2026-11-19).
- **First automatic attempt timing:** see §2.1.

## 6. Applied configuration record (staging, 2026-11-19)

Applied through the Administration App's database functions (the same
audited path as the pages), actor `admin_avinash` (portal user 1, ADMIN /
GLOBAL), in one run at 08:13:42 IST.

| Item | Result |
|---|---|
| Enrolment | Coimbatore enrolled 08:13:42 IST (existing organization and site) |
| Automatic weekly / monthly | **paused** immediately after enrolment, so that no report is generated before the automation account exists ("do not generate reports"). Resume them on Site → Reporting when authorized; periods that ended while paused are not generated automatically |
| Roster | 23 assets: 2 chillers, 4 pumps, 2 cooling towers, 7 AHUs (LOBBY 2, RESTAURANT 2, BANQUET_1, BANQUET_2, PRE_FUNCTION), 8 kitchen |
| Setpoints | 24.0 °C — Lobby Area AHU-1, Seasons Restaurant AHU-1/-2, Banquet 2 AHU (versions 1–4) |
| Schedules | §2.3 intervals, all 7 days, out-of-hours on, **confirmed by hotel = off (provisional)** (versions 5, 7, 9, 11, 13, 15, 17) |
| Thresholds | §2.3 OFF/ON; **STANDBY = none for every AHU** (Banquet 1's 0.03 kW not configured); runtime on (versions 6, 8, …, 18) |
| Effective from | the save instant, 2026-11-19 08:13:42 IST (A19); not retrospective (A17, A23) |
| Audit | 44 `admin.audit_events` rows, all actor 1 / ADMIN / SUCCEEDED: 1 SITE_REPORT_ENROL, 2 SITE_REPORT_SCHEDULE_PAUSE, 23 SITE_REPORT_ROSTER_CHANGE, 18 REPORT_SETTING_CHANGE (each with previous/new values and effective_from) |
| Reports / attempts | 0 / 0 |
| Engine view | the worker's settings path resolves exactly these values for 20-Nov and none for 14-Nov |

**Consequence for the first report.** Because settings take effect from
19-Nov 08:13 IST and cannot be back-dated, a report for an earlier week (e.g.
8–14 Nov) would show "setpoint not configured", no out-of-hours split and
runtime "not reported". The week 15–21 Nov has the settings for part of the
week only. The first week with the full configuration in force throughout
is **22–28 Nov 2026**, which can be generated from Sun 29 Nov.

## 7. Automation account creation and validation record (staging, 2026-11-19)

**Creation.** Portal user **17**, `ww_report_automation_coimbatore`, created at
08:19:48 IST through `src.user_management_service.create_managed_user`, which
calls `admin.create_managed_portal_user`. The actor was portal user 1
(`admin_avinash`, ADMIN / GLOBAL), and the command ran inside the
admin-portal container. The password hash is Argon2id of
`secrets.token_urlsafe(64)`; the secret was deleted in-process and never
printed, logged, stored or committed. The hash value was never displayed in
any check.

| Check | Evidence | Result |
|---|---|---|
| Shape | ADMIN, SELECTED_SITES, organization Radisson Blu, active, email NULL, Argon2id hash, created_by 1 | PASS |
| Site restriction | `portal_user_site_access` = {Coimbatore} only | PASS |
| Option A check | `site_report_automation_problem(17, Coimbatore)` = NULL (accepted) | PASS |
| Site isolation | `portal_user_can_access_site`: Coimbatore true; Avinash Home / Unit 2 and Meenaxy Pharma / Unit 2 false. Catalogue for Coimbatore 1,590 rows; another organization's site 0 rows; report list for another organization's site 0 rows | PASS |
| Report management refused (`BEGIN … ROLLBACK`) | enrol, set automation account, resume schedule, change/remove roster asset, add/withdraw setting, generate, and every admin read: `42501 site_report_forbidden` | PASS |
| Report actions on a report | regenerate, retry, delete, restore, permanently delete: `P0002 site_report_not_found` (no report exists; the target is resolved before the staff check). With a real report, a non-GLOBAL ADMIN is refused `site_report_forbidden`: CI test `test_tenant_admin_cannot_change_roster_or_manage_reports` | PASS (covered) |
| View access (A5) | `list_portal_site_reports(17, Coimbatore)` allowed (0 rows) | PASS |
| Nothing persisted by the refusal block | designation NULL, weekly still paused, roster 23, settings 18, reports 0, attempts 0 | PASS |
| Interactive sign-in refused | Customer API `POST /auth/login` (same-origin) → 401 `invalid_credentials`, no cookie; Administration App `POST /login` → 401, no cookie. Each used a fresh random password | PASS |
| Audit | `admin.portal_user_audit` USER_CREATED (actor 1, target 17, role ADMIN, organization Radisson Blu, site_ids = {Coimbatore}); the payload has no `password_hash` key | PASS |

**Side effect of the sign-in checks:** `failed_login_count` = 2 (expected;
not locked; the automation checks do not depend on it). Failed sign-ins appear
in the application logs only (no `admin.audit_events` row), which is existing
EMS behaviour.

**Not done at this point:** designation (done later, §8); resuming automatic
schedules; customer test users; any report generation.

## 8. Automation account designation record (staging, 2026-11-19)

PO-approved. Portal user 17 was designated with
`analytics.set_site_report_automation_account(1, Coimbatore, 17)`, the
Reporting page's function, called via `site_report_service.set_automation_account`
with actor portal user 1. A pre-check required the profile to be enrolled,
undesignated and paused.

| Check | Evidence | Result |
|---|---|---|
| Saved assignment | `site_report_profiles.automation_portal_user_id` = 17; Administration App profile view: `automation_username` = ww_report_automation_coimbatore, `automation_problem` = none | PASS |
| Worker acceptance | the AUTOMATION branch of `site_report_read_identity_problem`, evaluated from the saved profile: `site_report_automation_problem(17, Coimbatore)` → accepted | PASS |
| Read identity data access | `get_portal_analytics_catalog(17, Coimbatore)` = 1,590 rows / 32 assets | PASS |
| Still Coimbatore only | ADMIN / SELECTED_SITES, active; `portal_user_site_access` = {Coimbatore}; accessible sites = {Coimbatore} of 3 | PASS |
| Audit | `SITE_REPORT_AUTOMATION_ACCOUNT_CHANGE`, actor 1 / ADMIN, SUCCEEDED, 08:25:18 IST, previous `{"automation_portal_user_id": null}` → new `{"automation_portal_user_id": 17}` | PASS |
| Still paused, nothing generated | weekly_enabled = false, monthly_enabled = false; reports 0, attempts 0; report-worker healthy, no attempt logged | PASS |

Remaining: resume automatic schedules (needs approval; resuming before
Sun 22 Nov 06:00 IST would schedule 15–21 Nov, which had the configuration
for part of the week only); customer test users; the first controlled report
(22–28 Nov recommended, generable from Sun 29 Nov).

## 9. Automatic schedule resume (PO-approved 2026-11-19: from Sun 22 Nov 2026 06:00 IST)

EMS has no future-dated resume: `set_site_report_schedule` takes effect at the
save instant and sets `*_resumed_at`. The scheduler skips any period whose
first-attempt time (period end + 6 h) is **at or before** `*_resumed_at`
(`schedule_due_site_reports`). Therefore:

| Period | First attempt | Effect of a resume at ≥ 22 Nov 06:00:00 IST |
|---|---|---|
| Weekly 15–21 Nov | Sun 22 Nov 06:00 IST | **skipped, never generated (no back-fill)**. A resume even 1 s earlier would schedule it |
| Weekly 22–28 Nov | Sun 29 Nov 06:00 IST | scheduled (first automatic report) |
| Monthly November | Tue 1 Dec 06:00 IST | scheduled |

**State on 2026-11-19:** both schedules **paused** (weekly_enabled =
monthly_enabled = false); reports 0, attempts 0.

**Mechanism:** a guarded script calls `site_report_service.set_schedule(1, Coimbatore, WEEKLY|MONTHLY, true)`
(audited `SITE_REPORT_SCHEDULE_RESUME`). It **refuses before
2026-11-22 06:00:00 IST by the database clock**; this was proven on
2026-11-19 08:28 IST, when it refused and wrote nothing. The run is scheduled
for 06:03 IST, to stay clear of the boundary, as a one-shot in the operator's
Claude Code session. That timer exists only while the session is open; if it
does not run, a WiseWatts Admin presses *Resume* for Weekly and Monthly on
Site → Reporting at or after 06:00 IST, which is equivalent.

**Post-resume verification (read-only):** both enabled with `*_resumed_at` ≥
06:00 IST; two resume audit events; after the worker's next scheduling pass
(≤ 5 min), no report or attempt for 15 Nov.

## 10. Radisson test users (staging only, PO consolidated authorization 2026-11-19)

Created 08:32 IST through `create_managed_user` → `admin.create_managed_portal_user`
(actor portal user 1), scope SELECTED_SITES in Radisson Blu with Coimbatore
only, no email. Passwords are random (20 characters), hashed with Argon2id,
and handed to the Product Owner in a private file outside the repository.
They are never committed or logged.

| portal_user_id | username | role |
|---|---|---|
| 18 | `radisson_test_admin` | ADMIN |
| 19 | `radisson_test_operator` | OPERATOR |
| 20 | `radisson_test_viewer` | VIEWER |

| Check | Admin / Operator / Viewer | Result |
|---|---|---|
| Shape | active, Radisson Blu, SELECTED_SITES, sites = {Coimbatore}, accessible = {Coimbatore}, Argon2id | PASS |
| Audit | `portal_user_audit` USER_CREATED ×3, actor 1, no `password_hash` key | PASS |
| DB management functions (`BEGIN … ROLLBACK`) | 12/12 each → `42501 site_report_forbidden` (enrol, automation account, schedule, roster, settings, generate, admin reads) | PASS |
| DB view functions | Coimbatore list and schedule allowed; another organization's site 0 rows | PASS |
| Customer API sign-in | 200, `ems_session` cookie Secure, HttpOnly, SameSite | PASS |
| `/api/v1/me` | `report.view` present (ADMIN 15 permissions, OPERATOR 12, VIEWER: dashboard.view, report.export, report.view) | PASS |
| History Coimbatore | 200 (enrolled, weekly/monthly paused, 0 reports) | PASS |
| Other organization's site / unknown versions / unknown download | 404 / 404 / 404 | PASS |
| Report writes via the customer API | POST site-reports 405; DELETE 404; admin generate path 404 | PASS |
| Administration App reporting pages and actions | GET reporting/reports 403; POST generate, schedule, delete, purge 403 (ADMIN, OPERATOR) or 303 → /forbidden (VIEWER) | PASS |
| **Administration App general access** | **sign-in succeeds (303 → /administration/sites) and Sites pages return 200**, because `EMS_ADMIN_STAFF_ONLY` is off on staging (the default) | **FINDING** (see below) |

**Finding — staff-only Administration App not enforced on staging.**
ADR-023's switch `EMS_ADMIN_STAFF_ONLY` is unset on staging (default
false), so customer identities can sign in to the Administration App and
browse its general pages, such as Sites. Every reporting page and action is
still refused, by the route check (`_staff()`) and in the database. Enabling
the switch is a staging configuration change outside this authorization.

## 11. Deployment-script fix (PR #183)

| Item | Value |
|---|---|
| PR | #183, squash-merged to `staging` as `400608b`; CI on head `ff52045` 14/14 green (including the full backend suite) |
| Staging deploy | Deploy to Staging run 44448407754: success. The fixed `deploy_web.sh` check: `[1/5] Checking the deployed compose configuration... OK`; ems-web healthy |
| Customer API deploy | run 44450767646: success. The fixed `deploy_customer_api.sh` precondition passed; `ems-customer-api` healthy on `400608b` |

## 12. Comparison configuration-gap disclosure (PR #184, engine 1.1.0)

The PO requires the first report's comparison limitation (15–21 Nov, settings
in force only from 19 Nov 08:13) to be clearly disclosed. PR #184 applies
the A109 comparison disclosure to settings not in force throughout the
comparison period (spec §6.5): † on comparison temperature, runtime and
out-of-hours figures, a note naming the settings and their start, and
"Comparison incomplete" in history. No calculation, threshold or
publication rule changes.

| Item | Value |
|---|---|
| PR | #184, squash-merged as `3a270cd`; CI 14/14 green |
| Staging deploy | run 44452477090: success; report-worker and admin-portal on `3a270cd`, worker `ENGINE_VERSION` 1.1.0 |
| State after deploy | automation account 17; weekly and monthly still paused; 18 ACTIVE settings; no STANDBY threshold set; 0 reports, 0 attempts |

## 13. Pending timed steps

- **Sun 22 Nov 06:03 IST:** guarded resume of weekly and monthly (§9), then verification.
- **Sun 29 Nov:** the worker's automatic attempt for 22–28 Nov (first attempt
  06:00, generated by 12:00 at the latest after the data-completeness wait),
  then full first-report validation (scheduled 12:41 IST).
