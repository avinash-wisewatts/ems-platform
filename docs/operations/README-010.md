# Migration 010 — Effective policy look-back

This is a narrow normalization efficiency cleanup after migration 009.

It does not change capture selection, site-frequency normalization, late-arrival semantics, routing, retention, connectivity, failure classification, or recovery.

The loader previously sized its dynamic replay/look-back window from every enabled capture-policy row, including policy history that ended days earlier. Historical rows remain necessary for event-time policy resolution, but should stop influencing future scan windows once their effective window plus their own capture interval and late-arrival allowance is fully behind the normalization checkpoint.

Migration 010 changes only the dynamic overlap calculation so that a policy contributes when:
- it started by the current raw head; and
- it is current/open-ended, or its `effective_to + capture_interval + late_arrival_tolerance` has not yet passed the previous normalization checkpoint.

This preserves safe processing around policy transitions while preventing stale 900-second historical tolerances from forcing a large look-back forever.
