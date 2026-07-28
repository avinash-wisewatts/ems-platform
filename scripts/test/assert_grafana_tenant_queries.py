#!/usr/bin/env python3
"""
Validate tenant isolation in provisioned Grafana dashboard SQL.

Security contract:
- Every SQL query that reads an analytics.* object must include the Grafana
  organization session macro ${__org.id}.
- The query must compare that macro to grafana_org_id.
- This applies to panel queries and dashboard variable queries.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any, Iterator


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DASHBOARD_ROOT = PROJECT_ROOT / "grafana" / "dashboards"

ANALYTICS_REFERENCE = re.compile(
    r"\b(?:FROM|JOIN)\s+analytics\.",
    re.IGNORECASE,
)

TENANT_PREDICATE = re.compile(
    r"\bgrafana_org_id\s*=\s*\$\{__org\.id\}",
    re.IGNORECASE,
)


def walk_json(value: Any, path: str = "$") -> Iterator[tuple[str, str]]:
    """Yield JSON paths and string values from a dashboard document."""
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if isinstance(child, str):
                yield child_path, child
            else:
                yield from walk_json(child, child_path)

    elif isinstance(value, list):
        for index, child in enumerate(value):
            child_path = f"{path}[{index}]"
            if isinstance(child, str):
                yield child_path, child
            else:
                yield from walk_json(child, child_path)


def validate_dashboard(path: Path) -> list[str]:
    errors: list[str] = []

    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{path.relative_to(PROJECT_ROOT)}: invalid JSON: {exc}"]

    for json_path, value in walk_json(document):
        if not ANALYTICS_REFERENCE.search(value):
            continue

        if not TENANT_PREDICATE.search(value):
            errors.append(
                f"{path.relative_to(PROJECT_ROOT)} {json_path}: "
                "analytics query lacks "
                "'grafana_org_id = ${__org.id}'"
            )

    return errors


def main() -> int:
    dashboard_files = sorted(DASHBOARD_ROOT.rglob("*.json"))

    if not dashboard_files:
        print(
            f"ERROR: no dashboard JSON files found under {DASHBOARD_ROOT}",
            file=sys.stderr,
        )
        return 1

    errors: list[str] = []

    for dashboard_file in dashboard_files:
        errors.extend(validate_dashboard(dashboard_file))

    if errors:
        print("Grafana tenant-query assertions failed:", file=sys.stderr)

        for error in errors:
            print(f"  - {error}", file=sys.stderr)

        return 1

    print(
        "Grafana tenant-query assertions passed "
        f"for {len(dashboard_files)} dashboard files."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
