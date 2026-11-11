#!/usr/bin/env python3
"""Generate scripts/maintenance/airsense_recovery_session.sql from migration 310.

The session script defines migration 310's packet table and three functions as
SESSION-ONLY objects (pg_temp), so the AirSense recovery can run on production
without migration 310 (production cannot take 310 without 309, which is not
approved for production). Nothing it creates outlives the session; no schema,
ledger or application change.

The ONLY differences from migration 310 (asserted by
app/tests/test_airsense_recovery_session.py) are:
  * the four object names: telemetry.preserved_rtdata_packets /
    preserved_rtdata_samples / preserved_rtdata_points /
    backfill_preserved_rtdata  ->  pg_temp.<same name>
    (the advisory-lock key string 'telemetry.backfill_preserved_rtdata' is NOT
    renamed, so a session run and a deployed-310 run serialize together);
  * CREATE TABLE -> CREATE TEMP TABLE for the packet table;
  * omitted: ALTER ... OWNER, REVOKE, COMMENT ON and the postcondition block
    (meaningless for session-only objects).

Usage: python scripts/maintenance/generate_airsense_recovery_session.py [--check]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "310_preserved_rtdata_backfill.sql"
OUTPUT = REPO / "scripts" / "maintenance" / "airsense_recovery_session.sql"
NAMES = ("preserved_rtdata_packets", "preserved_rtdata_samples", "preserved_rtdata_points", "backfill_preserved_rtdata")
LOCK_KEY = "hashtext('telemetry.backfill_preserved_rtdata')"
LOCK_PLACEHOLDER = "\x00LOCK_KEY\x00"


def to_session(text: str) -> str:
    """Rename the four objects to pg_temp, leaving the advisory-lock key alone."""
    text = text.replace(LOCK_KEY, LOCK_PLACEHOLDER)
    for name in NAMES:
        text = re.sub(rf"\btelemetry\.{name}\b", f"pg_temp.{name}", text)
    return text.replace(LOCK_PLACEHOLDER, LOCK_KEY)


def blocks(sql: str) -> dict[str, str]:
    """The preconditions DO block, the CREATE TABLE and the three CREATE FUNCTIONs, verbatim."""
    out = {}
    m = re.search(r"^DO \$\$\n.*?^END \$\$;\n", sql, re.S | re.M)
    out["preconditions"] = m.group(0)
    m = re.search(r"^CREATE TABLE telemetry\.preserved_rtdata_packets\n.*?^\);\n", sql, re.S | re.M)
    out["table"] = m.group(0)
    for name in NAMES[1:]:
        m = re.search(rf"^CREATE FUNCTION telemetry\.{name}\n.*?^\$function\$;\n", sql, re.S | re.M)
        out[name] = m.group(0)
    return out


def render() -> str:
    b = blocks(MIGRATION.read_text(encoding="utf-8"))
    table = b["table"].replace("CREATE TABLE telemetry.preserved_rtdata_packets", "CREATE TEMP TABLE pg_temp.preserved_rtdata_packets", 1)
    header = f"""-- ============================================================================
-- GENERATED -- do not edit. Source: postgres/migrations/{MIGRATION.name}
-- Generator: scripts/maintenance/generate_airsense_recovery_session.py
-- Identity test: app/tests/test_airsense_recovery_session.py
--
-- Session-only AirSense recovery: migration 310's packet table and functions as
-- pg_temp objects. Everything it creates disappears when the session ends.
-- Differences from migration 310 (and nothing else):
--   * telemetry.{{preserved_rtdata_packets, preserved_rtdata_samples,
--     preserved_rtdata_points, backfill_preserved_rtdata}} -> pg_temp.<same>;
--     the advisory-lock key 'telemetry.backfill_preserved_rtdata' is unchanged;
--   * CREATE TEMP TABLE for the packet table;
--   * no OWNER / REVOKE / COMMENT statements and no postcondition block.
--
-- Use (operator, ems_admin, one psql session; see
-- docs/10-operations/airsense-preserved-payload-recovery.md):
--   1. \\i this file (or pipe it) inside the session;
--   2. load the preserved exports into pg_temp.preserved_rtdata_packets;
--   3. dry runs:  SELECT * FROM pg_temp.backfill_preserved_rtdata(actor, from, to, devices);
--   4. execution only with explicit approval: (..., false, <dry-run points_to_insert>).
-- ============================================================================

"""
    parts = [
        header,
        "-- Preconditions (migration 310, verbatim).\n",
        b["preconditions"],
        "\n-- The preserved packets (session-only).\n",
        table,
    ]
    for name in NAMES[1:]:
        parts += [f"\n-- pg_temp.{name} (migration 310 body, names as above).\n", to_session(b[name])]
    return "".join(parts)


def main() -> int:
    text = render()
    if "--check" in sys.argv:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != text:
            print(f"{OUTPUT} is out of date; regenerate it.", file=sys.stderr)
            return 1
        return 0
    OUTPUT.write_bytes(text.encode("utf-8"))
    print(f"wrote {OUTPUT} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
