# WhatsApp opt-in confirmation wording — register

Status: **`WA-OPTIN-1` approved by the Product Owner on 2026-11-24, subject to
Legal review (L-1).** Migration 332 loads it marked **Legal review
PENDING**, and **new opt-ins stay closed until Legal approves it**
(`whatsapp_consent_legal_review_pending`; Product Owner, 2026-11-24).
Migration 332 is **not yet deployed**.

This is the documentation record of each approved version of the statement
an administrator confirms when adding a WhatsApp recipient (decision D21:
WiseWatts Product defines and approves the exact wording before it is used).
Each approved version is also loaded, by migration, into
`analytics.alert_whatsapp_consent_statements`. Every consent records the
version **and the business name** it was given under, so the stored evidence
is the full text the administrator confirmed.

Rules:
- A version is used only after Product approval is recorded here, with the
  approver and the date.
- Legal review of sufficiency is a separate column (L-1). Product approval
  does not imply Legal sign-off. In the database each version carries
  `legal_review_status` (`PENDING` or `APPROVED`, with reviewer and date).
  New opt-ins are accepted only under an `APPROVED` version. Recording
  Legal's approval is a separate, separately approved migration.
- Approved text is never edited. A change is a new version, and the old one
  is retired. Existing consents keep the version they were given under.
- **R9 (decided 2026-11-24):** the wording names the **customer business**
  as the alert originator, and WiseWatts as the technology and delivery
  platform. `{business_name}` is replaced with the customer organisation's
  recorded legal name (`metadata.organizations.legal_name`). If no legal
  name is recorded, the wording cannot be shown, and new opt-ins are refused
  (`whatsapp_business_name_missing`).
- **D21 conditions:** explicit individual recipient consent is mandatory (one
  confirmation per new or changed number), for operational notifications
  only, with no marketing messages.
- Meta requires the opt-in to say that the person agrees to receive messages
  from the business over WhatsApp, and to **name the business** (desk
  research, review §3). Whether WA-OPTIN-1 meets this, and the DPDP Act
  notice and record requirements, is for Legal (L-1;
  [legal-review-package.md](legal-review-package.md)).

| Version | Statement text (as stored; `{business_name}` is filled per customer) | Product approval (who, date) | Legal review (L-1) | Status |
|---|---|---|---|---|
| `WA-OPTIN-1` | I confirm that this person has explicitly agreed to receive operational alert notifications from {business_name} on WhatsApp at this number. These messages are delivered by WiseWatts as {business_name}'s technology platform. No marketing messages will be sent. | Product Owner, 2026-11-24 (with R9) | **Pending** ([legal-review-package.md](legal-review-package.md)) | Product-approved; loaded by migration 332 as `PENDING` (not yet deployed); opt-ins closed |

Example as shown to an administrator, for a fictional customer "Example
Hotels Pvt Ltd":

> I confirm that this person has explicitly agreed to receive operational
> alert notifications from Example Hotels Pvt Ltd on WhatsApp at this number.
> These messages are delivered by WiseWatts as Example Hotels Pvt Ltd's
> technology platform. No marketing messages will be sent.
