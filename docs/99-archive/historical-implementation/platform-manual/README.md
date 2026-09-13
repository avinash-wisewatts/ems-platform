# EMS Platform Architecture & Operations Manual

Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository, Staging, Production read-only, Audit evidence

## What this is

A human-readable technical reference explaining how the WiseWatts EMS
(Energy Management System) platform's repository components fit together
and how the platform actually behaves, as implemented and verified. It is
**not** a second source of truth for configuration — every document below
points back to the repository files, live database objects, or Audit
evidence that back its claims. When the manual and the repository disagree
about *mechanics*, the repository wins; this manual should be corrected.
When the manual and a **live environment** (staging/production) disagree,
that is drift, and is documented as drift rather than silently reconciled.

## How to read this manual

Every document opens with a status block:

```
Status: CURRENT / PARTIAL / HISTORICAL
Last verified: YYYY-MM-DD
Verification basis: Repository | Staging | Production read-only | Audit evidence
```

`CURRENT` means the content reflects what was actually checked (repo and/or
live) as of the date shown. `PARTIAL` means some sections are verified and
others are inferred or unknown — read carefully, the document says which is
which. `HISTORICAL` means the document is a record of past investigation,
not a claim about today's state.

## Document index

### Core architecture
- [01-system-overview.md](01-system-overview.md) — what the platform is, who it's for, top-level components
- [02-architecture.md](02-architecture.md) — component/dependency diagram, source-of-truth map
- [03-infrastructure.md](03-infrastructure.md) — deployment topology, current vs. planned
- [04-docker-services.md](04-docker-services.md) — every Compose service in detail

### Data and telemetry
- [05-database.md](05-database.md) — schema map (metadata/config/telemetry/analytics)
- [06-data-model.md](06-data-model.md) — organization → site → gateway → device → asset model
- [07-telemetry-pipeline.md](07-telemetry-pipeline.md) — physical device → Grafana, stage by stage
- [08-device-onboarding.md](08-device-onboarding.md) — how a device gets created and wired up
- [09-asset-model.md](09-asset-model.md) — assets, asset types, asset-device relationships
- [10-analytics.md](10-analytics.md) — the semantic/analytics layer
- [11-aggregation.md](11-aggregation.md) — 1m/5m/15m/1h/1d aggregation architecture
- [15-mqtt-and-telegraf.md](15-mqtt-and-telegraf.md) — MQTT ingestion and Telegraf configuration
- [16-commissioning.md](16-commissioning.md) — commissioning vs. onboarding vs. "producing telemetry"

### Presentation and access
- [12-grafana.md](12-grafana.md) — Grafana architecture, provisioning, dashboards
- [13-admin-portal.md](13-admin-portal.md) — admin portal architecture
- [14-authentication-and-tenancy.md](14-authentication-and-tenancy.md) — tenant isolation model
- [20-security.md](20-security.md) — security boundaries and posture

### Delivery and operations
- [17-cicd-and-deployment.md](17-cicd-and-deployment.md) — CI/CD pipeline
- [18-environment-management.md](18-environment-management.md) — env file boundaries
- [19-operations-and-diagnostics.md](19-operations-and-diagnostics.md) — health checks, verification commands
- [21-backup-and-recovery.md](21-backup-and-recovery.md) — backup/recovery posture
- [22-performance.md](22-performance.md) — query performance architecture and evidence
- [23-known-issues-and-drift.md](23-known-issues-and-drift.md) — catalogued drift and open issues
- [24-troubleshooting.md](24-troubleshooting.md) — practical failure-mode playbook
- [25-change-history.md](25-change-history.md) — HISTORICAL narrative timeline (Phase 0 → present)

### Reference catalogs
- [reference/database-object-catalog.md](reference/database-object-catalog.md)
- [reference/service-port-map.md](reference/service-port-map.md)
- [reference/environment-matrix.md](reference/environment-matrix.md)
- [reference/telemetry-field-catalog.md](reference/telemetry-field-catalog.md)
- [reference/grafana-dashboard-catalog.md](reference/grafana-dashboard-catalog.md)
- [reference/configuration-catalog.md](reference/configuration-catalog.md)

## Source-of-truth summary

See [02-architecture.md](02-architecture.md) for the full "Where to Look"
table. In short: this manual explains *how things fit together*; the
repository (`postgres/`, `compose.yaml`, `grafana/`, `.github/workflows/`)
is authoritative for *exact configuration*; `Audit/` is a historical
investigation record, not current truth; and the live staging/production
databases are authoritative for *current runtime state*, which this manual
notes as of specific verification dates, not continuously.

## Keeping this manual current

This manual is a maintained engineering artifact, not a one-time export. It
should be updated whenever a change to the repository, configuration, or a
verified live-environment finding materially changes what one of these
documents claims. Update the `Last verified` date and `Verification basis`
whenever a document's claims are re-checked, even if nothing changed.

**Source-of-truth priority when evidence conflicts** (highest first):
1. Live database / live application behavior, when explicitly verified
2. Current repository implementation
3. Current deployment/configuration files
4. Existing platform-manual documentation
5. `Audit/` folder investigations and historical documents
6. Historical assumptions / old investigation notes

Never silently reconcile a contradiction. Record it as:
```
CURRENT IMPLEMENTATION: <what's actually true now, with evidence>
HISTORICAL / REPOSITORY EXPECTATION: <what an older source claimed>
CHANGE: <what happened between the two, if known>
VERIFICATION: <how/when this was checked, and by what method>
```
Historical findings are preserved, not overwritten — mark them `HISTORICAL`,
`SUPERSEDED`, `RESOLVED`, `DRIFT`, or `UNKNOWN` rather than deleting them.
`Audit/` is evidence, never an automatic source of truth — reconcile it
against current repo/staging/production state before treating it as current.

**A change in one area should trigger a review of related documents** — a
schema change touches [05-database.md](05-database.md)/[06-data-model.md](06-data-model.md)
and onboarding/telemetry docs if applicable; a telemetry-pipeline change
touches [07-telemetry-pipeline.md](07-telemetry-pipeline.md),
[11-aggregation.md](11-aggregation.md), [10-analytics.md](10-analytics.md),
[12-grafana.md](12-grafana.md); a deployment/infra change touches
[03-infrastructure.md](03-infrastructure.md), [17-cicd-and-deployment.md](17-cicd-and-deployment.md),
[reference/environment-matrix.md](reference/environment-matrix.md),
[reference/service-port-map.md](reference/service-port-map.md); an
onboarding/commissioning change touches [08-device-onboarding.md](08-device-onboarding.md),
[16-commissioning.md](16-commissioning.md); a Grafana/dashboard change touches
[12-grafana.md](12-grafana.md), [reference/grafana-dashboard-catalog.md](reference/grafana-dashboard-catalog.md).
Update [23-known-issues-and-drift.md](23-known-issues-and-drift.md)'s tracked-items
index whenever an open item is opened, re-scoped, or genuinely resolved (with
evidence — not on the strength of a report alone), and log every meaningful
change in [25-change-history.md](25-change-history.md). Skip updates for
trivial, non-architectural implementation changes — this is an engineering
manual, not a commit diary.
