# EMS Platform Repository Cleanup Audit

Date: 2026-08-17
Scope: full working tree at `/opt/ems-platform`, read-only audit (no files deleted or moved).
Branch at time of audit: `feature/three-role-scope-model`.

This report is organized into three sections as requested:

1. **Safe to Delete** — untracked, either already `.gitignore`-matched or trivially regenerable, zero history/data loss. These have corresponding (commented-out) commands in `propose_cleanup.sh`.
2. **Needs Review** — real ambiguity, real risk, or requires a human/code decision rather than a mechanical delete. Nothing here is in the cleanup script.
3. **Proposed Structural Changes** — non-file-deletion recommendations (`.gitignore` hygiene, migration-ledger governance, directory layout).

`postgres/archive/`, `postgres/legacy/`, and `postgres/restructure_manifest.csv` were treated as immutable audit trails throughout and do not appear in the Safe to Delete section.

---

## 1. Safe to Delete

All items below are **untracked** (`git ls-files` confirms zero history impact) and either already covered by `.gitignore` or clearly regenerable via an existing build/test command. Total disk reclaimed: **~605 MB**, dominated by one item (`node_modules`).

### 1.1 Regenerable caches (~3.7 MB)
| Path | Notes |
|---|---|
| `.pytest_cache/` | Regenerates on next `pytest` run. Not currently gitignored (see §3). |
| `.coverage` | pytest-cov artifact, gitignored. |
| `app/src/__pycache__/`, `app/src/context/__pycache__/`, `app/src/routers/__pycache__/`, `app/src/onboarding/__pycache__/`, `app/src/auth/__pycache__/`, `app/tests/__pycache__/` | Standard Python bytecode cache, gitignored. |

### 1.2 Regenerable Grafana plugin build artifacts (~599 MB)
| Path | Size | Notes |
|---|---|---|
| `grafana/plugin-src/wisewatts-live-datasource/node_modules/` | 527 MB | Not gitignored (gap — see §3). Fully reproduced by `build-plugin.sh`'s `npm install` step. By far the largest single item in this audit. |
| `grafana/plugin-src/wisewatts-live-datasource/dist/` | 36 MB | Build output; `build-plugin.sh` deletes and rebuilds this itself on every run. |
| `grafana/plugin-src/wisewatts-live-datasource/wisewatts_live_datasource_linux_amd64` | 36 MB | A compiled binary sitting at the plugin-src root (outside `dist/`) — looks like a manual `go build` run outside the official script. Regenerable. |

The plugin itself (`grafana/plugin-src/wisewatts-live-datasource/*.go`, `src/`) is **live and in use** — `compose.yaml` explicitly allow-lists it as an unsigned plugin — only the build byproducts above are being proposed for removal, not the plugin source.

### 1.3 Backup / scratch file patterns (`.bak`, `.bak-*`, `.before-*`, `.failed-*`, `.broken-*`)
All confirmed untracked; each has a clean, current, git-tracked counterpart already in place. 4 files (marked †) match `*.broken-*`, which has no `.gitignore` rule yet (see §3) — everything else here is already gitignore-matched, so removing these files is purely a disk-hygiene action, not a git-status change.

