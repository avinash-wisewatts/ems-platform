"""Contract and functional tests for migration 268 (ADR-020 PR1): late/recovered
Energy reconstruction FOUNDATIONS.

Migration 268 must be inert: additive columns with defaults, pure IMMUTABLE
allocation functions, and a reconstruction switch seeded OFF. These tests prove
that, and prove the allocation arithmetic exactly.

Static tests read the repository. Database tests run against the disposable
ems_test database (see conftest.py); every write happens inside a transaction
that is rolled back.
"""

import csv
import os
import random
import re
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest

DB_HOST = os.environ["EMS_APP_DB_HOST"]
DB_PORT = os.environ["EMS_APP_DB_PORT"]
DB_NAME = os.environ["EMS_APP_DB_NAME"]
DB_USER = os.environ["EMS_APP_DB_USER"]
DB_PASSWORD = os.environ["EMS_APP_DB_PASSWORD"]

CONNINFO = (
    f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} "
    f"user={DB_USER} password={DB_PASSWORD}"
)

# Deterministic tenant identity created by conftest.seed_grafana_tenant_fixture.
ORGANIZATION_ID = "00000000-0000-0000-0000-0000000000a1"
SITE_ID = "00000000-0000-0000-0000-0000000001a1"
DEVICE_ID = "00000000-0000-0000-0000-0000000002a1"

REPO = Path(__file__).resolve().parents[2]
MIGRATIONS = REPO / "postgres" / "migrations"
MIGRATION_PATH = MIGRATIONS / "268_energy_reconstruction_foundations.sql"
MANIFEST = REPO / "postgres" / "restructure_manifest.csv"

TABLES = ("energy_consumption_1min", "energy_consumption_5min")

NEW_COLUMNS = (
    "is_reconstructed",
    "import_reconstruction_role",
    "import_reconstruction_method",
    "import_gap_start",
    "import_gap_end",
    "import_gap_delta_wh",
    "export_reconstruction_role",
    "export_reconstruction_method",
    "export_gap_start",
    "export_gap_end",
    "export_gap_delta_wh",
)

NEW_FUNCTIONS = (
    "analytics.energy_gap_weights(numeric[])",
    "analytics.allocate_energy_delta(numeric,numeric[],integer)",
    "config.energy_reconstruction_enabled(uuid,uuid)",
)

# The minimal column list every existing writer of these tables uses (the
# refresh functions name exactly these NOT NULL identity/quality columns and
# more; none names a migration-268 column).
LEGACY_INSERT_COLUMNS = (
    "bucket_start, organization_id, site_id, device_id, "
    "import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected, "
    "export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected, "
    "gap_detected, calculated_at"
)
LEGACY_INSERT_VALUES = (
    "%(bucket)s, %(org)s, %(site)s, %(device)s, "
    "'GOOD', TRUE, FALSE, FALSE, "
    "'GOOD', TRUE, FALSE, FALSE, "
    "FALSE, now()"
)

MILLI = Decimal("0.001")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        yield connection


@pytest.fixture
def tx():
    """A connection inside an explicit transaction that is always rolled back."""
    with psycopg.connect(CONNINFO) as connection:
        try:
            yield connection
        finally:
            connection.rollback()


