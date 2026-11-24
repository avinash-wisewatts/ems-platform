# WiseWatts EMS — WhatsApp Alert Notifications — PRD (Draft 0.1)

> **Record note (2026-11-23).** This is the Product Owner's PRD as received
> on 2026-11-23, kept verbatim as the source record. It is **Proposed**, not
> decided. It authorises no database, API, UI, infrastructure or production
> change (its own §16). The engineering intake review — how it maps onto the
> ADR-024 alert-rule model, the conflicts found and the decisions needed — is
> in [README.md](README.md); dated clarifications (including the outdated §16)
> are in [prd-draft-0.1-addendum-2026-11-23.md](prd-draft-0.1-addendum-2026-11-23.md),
> never edited into the text below; the proposed architecture decision is
> [ADR-026](../../../00-governance/decisions/ADR-026-whatsapp-alert-notifications.md).
> Where this PRD says "alert", the ADR-024 model calls it an **alert rule**;
> "a triggered alert" is a rule's **occurrence** becoming Active.

---

**Status:** Proposed — Product Owner direction captured  
**Version:** Draft 0.1  
**Product:** WiseWatts Energy Management System  
**Module:** EMS → Alerts  
**Feature:** WhatsApp Notifications  
**Scope:** Individual WhatsApp recipients, configured independently for each alert

---

## 1. Executive Summary

WiseWatts EMS will support sending alert notifications to individual WhatsApp phone numbers.

Authorised administrators will be able to enable or disable WhatsApp notifications for each individual alert and configure multiple recipient phone numbers for that alert.

The configuration will be available in the existing EMS Alerts module.

The initial release will use direct phone-number entry within each alert configuration. The architecture should allow a reusable contact directory and more advanced recipient management to be introduced later.

The feature will supplement the existing in-product alert experience. It will not replace the alert engine or existing alert history.

## 2. Business Objective

The objective is to ensure that relevant site stakeholders receive timely notifications about significant energy and electrical-performance conditions without having to continuously monitor the EMS application.

The feature should:

- Improve awareness of important site conditions.
- Make alert delivery configurable at an individual alert level.
- Support multiple recipients for each alert.
- Give site administrators control over notification recipients.
- Provide WiseWatts administrators with cross-site configuration capabilities.
- Preserve the existing alert-generation and analytical experience.

## 3. Product Decisions and Scope

### 3.1 Confirmed product decisions

| Area | Decision |
|---|---|
| Notification channel | WhatsApp |
| Recipient type | Individual phone numbers |
| Configuration location | EMS → Alerts |
| Configuration level | Individual alert |
| WhatsApp activation | Checkbox on each alert |
| Recipients | Multiple phone numbers per alert |
| Initial contact management | Direct phone-number entry |
| Delivery | Individual message to each configured number |
| Site Admin | Can configure alerts within authorised sites |
| WiseWatts Global Site Admin | Can configure alerts across all sites |
| Future extensibility | Reusable contact directory and multiple recipient-routing options |

### 3.2 Initial release scope

Included:

1. Enable or disable WhatsApp notifications for an alert.
2. Add multiple recipient phone numbers.
3. Edit and remove recipient numbers.
4. Save recipient configuration against the individual alert.
5. Send alert notifications to configured numbers.
6. Record individual delivery outcomes.
7. Enforce role-based and site-based permissions.
8. Provide appropriate validation and error handling.

### 3.3 Out of scope for the initial release

- WhatsApp group messaging.
- Reusable contact directory.
- Advanced notification routing.
- Escalation workflows.
- Scheduled notifications.
- Customer-configurable notification priorities.
- Alert acknowledgement through WhatsApp.
- Two-way WhatsApp conversations.
- AI-generated alert interpretation or recommendations.
- Intelligent notification suppression beyond basic duplicate prevention.

## 4. User Roles and Permissions

Two EMS roles will manage this capability.

### 4.1 Site Admin

A Site Admin can:

- View alerts belonging to authorised sites.
- Enable or disable WhatsApp notifications for an alert.
- Add multiple WhatsApp phone numbers.
- Edit existing phone numbers.
- Remove phone numbers.
- Save alert notification configuration.
- View delivery history for authorised sites.

A Site Admin must not be able to modify alerts belonging to sites outside their authorised scope.

### 4.2 WiseWatts Global Site Admin

A WiseWatts Global Site Admin can:

