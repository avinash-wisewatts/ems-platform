# Migration 015 — Complete Asset Dashboard V1 contract

This forward migration and dashboard rebuild implement the agreed Asset Dashboard V1 from scratch while preserving the existing dashboard UID for links/reconciliation.

The dashboard separates instantaneous power from canonical interval demand and covers identity/context, electrical KPIs, demand, energy performance with previous-period comparison, explicit operating-state/utilization telemetry, electrical health, assigned devices, demand capability/quality and alarms.

Unsupported telemetry is allowed to remain unavailable. The dashboard does not invent operating state, kVA demand, THD or other metrics when the mapped device does not provide them.

Deferred from this V1: cost, carbon/emissions, energy intensity, composite health score and generic data-quality score.