def _one(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def _all(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def _allocate(conn, delta, weights, scale=None):
    if scale is None:
        return _one(
            conn,
            "SELECT analytics.allocate_energy_delta(%s::numeric, %s::numeric[])",
            (delta, weights),
        )[0]
    return _one(
        conn,
        "SELECT analytics.allocate_energy_delta(%s::numeric, %s::numeric[], %s)",
        (delta, weights, scale),
    )[0]


def _weights(conn, power):
    return _one(
        conn,
        "SELECT method, weights FROM analytics.energy_gap_weights(%s::numeric[])",
        (power,),
    )


def _sqlstate_of(conn, sql, params=None):
    """Run sql inside a savepoint-free autocommit call; return the SQLSTATE."""
    with pytest.raises(psycopg.Error) as excinfo:
        _one(conn, sql, params)
    return excinfo.value.sqlstate


def _migration_sql_without_comments():
    text = MIGRATION_PATH.read_text(encoding="utf-8")
    return "\n".join(line.split("--", 1)[0] for line in text.splitlines())


# ---------------------------------------------------------------------------
# Static: file, manifest, and migration shape
# ---------------------------------------------------------------------------


def test_migration_file_exists_and_number_is_unique():
    assert MIGRATION_PATH.exists()
    numbers = [int(p.name.split("_", 1)[0]) for p in MIGRATIONS.glob("*.sql")]
    assert numbers.count(268) == 1
    assert len(numbers) == len(set(numbers))


def test_manifest_row_follows_267_and_is_last_migration_row():
    with MANIFEST.open(newline="") as handle:
        rows = [r for r in csv.DictReader(handle) if r["target_category"] == "migration"]
    names = [r["source_file"] for r in rows]
    assert names[-2] == "267_routing_bounded_window_end.sql"
    assert names[-1] == "268_energy_reconstruction_foundations.sql"
    assert rows[-1]["target_path"] == "postgres/migrations/268_energy_reconstruction_foundations.sql"
    assert names.count("268_energy_reconstruction_foundations.sql") == 1


def test_migration_creates_only_new_functions_and_no_views_jobs_or_drops():
    sql = _migration_sql_without_comments()
    created = set(
        m.lower()
        for m in re.findall(
            r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+([a-z_]+\.[a-z_0-9]+)",
            sql,
            flags=re.IGNORECASE,
        )
    )
    assert created == {
        "analytics.energy_gap_weights",
        "analytics.allocate_energy_delta",
        "config.energy_reconstruction_enabled",
    }
    for forbidden in (
        r"\bCREATE\s+(OR\s+REPLACE\s+)?VIEW\b",
        r"\bCREATE\s+MATERIALIZED\s+VIEW\b",
        r"\bDROP\s+(FUNCTION|PROCEDURE|VIEW|TABLE|COLUMN|CONSTRAINT)\b",
        r"\badd_job\b",
        r"\balter_job\b",
        r"\bdelete_job\b",
        r"\brefresh_continuous_aggregate\b",
        r"\badd_retention_policy\b",
        r"\badd_compression_policy\b",
        r"\bUPDATE\s+[a-z_]+\.",
        r"\bDELETE\s+FROM\b",
        r"\bTRUNCATE\b",
        r"\bpipeline_state\b",
    ):
        assert not re.search(forbidden, sql, flags=re.IGNORECASE), forbidden


def test_migration_writes_only_the_switch_seed_row():
    sql = _migration_sql_without_comments()
    targets = re.findall(r"INSERT\s+INTO\s+([a-z_]+\.[a-z_0-9]+)", sql, flags=re.IGNORECASE)
    assert targets == ["config.energy_reconstruction_scope"]
    assert "VALUES ('GLOBAL', FALSE," in sql


def test_migration_alters_only_the_two_native_consumption_tables():
    sql = _migration_sql_without_comments()
    altered = re.findall(r"ALTER\s+TABLE\s+([a-z_]+\.[a-z_0-9%$I]+)", sql, flags=re.IGNORECASE)
    assert altered and set(altered) == {"analytics.%1$I"}
    assert "ARRAY['energy_consumption_1min', 'energy_consumption_5min']" in sql


def test_check_constraints_are_not_valid_and_catalog_only_postconditions():
    sql = _migration_sql_without_comments()
    assert sql.count(") NOT VALID") == 3
    # Postconditions must not scan hypertable data.
    post = sql.split("$post$", 1)[1]
    assert "FROM analytics.energy_consumption" not in post


# ---------------------------------------------------------------------------
# Static: no existing writer can be affected by new columns
# ---------------------------------------------------------------------------

_SQL_SOURCE_GLOBS = ("postgres/**/*.sql", "scripts/**/*.sql", "scripts/**/*.sh", "app/src/**/*.py")


def _repo_sources():
    for pattern in _SQL_SOURCE_GLOBS:
        for path in REPO.glob(pattern):
            if "archive" in path.parts:
                continue
            yield path


def test_repository_has_no_positional_insert_into_native_consumption_tables():
    insert = re.compile(
        r"INSERT\s+INTO\s+analytics\.energy_consumption_(1min|5min)\b(?P<rest>\s*.)",
        flags=re.IGNORECASE,
    )
    found = 0
    offenders = []
    for path in _repo_sources():
        text = path.read_text(encoding="utf-8", errors="replace")
        for match in insert.finditer(text):
            found += 1
            if match.group("rest").strip() != "(":
                offenders.append(f"{path.relative_to(REPO)}:{text[: match.start()].count(chr(10)) + 1}")
    assert found > 0, "expected to find the existing column-list INSERTs"
    assert offenders == []


def test_repository_has_no_rowtype_or_star_dependency_on_native_consumption_tables():
    pattern = re.compile(
        r"energy_consumption_(1min|5min)%ROWTYPE"
        r"|SETOF\s+analytics\.energy_consumption_(1min|5min)\b"
        r"|COPY\s+analytics\.energy_consumption_(1min|5min)\b"
        r"|SELECT\s+\*\s+FROM\s+analytics\.energy_consumption_(1min|5min)\b",
        flags=re.IGNORECASE,
    )
    offenders = [
        str(path.relative_to(REPO))
        for path in _repo_sources()
        if pattern.search(path.read_text(encoding="utf-8", errors="replace"))
    ]
    assert offenders == []


# ---------------------------------------------------------------------------
# Database: schema, inertness, and no live dependency on the new objects
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("table", TABLES)
def test_columns_exist_with_inert_defaults(conn, table):
    rows = _all(
        conn,
        """
        SELECT column_name, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = %s AND column_name = ANY(%s)
        """,
        (table, list(NEW_COLUMNS)),
    )
    by_name = {name: (nullable, default) for name, nullable, default in rows}
    assert set(by_name) == set(NEW_COLUMNS)
    assert by_name["is_reconstructed"] == ("NO", "false")
    for name in NEW_COLUMNS[1:]:
        assert by_name[name] == ("YES", None), name


@pytest.mark.parametrize("table", TABLES)
def test_reconstruction_constraints_present_and_not_valid(conn, table):
    rows = _all(
        conn,
        """
        SELECT conname, convalidated FROM pg_constraint
        WHERE conrelid = ('analytics.' || %s)::regclass AND contype = 'c'
          AND conname LIKE 'ck_%%reconstruct%%'
        ORDER BY conname
        """,
        (table,),
    )
    assert rows == [
        (f"ck_{table}_export_reconstruction", False),
        (f"ck_{table}_import_reconstruction", False),
        (f"ck_{table}_is_reconstructed", False),
    ]


@pytest.mark.parametrize("table", TABLES)
def test_no_reconstructed_rows_exist(conn, table):
    assert _one(conn, f"SELECT count(*) FROM analytics.{table} WHERE is_reconstructed")[0] == 0
    assert (
        _one(
            conn,
            f"""
            SELECT count(*) FROM analytics.{table}
            WHERE import_reconstruction_role IS NOT NULL
               OR export_reconstruction_role IS NOT NULL
               OR import_gap_delta_wh IS NOT NULL
               OR export_gap_delta_wh IS NOT NULL
            """,
        )[0]
        == 0
    )


def test_no_view_or_rule_depends_on_the_new_columns(conn):
    """A view that selected a new column would be a behavior change."""
    rows = _all(
        conn,
        """
        SELECT DISTINCT r.ev_class::regclass::text, a.attname
        FROM pg_depend d
        JOIN pg_rewrite r ON r.oid = d.objid
        JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
        WHERE d.refobjid IN ('analytics.energy_consumption_1min'::regclass,
                             'analytics.energy_consumption_5min'::regclass)
          AND a.attname = ANY(%s)
        """,
        (list(NEW_COLUMNS),),
    )
    assert rows == []


def test_no_existing_routine_references_migration_268_objects(conn):
    """Only the three new functions may mention the new objects."""
    rows = _all(
        conn,
        r"""
        SELECT p.oid::regprocedure::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', '_timescaledb_internal',
                                '_timescaledb_functions', '_timescaledb_catalog', 'timescaledb_information',
                                'timescaledb_experimental', '_timescaledb_debug', '_timescaledb_cache',
                                '_timescaledb_config')
          AND p.prokind IN ('f', 'p')
          AND pg_get_functiondef(p.oid) ~* '(is_reconstructed|_reconstruction_role|_reconstruction_method|_gap_delta_wh|energy_reconstruction_scope|energy_reconstruction_enabled|allocate_energy_delta|energy_gap_weights)'
        ORDER BY 1
        """,
    )
    assert sorted(r[0] for r in rows) == sorted(
        [
            "analytics.allocate_energy_delta(numeric,numeric[],integer)",
            "analytics.energy_gap_weights(numeric[])",
            "config.energy_reconstruction_enabled(uuid,uuid)",
        ]
    )


def test_live_routine_inserts_into_native_tables_name_their_columns(conn):
    rows = _all(
        conn,
        r"""
        SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('analytics', 'telemetry', 'admin', 'config', 'metadata')
          AND p.prokind IN ('f', 'p')
          AND pg_get_functiondef(p.oid) ~* 'INSERT\s+INTO\s+analytics\.energy_consumption_(1min|5min)'
        """,
    )
    assert rows, "expected the refresh functions to insert into the native tables"
    insert = re.compile(
        r"INSERT\s+INTO\s+analytics\.energy_consumption_(1min|5min)\b\s*(.)",
        flags=re.IGNORECASE,
    )
    for name, body in rows:
        for match in insert.finditer(body):
            assert match.group(2) == "(", name


@pytest.mark.parametrize("table", TABLES)
def test_legacy_column_list_insert_gets_inert_defaults(tx, table):
    bucket = "2026-01-01 00:00:00+00" if table.endswith("1min") else "2026-01-01 00:05:00+00"
    with tx.cursor() as cur:
        cur.execute(
            f"INSERT INTO analytics.{table} ({LEGACY_INSERT_COLUMNS}) VALUES ({LEGACY_INSERT_VALUES}) "
            f"RETURNING {', '.join(NEW_COLUMNS)}",
            {"bucket": bucket, "org": ORGANIZATION_ID, "site": SITE_ID, "device": DEVICE_ID},
        )
        values = cur.fetchone()
    assert values[0] is False
    assert all(v is None for v in values[1:])


@pytest.mark.parametrize("table", TABLES)
@pytest.mark.parametrize(
    "extra, ok",
    [
        # Consistent complete GAP_END import metadata: accepted.
        ({"is_reconstructed": True, "import_reconstruction_role": "GAP_END",
          "import_reconstruction_method": "TIME_WEIGHTED", "import_gap_start": "2025-12-31 23:00:00+00",
          "import_gap_end": "BUCKET", "import_gap_delta_wh": 10}, True),
        # INTERIOR row strictly inside the gap: accepted.
        ({"is_reconstructed": True, "export_reconstruction_role": "INTERIOR",
          "export_reconstruction_method": "MIXED", "export_gap_start": "2025-12-31 23:00:00+00",
          "export_gap_end": "2026-01-01 01:00:00+00", "export_gap_delta_wh": 0}, True),
        # Flag without metadata: rejected.
        ({"is_reconstructed": True}, False),
        # Metadata without flag: rejected.
        ({"import_reconstruction_role": "INTERIOR", "import_reconstruction_method": "TIME_WEIGHTED",
          "import_gap_start": "2025-12-31 23:00:00+00", "import_gap_end": "2026-01-01 01:00:00+00",
          "import_gap_delta_wh": 1}, False),
        # Incomplete metadata: rejected.
        ({"is_reconstructed": True, "import_reconstruction_role": "INTERIOR"}, False),
        # Unknown method: rejected.
        ({"is_reconstructed": True, "import_reconstruction_role": "INTERIOR",
          "import_reconstruction_method": "GUESSED", "import_gap_start": "2025-12-31 23:00:00+00",
          "import_gap_end": "2026-01-01 01:00:00+00", "import_gap_delta_wh": 1}, False),
        # Bucket outside (gap_start, gap_end]: rejected.
        ({"is_reconstructed": True, "import_reconstruction_role": "INTERIOR",
          "import_reconstruction_method": "TIME_WEIGHTED", "import_gap_start": "2026-01-01 00:10:00+00",
          "import_gap_end": "2026-01-01 01:00:00+00", "import_gap_delta_wh": 1}, False),
        # GAP_END role on a bucket that is not the gap end: rejected.
        ({"is_reconstructed": True, "import_reconstruction_role": "GAP_END",
          "import_reconstruction_method": "TIME_WEIGHTED", "import_gap_start": "2025-12-31 23:00:00+00",
          "import_gap_end": "2026-01-01 01:00:00+00", "import_gap_delta_wh": 1}, False),
        # Negative gap delta: rejected.
        ({"is_reconstructed": True, "import_reconstruction_role": "INTERIOR",
          "import_reconstruction_method": "TIME_WEIGHTED", "import_gap_start": "2025-12-31 23:00:00+00",
          "import_gap_end": "2026-01-01 01:00:00+00", "import_gap_delta_wh": -1}, False),
    ],
)
def test_reconstruction_constraints_are_enforced_on_new_rows(tx, table, extra, ok):
    bucket = "2026-01-01 00:00:00+00" if table.endswith("1min") else "2026-01-01 00:05:00+00"
    extra = {k: (bucket if v == "BUCKET" else v) for k, v in extra.items()}
    cols = LEGACY_INSERT_COLUMNS + "".join(f", {k}" for k in extra)
    vals = LEGACY_INSERT_VALUES + "".join(f", %({k})s" for k in extra)
    params = {"bucket": bucket, "org": ORGANIZATION_ID, "site": SITE_ID, "device": DEVICE_ID, **extra}
    with tx.cursor() as cur:
        if ok:
            cur.execute(f"INSERT INTO analytics.{table} ({cols}) VALUES ({vals})", params)
        else:
            with pytest.raises(psycopg.errors.CheckViolation):
                cur.execute(f"INSERT INTO analytics.{table} ({cols}) VALUES ({vals})", params)


# ---------------------------------------------------------------------------
# Database: the switch (default OFF, precedence, privileges)
# ---------------------------------------------------------------------------


def test_switch_seeded_with_single_disabled_global_row(conn):
    assert _all(
        conn,
        "SELECT scope_type, site_id, device_id, is_enabled FROM config.energy_reconstruction_scope",
    ) == [("GLOBAL", None, None, False)]


def test_switch_resolves_disabled_everywhere_by_default(seed_grafana_tenant_fixture, conn):
    for site, device in ((None, None), (SITE_ID, DEVICE_ID), (SITE_ID, None), (None, DEVICE_ID)):
        assert (
            _one(conn, "SELECT config.energy_reconstruction_enabled(%s::uuid, %s::uuid)", (site, device))[0]
            is False
        )


def test_switch_most_specific_row_wins(seed_grafana_tenant_fixture, tx):
    other_device = "00000000-0000-0000-0000-00000000ffff"
    with tx.cursor() as cur:

        def enabled(site, device):
            cur.execute("SELECT config.energy_reconstruction_enabled(%s::uuid, %s::uuid)", (site, device))
            return cur.fetchone()[0]

        # Canary: GLOBAL off, one DEVICE on.
        cur.execute(
            "INSERT INTO config.energy_reconstruction_scope (scope_type, device_id, is_enabled) "
            "VALUES ('DEVICE', %s, TRUE)",
            (DEVICE_ID,),
        )
        assert enabled(SITE_ID, DEVICE_ID) is True
        assert enabled(SITE_ID, other_device) is False

        # SITE on, DEVICE explicitly off: device stays off, siblings on.
        cur.execute(
            "UPDATE config.energy_reconstruction_scope SET is_enabled = FALSE WHERE scope_type = 'DEVICE'"
        )
        cur.execute(
            "INSERT INTO config.energy_reconstruction_scope (scope_type, site_id, is_enabled) "
            "VALUES ('SITE', %s, TRUE)",
            (SITE_ID,),
        )
        assert enabled(SITE_ID, DEVICE_ID) is False
        assert enabled(SITE_ID, other_device) is True

        # GLOBAL on applies where no more specific row exists.
        cur.execute(
            "UPDATE config.energy_reconstruction_scope SET is_enabled = TRUE WHERE scope_type = 'GLOBAL'"
        )
        assert enabled(None, None) is True
        assert enabled(SITE_ID, DEVICE_ID) is False


@pytest.mark.parametrize(
    "scope_type, use_site, use_device",
    [("GLOBAL", True, False), ("SITE", False, False), ("DEVICE", True, True), ("OTHER", False, False)],
)
def test_switch_scope_target_shape_is_enforced(seed_grafana_tenant_fixture, tx, scope_type, use_site, use_device):
    with tx.cursor() as cur:
        with pytest.raises(psycopg.errors.CheckViolation):
            cur.execute(
                "INSERT INTO config.energy_reconstruction_scope (scope_type, site_id, device_id) "
                "VALUES (%s, %s, %s)",
                (scope_type, SITE_ID if use_site else None, DEVICE_ID if use_device else None),
            )


def test_switch_allows_only_one_global_row(tx):
    with tx.cursor() as cur:
        with pytest.raises(psycopg.errors.UniqueViolation):
            cur.execute("INSERT INTO config.energy_reconstruction_scope (scope_type) VALUES ('GLOBAL')")


def test_new_objects_are_not_public_or_app_writable(conn):
    for signature in NEW_FUNCTIONS:
        assert _one(conn, "SELECT has_function_privilege('public', %s, 'EXECUTE')", (signature,))[0] is False
    for role in ("ems_app", "grafana_reader"):
        exists = _one(conn, "SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %s)", (role,))[0]
        if not exists:
            continue
        for privilege in ("INSERT", "UPDATE", "DELETE"):
            assert (
                _one(
                    conn,
                    "SELECT has_table_privilege(%s, 'config.energy_reconstruction_scope', %s)",
                    (role, privilege),
                )[0]
                is False
            ), (role, privilege)


def test_allocation_functions_are_immutable_and_parallel_safe(conn):
    rows = _all(
        conn,
        """
        SELECT p.oid::regprocedure::text, p.provolatile, p.proparallel, p.proisstrict
        FROM pg_proc p
        WHERE p.oid IN ('analytics.energy_gap_weights(numeric[])'::regprocedure,
                        'analytics.allocate_energy_delta(numeric,numeric[],integer)'::regprocedure)
        """,
    )
    assert len(rows) == 2
    for _name, volatility, parallel, strict in rows:
        assert (volatility, parallel, strict) == ("i", "s", True)


# ---------------------------------------------------------------------------
# Database: analytics.allocate_energy_delta -- exactness
# ---------------------------------------------------------------------------


def _assert_exact(delta, shares):
    assert all(s >= 0 for s in shares), shares
    assert sum(shares, Decimal(0)) == Decimal(str(delta))


def test_single_slot_returns_delta_unchanged(conn):
    for delta in ("0", "1", "1269.389", "123.4567891"):
        assert _allocate(conn, delta, [1]) == [Decimal(delta)]
        assert _allocate(conn, delta, [0.25]) == [Decimal(delta)]


@pytest.mark.parametrize(
    "delta, slots, low, high",
    [
        # COIMBATORE Chiller2 / CoolingTower1 validation gaps (ADR-020 section 11).
        ("238645.2", 188, "1269.389", "1269.390"),
        ("477454.4", 301, "1586.227", "1586.228"),
        ("7961.32", 188, "42.347", "42.348"),
        ("98372.2", 188, "523.256", "523.257"),
    ],
)
def test_time_weighted_allocation_is_exact_and_even(conn, delta, slots, low, high):
    shares = _allocate(conn, delta, [1] * slots)
    assert len(shares) == slots
    _assert_exact(delta, shares)
    assert min(shares) == Decimal(low)
    assert max(shares) == Decimal(high)


def test_zero_delta_allocates_zero_everywhere(conn):
    assert _allocate(conn, "0", [1, 2, 3]) == [Decimal(0)] * 3


def test_power_weighted_allocation_follows_weights(conn):
    shares = _allocate(conn, "600", [100, 200, 300])
    assert shares == [Decimal("100.000"), Decimal("200.000"), Decimal("300")]


def test_zero_weight_slots_receive_nothing(conn):
    shares = _allocate(conn, "10", [0, 5, 0, 5, 0])
    _assert_exact("10", shares)
    assert shares[0] == shares[2] == shares[4] == 0


def test_trailing_zero_weight_with_finer_delta_never_goes_negative(conn):
    # delta has more decimals than the 0.001 allocation scale and the last
    # slot has zero weight: the clamp keeps every share >= 0.
    for delta in ("1.0006", "1.0004", "0.0009", "2.99995"):
        shares = _allocate(conn, delta, [1, 0])
        _assert_exact(delta, shares)


def test_non_default_scale(conn):
    shares = _allocate(conn, "10", [1, 1, 1], scale=0)
    _assert_exact("10", shares)
    assert shares == [Decimal(3), Decimal(4), Decimal(3)]
    shares = _allocate(conn, "1", [1, 1, 1], scale=6)
    _assert_exact("1", shares)


def test_allocation_is_deterministic(conn):
    args = ("477454.4", [random.Random(7).random() for _ in range(301)])
    first = _allocate(conn, *args)
    for _ in range(3):
        assert _allocate(conn, *args) == first


def test_non_one_based_weight_array_is_accepted(conn):
    shares = _one(conn, "SELECT analytics.allocate_energy_delta(9, '[0:2]={1,1,1}'::numeric[])")[0]
    assert shares == [Decimal("3.000"), Decimal("3.000"), Decimal("3")]


def test_allocation_property_randomized(conn):
    """Seeded property test: exact sum, no negatives, bounded rounding error."""
    rng = random.Random(20260925)
    for case in range(250):
        n = rng.choice([1, 2, 3, 7, 15, 60, 188, 301, 600])
        weights = []
        for _ in range(n):
            roll = rng.random()
            if roll < 0.15:
                weights.append(Decimal(0))
            else:
                weights.append(Decimal(str(round(rng.uniform(0.001, 150000), rng.choice([0, 1, 3, 6])))))
        if sum(weights) == 0:
            weights[-1] = Decimal(1)
        delta = Decimal(str(round(rng.uniform(0, 2_000_000), rng.choice([0, 1, 2, 3, 4, 7]))))
        shares = _allocate(conn, delta, weights)
        assert len(shares) == n, case
        _assert_exact(delta, shares)
        total = sum(weights)
        for k, (share, weight) in enumerate(zip(shares, weights)):
            ideal = delta * weight / total
            # cumulative rounding: every share is within 1 unit of the scale
            # of its ideal value, plus delta's own sub-scale remainder on the
            # final share.
            tolerance = MILLI + (abs(delta - delta.quantize(MILLI)) if k == n - 1 else 0) + Decimal("1e-9")
            assert abs(share - ideal) <= tolerance, (case, k, share, ideal)


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT analytics.allocate_energy_delta(-1, ARRAY[1]::numeric[])",
        "SELECT analytics.allocate_energy_delta('NaN'::numeric, ARRAY[1]::numeric[])",
        "SELECT analytics.allocate_energy_delta('Infinity'::numeric, ARRAY[1]::numeric[])",
        "SELECT analytics.allocate_energy_delta(1, ARRAY[]::numeric[])",
        "SELECT analytics.allocate_energy_delta(1, ARRAY[1, NULL]::numeric[])",
        "SELECT analytics.allocate_energy_delta(1, ARRAY[1, -1]::numeric[])",
        "SELECT analytics.allocate_energy_delta(1, ARRAY[0, 0]::numeric[])",
        "SELECT analytics.allocate_energy_delta(1, ARRAY['NaN']::numeric[])",
        "SELECT analytics.allocate_energy_delta(1, ARRAY[[1, 1]]::numeric[])",
        "SELECT analytics.allocate_energy_delta(1, ARRAY[1]::numeric[], -1)",
        "SELECT analytics.allocate_energy_delta(1, ARRAY[1]::numeric[], 13)",
    ],
)
def test_allocation_rejects_invalid_input(conn, sql):
    assert _sqlstate_of(conn, sql) == "22023"


