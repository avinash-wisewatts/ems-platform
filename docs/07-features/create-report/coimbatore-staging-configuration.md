# Create report — Radisson Blu Coimbatore staging configuration and automation-account plan

Status: **prepared, not applied** (2026-11-19). Nothing in this document has
been written to staging. Applying §2 (configuration) and §3 (automation
account) each needs explicit authorization. Production is out of scope (A106).

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
| Banquet 1 AHU | 06:00–22:00 | 0.005 | 0.03 | 0.60 | on | High (ON/OFF); Low–Medium (STANDBY) |
| Banquet 2 AHU | 06:00–22:00 | 0.05 | — | 0.85 | on | High |
| Pre Function Area AHU | 06:00–22:00 | 0.05 | — | 0.80 | on | High |

Data-quality thresholds are fixed in code and shown read-only (A11). They are
not configured here.

### 2.4 Post-configuration verification (read-only)

- 23 roster rows: 2 chillers, 4 pumps, 2 cooling towers, 7 AHUs with the areas above, 8 kitchen.
- 4 setpoint, 7 schedule and 7 threshold versions, ACTIVE, `effective_from` = save instant.
- One `admin.audit_events` row per write, with the WiseWatts Admin as actor.
- `analytics.get_site_report_worker_settings` returns the same values.

## 3. Automation account plan (A88–A90, A108 Option A) — NOT created

| Attribute | Value |
|---|---|
| Username | `ww_report_automation_coimbatore` (proposed) |
| Display name | `WiseWatts report automation (Coimbatore)` (proposed) |
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
- **Banquet 1 STANDBY threshold** has Low–Medium confidence (tool evidence).
- **First automatic attempt timing:** see §2.1.