- View alerts across all customer sites.
- Enable or disable WhatsApp notifications.
- Configure multiple recipients for individual alerts.
- Edit and remove recipient numbers.
- View notification configuration across sites.
- View delivery history across sites.

### 4.3 Permission enforcement

All permissions must be enforced by the backend.

Frontend visibility and navigation restrictions are not sufficient security controls.

Every configuration read and write must validate the user's role, organisation and site access.

## 5. Functional Requirements

### FR-01: WhatsApp notification checkbox

Every configurable alert must expose:

**Enable WhatsApp Notifications**

Behaviour:

- Default state: disabled.
- When unchecked, no WhatsApp notifications are sent for that alert.
- When checked, the recipient-number configuration becomes available.
- The setting must be saved against the individual alert.
- Disabling WhatsApp must not disable the underlying alert or its in-product presentation.

### FR-02: Multiple recipient phone numbers

When WhatsApp notifications are enabled, the administrator must be able to enter multiple phone numbers.

Each recipient entry must:

- Accept an international phone number.
- Include a country calling code.
- Be validated before saving.
- Be individually editable.
- Be individually removable.

The administrator must be able to add additional recipient numbers without replacing existing numbers.

### FR-03: Save configuration

The administrator must be able to save:

- WhatsApp enablement status.
- All configured recipient numbers.

The system must validate the configuration before saving.

Recommended validation:

- Reject invalid phone-number formats.
- Prevent duplicate numbers within the same alert.
- Require at least one valid recipient when WhatsApp is enabled.
- Display a clear confirmation after successful saving.
- Preserve existing saved configuration if a save operation fails.

### FR-04: Alert-to-recipient association

Recipient numbers must be associated with the individual alert being configured.

For example:

- Maximum Demand Exceeded → three recipient numbers.
- Power Factor Below Threshold → two different recipient numbers.
- THD Exceeded → WhatsApp disabled.

Changing the recipient list for one alert must not unintentionally modify another alert's recipients.

### FR-05: WhatsApp delivery

When an alert is triggered:

1. The alert engine generates the alert using the existing analytical condition.
2. The notification service checks whether WhatsApp is enabled for that alert.
3. The service retrieves the configured recipient numbers.
4. It sends a separate WhatsApp message to each eligible recipient.
5. It records the outcome of each delivery attempt.

A failure to deliver to one recipient must not prevent delivery to the other recipients.

### FR-06: Delivery history

The system should maintain delivery records containing:

- Alert reference.
- Site reference.
- Recipient phone number.
- Notification creation timestamp.
- Delivery attempt timestamp.
- Provider message identifier, where available.
- Delivery status.
- Failure reason, where available.

Suggested statuses:

- Pending
- Submitted
- Sent
- Delivered
- Failed

The exact status mapping must follow the selected WhatsApp provider's delivery callbacks and terminology.

## 6. EMS User Interface Requirements

### 6.1 Location

The feature will be available within:

**EMS → Alerts → Individual Alert → Notification Configuration**

It should be part of the existing alert configuration experience, not a separate notification-management application.

### 6.2 Proposed interface

**Alert: Maximum Demand Exceeded**

WhatsApp Notifications

[ ] Enable WhatsApp Notifications

When selected:

**Recipient Phone Numbers**

| Recipient | Action |
|---|---|
| +91 98765 43210 | Edit / Remove |
| +91 98765 12345 | Edit / Remove |

[+ Add Phone Number]

[Save Configuration]

The actual UI should follow the existing EMS design system and interaction patterns.

### 6.3 Interaction behaviour

- The recipient section remains hidden or disabled when WhatsApp is unchecked.
- Selecting the checkbox reveals the recipient editor.
- Add Phone Number creates another recipient entry.
- Remove deletes the selected entry from the pending configuration.
- Save persists the complete configuration.
- Unsaved changes must be distinguishable from saved configuration.
- Validation errors must be displayed next to the relevant field.

### 6.4 Delivery history

The alert detail experience should provide access to notification delivery history.

A delivery record should identify which recipients received the message and which deliveries failed.

## 7. WhatsApp Message Requirements

Messages should be concise, operationally useful and consistent with the existing alert content.

An alert message should communicate:

- What happened.
- Which site is affected.
- When it happened.
- The relevant measured value.
- The configured threshold, where applicable.
- A link to the relevant EMS analytical experience.

### Example

**WiseWatts Alert — Maximum Demand Exceeded**

Site: Hyderabad Manufacturing Facility

Maximum Demand: 485 kVA  
Configured Threshold: 450 kVA

