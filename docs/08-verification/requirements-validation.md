# Requirements Validation

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering

The live-verified build status of every product requirement and workshop
decision lives in
[../02-requirements/requirements-traceability.md](../02-requirements/requirements-traceability.md) —
not duplicated here. That document's §4 ("Status update, 2026-09-13")
records the most recent re-verification against `origin/staging` commit
`ddbe5a4`.

## How requirements get validated

1. A requirement (`EMS-REQ-nnn`) or workshop decision (`Qn`) is traced to a
   screen, an API capability, and a semantic/data capability — see the
   traceability chain in
   [../02-requirements/requirements-traceability.md](../02-requirements/requirements-traceability.md) §1.
2. When a capability lands, its status moves from `MISSING`/`PLANNED` to
   `LIVE` in that document, cited against the specific commit/PR that
   landed it — never inferred from a plan or an intention.
3. Per-feature validation detail (what was actually tested, by what
   method) lives in the relevant [../07-features/](../07-features/)
   document's "Validation" section.
4. Platform/staging-level validation evidence (as opposed to pre-merge CI)
   lives in [staging-validation.md](staging-validation.md).

## Buildable-now set (as of 2026-09-13)

MVP-1 (Hierarchy), MVP-2 (Energy/Demand/Power Quality), and MVP-3 (Site
Overview & Attention) are landed — see
[../01-product/roadmap.md](../01-product/roadmap.md). MVP-4 through MVP-8
remain not built; their requirements remain classified `PLANNED`/`MISSING`
in the traceability matrix.
