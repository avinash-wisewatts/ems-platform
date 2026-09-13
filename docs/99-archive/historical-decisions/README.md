# Historical Decisions — DDS Evidentiary Record

Status: HISTORICAL · Archived 2026-09-13

These two documents are the frozen DDS architecture's own **evidentiary
record** — the concrete evidence and corrections behind the conceptual
model, not a decision output in their own right. Per the frozen
architecture document's own framing: "the standalone review and stress-test
documents remain as the evidentiary record of *why* each correction was
made, but [the main architecture] document is the single authoritative
statement of *what* the architecture is."

| Document | Role |
|---|---|
| [analytics-platform-future-state-architecture-review.md](analytics-platform-future-state-architecture-review.md) | Red-team review — validated the initial architecture proposal against the live schema and corrected it. |
| [analytics-platform-future-state-architecture-stress-test.md](analytics-platform-future-state-architecture-stress-test.md) | Ten-scenario practical validation (motor, chiller, refrigeration, AHU/spaces, solar+battery, etc.) against real equipment/energy cases — corrected the model a second time. |

Every correction from both documents is already folded into
`docs/DDS/analytics-platform-future-state-architecture.md`, which remains
at its current path — see
[../../00-governance/source-of-truth.md](../../00-governance/source-of-truth.md).
See [../../00-governance/decisions/](../../00-governance/decisions/) for
the formal decision records extracted from the frozen model these two
documents helped shape.