Status: Threshold exceeded

Time: 23 November 2026, 3:45 PM IST

Please investigate the site's demand performance.

View Alert: [Secure EMS Link]

Messages must not expose credentials, sensitive internal identifiers or unnecessary technical implementation details.

WhatsApp template requirements, approval and message-format constraints must be validated with the selected provider before implementation.

## 8. Technical Architecture Requirements

### 8.1 Architectural approach

WhatsApp delivery should be implemented as a backend notification capability.

The EMS frontend must not communicate directly with the WhatsApp provider or contain provider credentials.

Proposed flow:

```text
Existing Alert Engine
        |
        v
Alert Triggered
        |
        v
WhatsApp Notification Eligibility
        |
        v
Load Alert Configuration
        |
        v
Load Recipient Phone Numbers
        |
        v
Notification Service
        |
        v
WhatsApp Business Provider
        |
        v
Individual Recipients
        |
        v
Delivery Status Tracking
```

### 8.2 Configuration write path

The existing EMS architecture defines the customer-facing application as read-only through the Analytics API.

This feature introduces a customer-facing configuration capability.

Therefore, an explicit architecture decision is required for an authorised backend write path.

The implementation must:

- Preserve the Analytics API boundary for analytical reads.
- Use a dedicated authorised backend mechanism for alert configuration writes.
- Enforce organisation and site permissions server-side.
- Apply the existing permission-check and audit principles.
- Avoid direct frontend database access.
- Avoid changes to the frozen platform architecture without an explicit decision.

The EMS UI location does not imply that the frontend should own the persistence or delivery logic.

### 8.3 Conceptual data model

The following describes the required logical information, not an approved database schema.

**Alert WhatsApp Configuration**

- Configuration identifier.
- Alert identifier.
- Enabled status.
- Created by.
- Updated by.
- Created timestamp.
- Updated timestamp.

**Alert WhatsApp Recipients**

- Recipient identifier.
- Alert configuration identifier.
- Phone number in international format.
- Verification status, if implemented.
- Consent status, if implemented.
- Active/inactive status.
- Created timestamp.
- Updated timestamp.

**WhatsApp Delivery Records**

- Delivery identifier.
- Alert occurrence identifier.
- Recipient identifier.
- Provider message identifier.
- Delivery status.
- Attempt count.
- Last attempt timestamp.
- Failure details.
- Created timestamp.

The logical model should support multiple recipient records per alert from the beginning.

Do not hardcode a single recipient field into the alert record.

### 8.4 Reliability and duplicate prevention

The notification service should support:

- Idempotent processing.
- Duplicate delivery prevention.
- Retry of transient provider failures.
- Independent delivery tracking for each recipient.
- Protection against repeated notification storms.
- Provider timeout and error handling.

Retry rules and duplicate-suppression windows require technical design before implementation.

### 8.5 Security and privacy

- Provider credentials must remain server-side.
- Phone numbers must be protected as personal information.
- Access to recipient configuration must be permission-controlled.
- Configuration changes must be auditable.
- Recipient consent and WhatsApp eligibility must be addressed.
- Delivery history should be available only to authorised users.
- Phone numbers should be masked where full display is unnecessary.

## 9. External WhatsApp Integration

The preferred integration direction is the official WhatsApp Business Platform Cloud API or an approved Business Solution Provider.

Before selecting the provider, validate:

1. Business account and number requirements.
2. Template approval requirements.
3. Recipient opt-in and consent requirements.
4. Message delivery callbacks.
5. Pricing and message categories.
6. Rate limits and throughput.
7. Retry and error semantics.
8. Regional availability and operational support.

Provider selection is not yet a confirmed product decision.

## 10. Non-Functional Requirements

### Security
- Tenant isolation must be preserved.
- Site Admin access must remain site-scoped.
- Global Site Admin access must be appropriately authorised.
- Provider secrets must never reach the browser.

### Reliability
- One recipient's failure must not block other recipients.
- Failed delivery attempts must be traceable.
- Retries must not create uncontrolled duplicate messages.

### Auditability
- Record who changed notification configuration.
- Record when configuration was changed.
- Record recipient additions and removals.
- Record delivery outcomes.

### Usability
- The configuration must be understandable without technical WhatsApp API knowledge.
- Phone-number validation must provide clear feedback.
- Saving must provide clear success or failure feedback.

### Extensibility
The initial implementation should support future additions such as:

