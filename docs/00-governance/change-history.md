# Change History

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Product + Engineering

This is the change log for **this documentation reorganization itself**.
For the platform's own operational change history (migrations, incidents,
deployments), see [../10-operations/incident-history.md](../10-operations/incident-history.md)
and the archived narrative at
[../99-archive/historical-implementation/platform-manual/25-change-history.md](../99-archive/historical-implementation/platform-manual/25-change-history.md).

## 2026-09-13 — SDLC documentation reorganization

Following a documentation-and-SDLC-governance audit, and after a separate
custody commit (`0ea53b0`) secured all previously-uncommitted documentation
into version control, this reorganization established `docs/` as the
canonical, SDLC-organized source of truth. Summary of what changed —
see [../99-archive/README.md](../99-archive/README.md) for the full
old-file → new-location mapping:

1. **Established the structure**: `docs/README.md` and `docs/00-governance/`
   (governance rules, source-of-truth priority, 13 formal decision records,
   this change log).
2. **Consolidated product and requirements**: `docs/product/` →
   `docs/01-product/` + `docs/02-requirements/`.
3. **Consolidated UX/design**: the information-architecture document →
   `docs/03-ux-and-design/` (4 documents).
4. **Consolidated architecture**: product-architecture content →
   `docs/04-architecture/` (6 documents), summarizing and linking to the
   frozen DDS rather than duplicating it; `docs/05-applications/` (3
   applications).
5. **Consolidated platform documentation**: `docs/platform-manual/`'s 25
   chapters + 6 reference catalogs → `docs/06-platform/` (12 documents
   across 5 subdirectories).
6. **Established feature documentation**: `docs/07-features/` (6
   features), each connecting purpose → requirements → UX → architecture →
   validation → release status.
7. **Established verification documentation**: `docs/08-verification/`,
   including the MVP-3 staging validation record (deployed SHA `ddbe5a4`,
   PASS WITH OBSERVATIONS).
8. **Consolidated release/operations documentation**: `docs/09-release-and-deployment/`
   and `docs/10-operations/` (9 documents).
9. **Archived superseded originals**: `docs/product/`, `docs/platform-manual/`,
   `Audit/` (46 files), and the DDS's evidentiary review/stress-test
   documents moved to `docs/99-archive/`, preserved verbatim.
10. **Corrected two decision records mid-reorganization** (ADR-009,
    ADR-010): an initial search covering only `docs/` and `Audit/` text
    files concluded "Slice C" and the Attention materiality threshold were
    not established anywhere in the repository. A subsequent check of
    `origin/staging`'s commit history and source code (commits `ddbe5a4`,
    `c299f27`, `19c09d7`, `e64c1e3`) found both were real, implemented, and
    merged — MVP-1, MVP-2, and MVP-3 had in fact landed on `origin/staging`
    as of 2026-09-13, after the 2026-09-11 snapshot the original source
    documents described. Both ADRs, and every downstream document their
    status affected (roadmap, requirements traceability, API architecture,
    the EMS Web App README, and six feature READMEs), were corrected with
    the real evidence rather than left wrong.

### What was not changed

No product decision, architecture decision, requirement, or historical
record was altered in substance. Where an open question in the original
v0.1 documents had since been answered by the Product Owner Workshop, that
resolution is stated directly (with its `Q`-number citation) rather than
left as a stale "open" marker — this is a documentation-currency
correction, not a new decision. The frozen DDS architecture
(`docs/DDS/analytics-platform-future-state-architecture.md`) was not
edited and did not move.

### Known unresolved items carried forward, not resolved by this reorganization

- The hierarchy-model tension between the frozen DDS and the product
  documentation (see [decisions/ADR-002-hierarchy-model.md](decisions/ADR-002-hierarchy-model.md)).
- The `site-overview.json` dual-demand-semantics Grafana inconsistency
  (see [../06-platform/grafana/README.md](../06-platform/grafana/README.md)).
- The "Slice C Historical Comparison decision pack" and "MVP-3
  Implementation Decision Pack," cited by name in implementation commits,
  are not themselves present as files anywhere in this repository (see
  [decisions/ADR-009-slice-c-historical-reference-methodology.md](decisions/ADR-009-slice-c-historical-reference-methodology.md)
  and [decisions/ADR-010-mvp3-attention-materiality-policy.md](decisions/ADR-010-mvp3-attention-materiality-policy.md)).