def test_allocation_is_strict_on_null_arguments(conn):
    assert _one(conn, "SELECT analytics.allocate_energy_delta(NULL, ARRAY[1]::numeric[])")[0] is None
    assert _one(conn, "SELECT analytics.allocate_energy_delta(1, NULL)")[0] is None


# ---------------------------------------------------------------------------
# Database: analytics.energy_gap_weights -- method selection
# ---------------------------------------------------------------------------


def test_no_power_is_time_weighted(conn):
    assert _weights(conn, [None, None, None]) == ("TIME_WEIGHTED", [Decimal(1)] * 3)


def test_all_zero_or_negative_power_is_time_weighted(conn):
    assert _weights(conn, [0, 0]) == ("TIME_WEIGHTED", [Decimal(1)] * 2)
    assert _weights(conn, [-5, 0, None]) == ("TIME_WEIGHTED", [Decimal(1)] * 3)


def test_full_coverage_is_active_power_with_negative_clamped(conn):
    method, weights = _weights(conn, [-5, 10, 30])
    assert method == "ACTIVE_POWER"
    assert weights == [Decimal(0), Decimal(10), Decimal(30)]


def test_partial_coverage_is_mixed_with_covered_mean_for_gaps(conn):
    method, weights = _weights(conn, [100, None, 300])
    assert method == "MIXED"
    assert weights == [Decimal(100), Decimal(200), Decimal(300)]