- Reusable contact directory.
- Recipient groups.
- Multiple delivery channels.
- Advanced routing rules.
- Additional notification preferences.

These future capabilities must not complicate the initial user experience unnecessarily.

## 11. Acceptance Criteria

The feature can be considered functionally complete when:

1. An authorised Site Admin can open an alert belonging to an authorised site.
2. The Site Admin can enable WhatsApp notifications for that alert.
3. The Site Admin can add multiple valid international phone numbers.
4. The Site Admin can edit and remove recipient numbers.
5. The Site Admin can save the configuration.
6. The configuration persists when the user returns to the alert.
7. A different alert retains its own independent WhatsApp configuration.
8. Disabling WhatsApp stops future WhatsApp deliveries for that alert without disabling the underlying alert.
9. A triggered alert is sent to every configured eligible recipient.
10. Delivery failure for one number does not prevent delivery to other numbers.
11. Delivery status is recorded per recipient.
12. A Site Admin cannot modify another site's configuration without permission.
13. A WiseWatts Global Site Admin can configure alerts across sites.
14. Provider credentials and sensitive configuration are never exposed to the frontend.
15. Repeated processing of the same alert occurrence does not cause uncontrolled duplicate notifications.

## 12. Dependencies

The feature depends on:

- Existing alert-generation capability.
- Existing alert configuration and persistence model.
- Defined EMS Site Admin and WiseWatts Global Site Admin permissions.
- An approved backend configuration write path.
- WhatsApp Business provider selection.
- Business account onboarding and message-template approval, where required.
- Recipient consent and verification design.
- Notification delivery and callback processing.

## 13. Risks

| Risk | Mitigation |
|---|---|
| WhatsApp provider restrictions | Validate API and business requirements before development |
| Invalid recipient numbers | Validate international number formats |
| Recipients have not opted in | Implement consent capture and eligibility checks |
| Duplicate messages | Idempotent notification processing |
| Provider outage | Retry transient failures and retain delivery history |
| Incorrect site permissions | Enforce permissions on backend |
| Future contact management complexity | Keep recipient records separate from alert definitions |

## 14. Delivery Phases

### Phase 1 — Configuration

- Alert-level WhatsApp checkbox.
- Multiple phone-number entry.
- Validation.
- Save and retrieve configuration.
- Site Admin and Global Site Admin permissions.

### Phase 2 — WhatsApp integration

- Provider integration.
- Approved message templates.
- Notification dispatch.
- Individual recipient delivery.
- Provider callback processing.

### Phase 3 — Operational readiness

- Delivery history.
- Failure handling.
- Retry and duplicate prevention.
- Audit logging.
- Security and permission testing.

### Future — Enhanced recipient management

- Reusable contact directory.
- Contact selection instead of repeated phone-number entry.
- Recipient groups.
- Multiple notification destinations.
- Advanced routing and preferences.

## 15. Open Decisions Before Implementation

The following items need explicit confirmation or technical validation:

1. **Provider:** WhatsApp Business Cloud API directly or an approved provider.
2. **Number verification:** Whether recipients must complete a verification process before activation.
3. **Consent:** How recipient opt-in is captured and retained.
4. **Alert scope:** Whether all existing alert types are eligible or only significant alerts initially.
5. **Repeat notifications:** Whether repeated occurrences of the same active condition should generate another message, and under what cooldown.
6. **Recovery messages:** Whether a separate notification should be sent when an alert condition returns to normal.
7. **Configuration write path:** The specific authorised backend mechanism and API contract.
8. **Template governance:** Who approves and maintains WhatsApp templates.

These are not assumed to be settled by the product decisions captured so far.

## 16. Relationship to Existing Product Baseline

The existing WiseWatts workshop baseline defines MVP alert delivery as in-product notifications and email, with WhatsApp deferred.

It also establishes the original configuration boundary in which the WiseWatts Admin Portal owns facility configuration and the customer EMS primarily consumes configured information.

This PRD captures a subsequent Product Owner direction to introduce WhatsApp delivery and manage its configuration within the EMS Alerts module.

Therefore, this requirement must be incorporated into the formal product documentation and architecture decision process before implementation.

No database, API, UI, infrastructure or production changes are authorised by this PRD alone.

---

**End of Document**

**Document owner:** WiseWatts Product  
**Review participants:** Product Owner, EMS Architecture, Backend Engineering, Frontend Engineering, QA and Operations  
**Next milestone:** Product and architecture review, followed by implementation planning.
