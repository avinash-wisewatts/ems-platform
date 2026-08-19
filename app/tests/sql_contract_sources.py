from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "postgres/migrations/001_ems_platform_baseline_20260807.sql"


def canonical_sql(filename: str) -> str:
    return (ROOT / "postgres/ddl" / filename).read_text(encoding="utf-8")


def baseline_migration_sql(filename: str) -> str:
    """Return one historical migration section embedded in baseline 001.

    Historical source files are intentionally outside the application test
    runtime. Baseline 001 is the immutable executable record of that history.
    """
    sql = BASELINE.read_text(encoding="utf-8")
    marker = f"-- Historical migration: {filename}"
    start = sql.find(marker)
    if start < 0:
        raise AssertionError(f"Historical migration not found in baseline: {filename}")
    next_start = sql.find("-- Historical migration: ", start + len(marker))
    return sql[start:] if next_start < 0 else sql[start:next_start]