def test_partial_coverage_mean_includes_clamped_negative(conn):
    method, weights = _weights(conn, [-100, None, 300])
    assert method == "MIXED"
    assert weights == [Decimal(0), Decimal(150), Decimal(300)]


def test_nan_and_infinity_are_treated_as_no_reading(conn):
    method, weights = _one(
        conn,
        "SELECT method, weights FROM analytics.energy_gap_weights("
        "ARRAY['NaN', 'Infinity', 60, '-Infinity']::numeric[])",
    )
    assert method == "MIXED"
    assert weights == [Decimal(60)] * 4


def test_single_slot_weights(conn):
    assert _weights(conn, [None]) == ("TIME_WEIGHTED", [Decimal(1)])
    assert _weights(conn, [42]) == ("ACTIVE_POWER", [Decimal(42)])


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT * FROM analytics.energy_gap_weights(ARRAY[]::numeric[])",
        "SELECT * FROM analytics.energy_gap_weights(ARRAY[[1, 2]]::numeric[])",
    ],
)
def test_weights_reject_invalid_arrays(conn, sql):
    assert _sqlstate_of(conn, sql) == "22023"


def test_weights_then_allocation_sum_exactly(conn):
    power = [95000, None, 110000, None, None, 0, 76000]
    method, weights = _weights(conn, power)
    assert method == "MIXED"
    shares = _allocate(conn, "499299.6", weights)
    _assert_exact("499299.6", shares)
    assert shares[5] == 0  # a slot measured at 0 W receives no energy
