# Local Development Boundaries

Status: CURRENT · Last reviewed: 2026-09-13 · Owner: Engineering

This document is operational, not architectural. It exists to keep local
development converged on one canonical checkout instead of accumulating
sibling project folders over time.

- `ems-platform` (`C:\Users\avina\Documents\WiseWatts\ems-platform`) is the
  single canonical local project directory for the WiseWatts EMS platform.
- Future feature/phase work uses Git branches — and, only when a working
  copy is genuinely needed in parallel, a `git worktree` — rooted in this
  one repository. It does not use a new permanent sibling clone.
- Temporary worktrees (e.g. `git worktree add ../ems-<slug> -b <branch>`)
  may be created for convenience but **must be removed with
  `git worktree remove`** once the branch is merged/pushed/abandoned and
  verified to hold no unique uncommitted work.
- Never create another long-lived clone of the project merely because a
  phase is "in progress" — use a branch (and, if needed, a worktree)
  instead.
- Production is never a local development target. This machine only ever
  reads or diagnoses staging or production over an authorized, explicit
  channel.
- Staging/production deployment remains governed exclusively by the
  existing Git/CI/CD approval process (`deploy-staging.yml`,
  `deploy-production.yml`) — never a local, ad hoc action.
- Do not duplicate project source or documentation into sibling folders.
  If a file needs to exist in two places, that is a sign it belongs on a
  branch instead.
- Product documentation belongs under `docs/` in `ems-platform` — see
  [docs/README.md](../README.md).
- Operator-only local artifacts (scratch SQL, ad hoc baselines, audit notes
  not yet promoted to a committed doc) may exist locally and untracked, but
  must be clearly named as such and must never become a silent shadow copy
  of tracked project files.
- Branches and PRs — not sibling folders — are the source of truth for
  in-progress Git work.
