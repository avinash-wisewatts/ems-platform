#!/usr/bin/env python3
"""
Validate active Grafana PostgreSQL queries against the disposable ems_test DB.

The validator:

1. Parses active dashboard JSON files.
2. Extracts SQL from rawSql, query, and definition fields.
3. Selects SQL that references analytics.* views.
4. Replaces supported Grafana macros and variables with safe test literals.
5. Runs PostgreSQL EXPLAIN as grafana_reader.
6. Rejects unresolved Grafana macros and SQL that the runtime role cannot use.

No query is executed; EXPLAIN performs parsing, name resolution, type checking,
and privilege checking without returning dashboard data.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DASHBOARD_ROOT = PROJECT_ROOT / "grafana" / "dashboards"
COMPOSE_FILE = PROJECT_ROOT / "compose.test.yaml"

TEST_SITE_ID = "00000000-0000-4000-8000-000000000001"
TEST_ASSET_ID = "00000000-0000-4000-8000-000000000002"
TEST_SENSOR_ID = "00000000-0000-4000-8000-000000000003"

ANALYTICS_REFERENCE = re.compile(
    r"\b(?:FROM|JOIN)\s+analytics\.",
    re.IGNORECASE,
)

UNRESOLVED_GRAFANA_TOKEN = re.compile(
    r"(?:\$\{[^}]+\}|\$__[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)"
)

TIME_FILTER = re.compile(
    r"\$__timeFilter\(\s*([^)]+?)\s*\)",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class DashboardQuery:
    dashboard: Path
    json_path: str
    sql: str


def walk_json(
    value: Any,
    path: str = "$",
) -> Iterator[tuple[str, str, str]]:
    """
    Yield key, JSON path, and string value from nested dashboard JSON.
    """
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"

            if isinstance(child, str):
                yield key, child_path, child
            else:
                yield from walk_json(child, child_path)

    elif isinstance(value, list):
        for index, child in enumerate(value):
            child_path = f"{path}[{index}]"

            if isinstance(child, str):
                yield "", child_path, child
            else:
                yield from walk_json(child, child_path)


def extract_queries(path: Path) -> list[DashboardQuery]:
    """
    Extract active PostgreSQL query strings from one dashboard.
    """
    document = json.loads(path.read_text(encoding="utf-8"))
    queries: list[DashboardQuery] = []
    seen: set[str] = set()

    for key, json_path, value in walk_json(document):
        if key not in {"rawSql", "query", "definition"}:
            continue

        sql = value.strip()

        if not sql or not ANALYTICS_REFERENCE.search(sql):
            continue

        # Grafana commonly stores the same variable SQL in both definition
        # and query. Validate each unique SQL string once per dashboard.
        if sql in seen:
            continue

        seen.add(sql)

        queries.append(
            DashboardQuery(
                dashboard=path,
                json_path=json_path,
                sql=sql,
            )
        )

    return queries


def substitute_grafana_tokens(sql: str) -> str:
    """
    Replace the supported Grafana runtime macros with deterministic literals.
    """
    rendered = sql

    rendered = rendered.replace("${__org.id}", "1")
    rendered = rendered.replace("${site}", TEST_SITE_ID)

    # sqlstring formatting must include SQL string quotes because dashboard
    # queries use these values in IN lists and ARRAY constructors.
    rendered = rendered.replace(
        "${asset:sqlstring}",
        f"'{TEST_ASSET_ID}'",
    )
    rendered = rendered.replace(
        "${sensor:sqlstring}",
        f"'{TEST_SENSOR_ID}'",
    )

    rendered = TIME_FILTER.sub(
        (
            r"\1 BETWEEN "
            r"TIMESTAMPTZ '2026-01-01 00:00:00+00' "
            r"AND TIMESTAMPTZ '2026-01-02 00:00:00+00'"
        ),
        rendered,
    )

    rendered = rendered.replace(
        "$__timeFrom()",
        "TIMESTAMPTZ '2026-01-01 00:00:00+00'",
    )
    rendered = rendered.replace(
        "$__timeTo()",
        "TIMESTAMPTZ '2026-01-02 00:00:00+00'",
    )

    unresolved = sorted(set(UNRESOLVED_GRAFANA_TOKEN.findall(rendered)))

    if unresolved:
        raise ValueError(
            "unsupported or unresolved Grafana tokens: "
            + ", ".join(unresolved)
        )

    return rendered.rstrip().rstrip(";")


def explain_query(query: DashboardQuery, rendered_sql: str) -> str | None:
    """
    Ask PostgreSQL to parse and plan a query as grafana_reader.
    """
    validation_sql = f"""
BEGIN;
SET LOCAL ROLE grafana_reader;
SET LOCAL statement_timeout = '15s';
EXPLAIN (COSTS OFF)
{rendered_sql};
ROLLBACK;
"""

    command = [
        "docker",
        "compose",
        "-f",
        str(COMPOSE_FILE),
        "exec",
        "-T",
        "timescaledb-test",
        "psql",
        "-X",
        "-v",
        "ON_ERROR_STOP=1",
        "-U",
        "ems_admin",
        "-d",
        "ems_test",
        "-P",
        "pager=off",
    ]

    result = subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        input=validation_sql,
        text=True,
        capture_output=True,
        check=False,
    )

    if result.returncode == 0:
        return None

    output = "\n".join(
        part.strip()
        for part in (result.stdout, result.stderr)
        if part.strip()
    )

    return output or "psql returned a non-zero status without output"


def main() -> int:
    dashboard_files = sorted(DASHBOARD_ROOT.rglob("*.json"))

    if not dashboard_files:
        print(
            f"ERROR: no active dashboards found under {DASHBOARD_ROOT}",
            file=sys.stderr,
        )
        return 1

    errors: list[str] = []
    query_count = 0

    for dashboard_file in dashboard_files:
        try:
            queries = extract_queries(dashboard_file)
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(
                f"{dashboard_file.relative_to(PROJECT_ROOT)}: "
                f"invalid dashboard JSON: {exc}"
            )
            continue

        for query in queries:
            query_count += 1
            relative_path = query.dashboard.relative_to(PROJECT_ROOT)

            try:
                rendered = substitute_grafana_tokens(query.sql)
            except ValueError as exc:
                errors.append(
                    f"{relative_path} {query.json_path}: {exc}"
                )
                continue

            failure = explain_query(query, rendered)

            if failure is not None:
                errors.append(
                    f"{relative_path} {query.json_path}:\n{failure}"
                )

    if query_count == 0:
        print(
            "ERROR: no analytics queries were found in active dashboards",
            file=sys.stderr,
        )
        return 1

    if errors:
        print("Grafana SQL validation failed:", file=sys.stderr)

        for error in errors:
            print(f"\n---\n{error}", file=sys.stderr)

        return 1

    print(
        "Grafana SQL validation passed for "
        f"{query_count} unique analytics queries across "
        f"{len(dashboard_files)} dashboard files."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