**postgres/** (13 files)
- `postgres/ddl/76_admin_onboarding_contract.sql.bak-before-asset-modes-20260719`
- `postgres/ddl/76_admin_onboarding_contract.sql.bak-before-category-relationship-rule-20260719`
- `postgres/ddl/76_admin_onboarding_contract.sql.bak-before-device-categories-20260719`
- `postgres/ddl/76_admin_onboarding_contract.sql.bak-before-location-modes-20260719`
- `postgres/ddl/76_admin_onboarding_contract.sql.bak-before-profile-compatibility-20260719`
- `postgres/ddl/76_admin_onboarding_contract.sql.bak-story-4-5`
- `postgres/migrations/039_resolution_aware_native_energy_gap_threshold.sql.failed-20260814-102047` (clean `039_resolution_aware_native_energy_gap_threshold.sql` exists and is manifest-registered)
- `postgres/migrations/169_universal_grafana_mvp.sql.bak-20260802-233217` (no active `169_*` migration exists anymore — this numbering was superseded by later files; the backup is an orphaned draft, not a backup of something still active)
- `postgres/restructure_manifest.csv.bak-eniscope-seed-20260802-232333`
- `postgres/restructure_manifest.csv.bak-story-4-5`
- `postgres/restructure_manifest.csv.before-baseline-reset`
- `postgres/restructure_move_20260718_153128.log`
- `postgres/seeds/demo/59_demo_asset_hierarchy.sql.bak-story-4-5`

**app/** (18 files)
- `app/src/live_main.py.broken-live-last-seen-20260814-161755` †
- `app/src/main.py.bak-before-form-preservation-20260719`
- `app/src/main.py.bak-before-inline-errors-20260719`
- `app/src/main.py.bak-story-4-5`
- `app/src/onboarding/asset.py.bak-story-4-5`
- `app/src/onboarding/forms.py.bak-before-inline-errors-20260719`
- `app/src/onboarding/forms.py.bak-before-validation-20260719`
- `app/src/onboarding/forms.py.bak-story-4-5`
- `app/src/onboarding/repository.py.bak-story-4-5`
- `app/src/onboarding/service.py.bak-before-relationship-validation-20260719`
- `app/src/templates/onboarding.html.bak-before-inline-errors-20260719`
- `app/src/templates/onboarding.html.bak-before-relationship-filter-20260719`
- `app/src/templates/onboarding/asset.html.bak-story-4-5`
- `app/src/templates/onboarding/result.html.bak-story-4-5`
- `app/src/templates/onboarding/review.html.bak-story-4-5`
- `app/tests/test_asset_validation.py.bak-story-4-5`
- `app/tests/test_onboarding_asset_routes.py.bak-story-4-5`
- `app/tests/test_onboarding_review_routes.py.bak-story-4-5`

  These `.bak-*` test files are additionally confirmed inert: pytest only collects `test_*.py`/`*_test.py`, so a `.bak-story-4-5` suffix means they were never executed by any test run.

**grafana/** (21 files)
- `grafana/dashboards/core/analytics-explorer.json.broken-before-clean-selector-repair-20260815-133410` †
- `grafana/dashboards/core/asset-overview.json.bak-20260813-003932`
- `grafana/dashboards/core/asset-overview.json.bak-before-complete-v1-20260810-212436`
- `grafana/dashboards/core/asset-overview.json.bak-before-runtime-fix-20260810-221124`
- `grafana/dashboards/core/asset-overview.json.broken-live-last-seen-20260814-161755` †
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-complete-last-seen-20260814-155303`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-isolated-status-20260814-162830`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-last-seen-runstream-20260814-154910`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-last-seen-runstream-v3-20260814-155016`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-last-updated-20260815-105553`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-live-last-seen-20260814-154738`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-live-last-seen-v2-20260814-154824`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-loading-sentinel-20260814-085240`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-stable-live-frame-20260814-080841`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.before-stable-live-frame-20260814-080959`
- `grafana/plugin-src/wisewatts-live-datasource/datasource.go.broken-live-last-seen-20260814-161755` †
- `grafana/plugin-src/wisewatts-live-datasource/datasource_stream_path_test.go.before-frame-ready-structural-fix-20260814-160057`
- `grafana/plugin-src/wisewatts-live-datasource/datasource_stream_path_test.go.before-frame-ready-test-fix-20260814-155811`
- `grafana/plugin-src/wisewatts-live-datasource/datasource_stream_path_test.go.before-frame-ready-test-fix-20260814-155958`
- `grafana/plugin-src/wisewatts-live-datasource/status_stream.go.before-last-updated-20260815-105553`
- `grafana/plugin-src/wisewatts-live-datasource/status_stream_test.go.before-last-updated-20260815-105553`

**root** (2 files)
- `compose.yaml.bak-before-admin-portal-20260719`
- `compose.yaml.bak-before-telegraf-env`

### 1.4 One-off / unreferenced scratch output
- `snapshots/ems-architecture-snapshot-20260817-002139.txt` (29 KB) — a one-off `git status`/environment text dump generated today, untracked, not gitignored, not referenced by any script. Purely diagnostic and reproducible on demand.

### 1.5 Redundant local backup bundle
- `backups/` (repo root, 2.7 MB, 14 timestamped feature-fix subdirectories) — gitignored under the repo's own "Repository-local backup bundles" convention, meaning the team already treats this as disposable. Every subdirectory is a manual pre-edit snapshot of code that has since been superseded and is already recoverable from git history. Recommended for deletion as a whole directory.

### 1.6 Empty placeholder directories
- `postgres/deploy/`, `postgres/functions/`, `postgres/views/` — 0 files, superseded by `postgres/ddl/`. Not bind-mounted by any compose file.
- `caddy/`, `logs/` (repo root) — 0 files, not referenced by `compose.yaml` (only `telegraf/logs` is mounted, a different path). Low priority; harmless to keep or remove.

---

## 2. Needs Review

Nothing in this section is in the cleanup script. Each item needs a human judgment call, a code change, or carries real (if small) risk.

### 2.1 — Critical: live schema objects that exist in nowhere except local disk
**This is the most important finding in the audit.** `postgres/migrations/` has 60 `.sql` files on disk; `postgres/restructure_manifest.csv` registers only 44 of them (through migration 043 — migration `044`, added this session, is correctly registered). The following are **neither git-tracked nor manifest-registered**, yet the schema objects they define — e.g. `analytics.v_grafana_asset_selector`, used by the Analytics Explorer dashboard wired up this session — **already exist live in the `ems` database**:

- `postgres/migrations/153_grafana_asset_connectivity_runtime_grant.sql`
- `postgres/migrations/170_grafana_asset_selector.sql` through `184_persisted_environment_daily.sql` (15 files)
- `postgres/ddl/139_live_telemetry_state.sql`, `150_grafana_telemetry_capture_policy.sql`, `151_resolution_aware_native_energy_gap_threshold.sql`, `152_grafana_asset_identity_context.sql`

This means these objects were applied to `ems` out-of-band — bypassing the checksummed `admin.schema_migrations` ledger — and their **only** source-of-truth copy is untracked local disk. If this working directory were lost, this schema would be unrecoverable from git. **Do not delete these files.** See §3 for the recommended fix (register + commit, don't discard).

A secondary, lower-severity version of the same gap: `postgres/ddl/07_02_mqtt_staging.sql`, `07_03_telegraf_ingest.sql`, `113_normalized_receipt_lineage_and_energy_loader_fix.sql`, `118_device_tab_system_generated_external_id.sql`, `43_energy_routing_view.sql`, `89_asset_metering_requirements.sql` are git-tracked but simply missing their `canonical_mirror` manifest row — a paperwork gap, not a data-loss risk.

### 2.2 — Dead tracked scripts
- `postgres/scripts/migrate.sh` and `postgres/scripts/status.sh` are both **0 bytes and git-tracked**. Since they're in history, removing them is a deliberate `git rm`, not a filesystem cleanup — flagging for a human decision (restore intended content, or remove and update anything that might reference them, e.g. docs mentioning `postgres/scripts/status.sh`).

### 2.3 — Confirmed orphaned application file
- `app/src/context/dependencies.py` defines `organization_context`, `site_context`, `location_context` — thin wrappers around `src.context.service.require_*_context`. Zero references anywhere in `app/src` or `app/tests`; `main.py` imports the underlying `require_*_context` functions directly instead. High-confidence dead file, but it's tracked application code — recommend a final grep for dynamic/string-based imports before a deliberate `git rm`, rather than including it in a mechanical cleanup script.

### 2.4 — Unused imports (confirmed via `pyflakes` + manual cross-reference)
| File:line | Unused name |
|---|---|
| `app/src/auth/middleware.py:4` | `starlette.types.Message` |
| `app/src/onboarding/grafana_reconciliation_service.py:3` | `GrafanaApiError` |
| `app/src/main.py:3985` | local variable `provisioning` assigned but never used |
| `app/src/main.py:6407` | local variable `exc` assigned but never used |

### 2.5 — Test debt: imports kept alive only by monkeypatches
`app/src/main.py` imports `require_location_context`, `require_site_context`, `list_sites`, `DEMAND_INTERVALS`, `DEMAND_BASES`, `DEMAND_SOURCE_ROLES`, `create_site` but never references them again in its own body. They aren't dead in the "delete the import" sense, though: `app/tests/test_asset_administration_routes.py` and `app/tests/test_scoped_site_loading.py` do `monkeypatch.setattr("src.main.require_location_context", ...)` etc., which requires the attribute to pre-exist on the module. This looks like leftover wiring from a refactor where the route stopped calling these directly — the monkeypatches are likely now exercising nothing. Fixing this means touching test assertions, not a mechanical import removal; needs a human to confirm what those tests are supposed to verify before either restoring real usage or updating the tests.

### 2.6 — Ambiguous backup directories (organized, possibly forensic — not junk-pattern cruft)
- `postgres/backups/` (3.2 MB, 20 files: schema-before-refactor dumps, a production-vs-canonical schema diff, function-definition snapshots) — gitignored, untracked, but organized and dated with clear disaster-recovery intent, unlike the `.bak-*` litter in §1.3.
- `grafana/dashboard-backups/` (240 KB, 5 dated dashboard-JSON snapshots) — same pattern, smaller scale.

Recommend a human skim these two directories rather than a blanket delete — if judged genuinely redundant with git history, they belong in `postgres/archive/` (the repo's own designated immutable-trail location) rather than deletion, or deletion after confirming nothing in them predates their content's arrival in git.

### 2.7 — Root README sprawl
`README-006.md` through `README-019.md` (14 files) at repo root are **untracked**, each a real per-migration/per-incident write-up (e.g. "Migration 006 — Canonical Failure Classification", "Device commissioning UI hotfix"). They sit alongside `README-CORRECTION.md`, `README-HOTFIX.md`, `README-INSTALL.md` (which *are* tracked) and a **tracked but empty (0-byte)** `README.md`. Since they're untracked, deleting them is genuinely irreversible (no git history backstop) — recommend a human skim-and-triage: fold the still-relevant ones into `docs/operations/` (which already holds similarly-named dated `.md` files) and commit, then discard the rest. Not included in the cleanup script for that reason.

### 2.8 — `.venv-test/`
79 MB, gitignored, untracked, and functionally in use (this audit's own sibling work in this session ran `pytest` through it). However, it is **not referenced by `Makefile` or `app/Dockerfile.test`** — the documented test path builds a fresh Docker image from `requirements-dev.txt` instead. This means the venv can silently drift from `requirements.txt`/`requirements-dev.txt` over time with nothing to catch it. Recommend either documenting it as the supported local-dev shortcut (with a `requirements-dev.txt` freshness check) or removing it in favor of the Docker-only path — a policy decision, not a cleanup action.

---

## 3. Proposed Structural Changes

No commands for this section — these are recommendations, not mechanical file operations.

### 3.1 Consolidate `.gitignore`
The current file has **duplicated sections** (three separate blocks touch `.bak`/`.backup`/`.before-*`; `postgres/data/` and `logs/` are each listed twice) and a **self-contradiction**: `postgres/archive/` is ignored under "# Archives," then un-ignored again at the bottom under "Preserve the immutable pre-production migration baseline archive." It happens to work today because of negation-pattern quirks, but it's fragile. Recommend a single deduplicated file, and while rewriting it, close the gaps this audit found:
- Add `.pytest_cache/` (currently uncovered).
- Add `*.broken-*` (currently uncovered — 4 files in §1.3 rely on being untracked-by-luck rather than by rule).
- Add `node_modules/` and a `grafana/plugin-src/**/dist` rule, plus a rule for compiled Go binaries (e.g. `wisewatts_live_datasource_linux_amd64`) — right now a stray `git add -A` in that directory would stage 527 MB.

### 3.2 Backfill the migration/manifest ledger (highest-value structural fix)
Register migrations `153`, `170`–`184` and `postgres/ddl/139`, `150`–`152` in `restructure_manifest.csv`, `git add` the files, and use `scripts/apply_migrations.sh --baseline` (the same mechanism migration `044` used this session, and the same one the pre-production baseline already relies on) to record them in `admin.schema_migrations` as already-applied — closing the gap between what's actually deployed in `ems` and what the checksummed ledger and git history can prove. Do this before anything in §2.1 is touched further.

### 3.3 Empty `postgres/` subdirectories
`deploy/`, `functions/`, `views/` are empty and superseded by `postgres/ddl/`. Either remove them (§1.6) or, if they were meant to hold something specific per an earlier reorg plan, document that intent in `postgres/README.md` (currently 0 bytes) so the next person doesn't have to guess.

### 3.4 Root README sprawl → one convention
Pick one of: (a) a single `CHANGELOG.md`, appended per change, or (b) commit the numbered write-ups into `docs/operations/` alongside the dated docs already living there (`PREPRODUCTION_MIGRATION_BASELINE_20260807.md` etc.). Either beats untracked numbered files at repo root that vanish the moment someone runs a stray `rm`. Also: populate the currently-empty tracked `README.md` — right now the canonical repo README is blank.

### 3.5 One backup convention, not three
`backups/` (root), `postgres/backups/`, and `grafana/dashboard-backups/` are three independently-invented "copy the file before I touch it" conventions. Git already provides this via commits/branches. Recommend relying on git for anything already tracked, and reserving manual backup directories only for genuinely pre-commit / disaster-recovery scenarios like the schema dumps in `postgres/backups/production-audit/`.

### 3.6 `grafana/plugin-src` build hygiene
Add a short README in `grafana/plugin-src/wisewatts-live-datasource/` noting that `node_modules/`, `dist/`, and the top-level compiled binary are ephemeral build output from `build-plugin.sh`, not inputs — this would have prevented the 527 MB from accumulating in the first place.
