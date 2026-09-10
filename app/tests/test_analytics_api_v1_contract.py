"""Phase 7 -- DB-backed tenant-isolation contract for the /api/v1 query
boundary (migration 231).

Exercises the three analytics.get_portal_* / analytics.portal_user_can_access_*
functions against the disposable ems_test database (see conftest.py for
connection defaults), since cross-tenant isolation, closed-set validation, and
"DEW_POINT is read, never recomputed" all need a real Postgres engine.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import psycopg
import pytest


CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} "
    f"port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} "
    f"user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

ORG_A = "00000000-0000-0000-0000-0000000000b7"
ORG_B = "00000000-0000-0000-0000-0000000001b7"
SITE_A = "00000000-0000-0000-0000-0000000002b7"
SITE_B = "00000000-0000-0000-0000-0000000003b7"
BLDG_A = "00000000-0000-0000-0000-0000000004b7"
FLOOR_A = "00000000-0000-0000-0000-0000000005b7"
SPACE_A = "00000000-0000-0000-0000-0000000006b7"
BLDG_B = "00000000-0000-0000-0000-0000000007b7"
FLOOR_B = "00000000-0000-0000-0000-0000000008b7"
SPACE_B = "00000000-0000-0000-0000-0000000009b7"
DEVICE_A = "00000000-0000-0000-0000-00000000a0b7"

# Fixed measurement window used by every test.
T0 = datetime(2026, 6, 1, 0, 0, tzinfo=timezone.utc)
WINDOW_FROM = T0
WINDOW_TO = T0 + timedelta(hours=3)


@pytest.fixture(scope="module", autouse=True)
def seed() -> None:
    """Deterministic two-tenant fixture. Idempotent (ON CONFLICT DO NOTHING),
    committed as one transaction so the DEFERRABLE portal-user scope triggers
    validate a consistent state."""

    with psycopg.connect(CONNINFO) as conn:  # autocommit=False
        with conn.cursor() as cur:
            # --- structural hierarchy: two orgs, each org one site/bldg/floor/space
            for org, name in ((ORG_A, "P7 Org A"), (ORG_B, "P7 Org B")):
                cur.execute(
                    "INSERT INTO metadata.organizations (id, name, code) "
                    "VALUES (%s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (org, name, "P7_" + name.replace(" ", "_").upper()),
                )
            for site, org, code in (
                (SITE_A, ORG_A, "P7_SITE_A"),
                (SITE_B, ORG_B, "P7_SITE_B"),
            ):
                cur.execute(
                    "INSERT INTO metadata.sites (id, organization_id, name, code) "
                    "VALUES (%s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (site, org, code.replace("_", " "), code),
                )
            for bldg, org, site, code in (
                (BLDG_A, ORG_A, SITE_A, "BLDG_A"),
                (BLDG_B, ORG_B, SITE_B, "BLDG_B"),
            ):
                cur.execute(
                    "INSERT INTO metadata.buildings (id, organization_id, site_id, name, code) "
                    "VALUES (%s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (bldg, org, site, code, code),
                )
            for floor, org, bldg, code in (
                (FLOOR_A, ORG_A, BLDG_A, "FLOOR_A"),
                (FLOOR_B, ORG_B, BLDG_B, "FLOOR_B"),
            ):
                cur.execute(
                    "INSERT INTO metadata.floors (id, organization_id, building_id, name, code) "
                    "VALUES (%s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (floor, org, bldg, code, code),
                )
            for space, org, floor, code in (
                (SPACE_A, ORG_A, FLOOR_A, "SPACE_A"),
                (SPACE_B, ORG_B, FLOOR_B, "SPACE_B"),
            ):
                cur.execute(
                    "INSERT INTO metadata.spaces (id, organization_id, floor_id, name, code) "
                    "VALUES (%s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                    (space, org, floor, code, code),
                )

            # --- portal users: GLOBAL, ORG_A-scoped, ORG_B-scoped, SELECTED_SITES(SITE_A)
            def upsert_user(username, role, org, scope):
                cur.execute(
                    """
                    INSERT INTO admin.portal_users
                        (username, display_name, password_hash, role_code,
                         organization_id, access_scope_mode, created_by)
                    VALUES (%s, %s, '$argon2id$placeholder', %s, %s, %s, 'p7-contract-test')
                    ON CONFLICT (username) DO NOTHING
                    """,
                    (username, username, role, org, scope),
                )
                cur.execute(
                    "SELECT portal_user_id FROM admin.portal_users WHERE username = %s",
                    (username,),
                )
                return cur.fetchone()[0]

            uid_global = upsert_user("p7.global@test", "ADMIN", None, "GLOBAL")
            upsert_user("p7.orga@test", "OPERATOR", ORG_A, "ORGANIZATION")
            upsert_user("p7.orgb@test", "OPERATOR", ORG_B, "ORGANIZATION")
            uid_sel_a = upsert_user("p7.sel-a@test", "VIEWER", ORG_A, "SELECTED_SITES")
            cur.execute(
                "INSERT INTO admin.portal_user_site_access "
                "(portal_user_id, site_id, created_by_portal_user_id) "
                "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                (uid_sel_a, SITE_A, uid_global),
            )

            # --- environment_measurements for SPACE_A: 3 hourly groups x 2 rows/hr
            for hour in range(3):
                for minute in (10, 40):
                    ts = T0 + timedelta(hours=hour, minutes=minute)
                    cur.execute(
                        """
                        INSERT INTO telemetry.environment_measurements
                            (bucket_start, received_at, organization_id, site_id,
                             device_id, space_id, temperature_c, humidity_percent,
                             quality_code)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NULL)
                        ON CONFLICT DO NOTHING
                        """,
                        (
                            ts, ts, ORG_A, SITE_A, DEVICE_A, SPACE_A,
                            20.0 + hour,        # temperature_c
                            50.0 + hour,        # humidity_percent
                        ),
                    )

            # --- DEW_POINT persisted derived rows for SPACE_A. Deliberately a
            # value that does NOT match Magnus(temperature, humidity) for the
            # env rows above, so "the API returns the stored number" is provable.
            cur.execute(
                """
                SELECT pc.id, pc.calculation_version, pc.output_parameter_id
                FROM config.parameter_calculations pc
                JOIN config.parameters op ON op.id = pc.output_parameter_id
                WHERE op.code = 'DEW_POINT'
                ORDER BY pc.calculation_version DESC
                LIMIT 1
                """
            )
            calc = cur.fetchone()
            if calc is not None:
                calc_id, calc_ver, out_param = calc
                for hour in range(3):
                    for minute in (10, 40):
                        ts = T0 + timedelta(hours=hour, minutes=minute)
                        cur.execute(
                            """
                            INSERT INTO analytics.derived_parameter_values
                                (bucket_start, calculation_id, calculation_version,
                                 output_parameter_id, subject_type, space_id, asset_id,
                                 device_id, organization_id, site_id, numeric_value,
                                 state_value, quality_code, input_quality_summary,
                                 source_received_at)
                            VALUES (%s, %s, %s, %s, 'SPACE', %s, NULL, %s, %s, %s,
                                    %s, NULL, NULL, '{"null_handling":"test"}'::jsonb, %s)
                            ON CONFLICT DO NOTHING
                            """,
                            (
                                ts, calc_id, calc_ver, out_param, SPACE_A,
                                DEVICE_A, ORG_A, SITE_A,
                                7.0 + hour,   # stored dew point, NOT Magnus-derived
                                ts,
                            ),
                        )

            # --- energy consumption historians for SITE_A
            _COUNTER_COLS = (
                "source_interval_count, valid_import_intervals, invalid_import_intervals, "
                "valid_export_intervals, invalid_export_intervals, gap_interval_count, "
                "reset_interval_count, rollover_interval_count, invalid_interval_count"
            )
            for hour in range(3):
                ts = T0 + timedelta(hours=hour)
                cur.execute(
                    f"""
                    INSERT INTO analytics.energy_consumption_hourly
                        (bucket_start, organization_id, site_id, device_id,
                         import_consumption_kwh, export_consumption_kwh,
                         {_COUNTER_COLS}, calculated_at)
                    VALUES (%s, %s, %s, %s, %s, %s, 4,4,0,4,0,0,0,0,0, now())
                    ON CONFLICT DO NOTHING
                    """,
                    (ts, ORG_A, SITE_A, DEVICE_A, 1.0 + hour, 0.0),
                )
            for day in range(2):
                ts = T0 + timedelta(days=day)
                cur.execute(
                    f"""
                    INSERT INTO analytics.energy_consumption_daily
                        (bucket_start, consumption_date, site_timezone,
                         organization_id, site_id, device_id,
                         import_consumption_kwh, export_consumption_kwh,
                         {_COUNTER_COLS}, calculated_at)
                    VALUES (%s, %s, 'UTC', %s, %s, %s, %s, %s,
                            96,96,0,96,0,0,0,0,0, now())
                    ON CONFLICT DO NOTHING
                    """,
                    (ts, ts.date(), ORG_A, SITE_A, DEVICE_A, 24.0 + day, 0.0),
                )

        conn.commit()


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        yield connection


def _uid(conn, key: str) -> int:
    # _p7_uids is a TEMP table on the seed connection; re-resolve by username.
    username = {
        "global": "p7.global@test",
        "org_a": "p7.orga@test",
        "org_b": "p7.orgb@test",
        "sel_a": "p7.sel-a@test",
    }[key]
    with conn.cursor() as cur:
        cur.execute(
            "SELECT portal_user_id FROM admin.portal_users WHERE username = %s",
            (username,),
        )
        return cur.fetchone()[0]


def _rows(conn, sql, params):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def _measurements(conn, uid, space, parameter, resolution,
                  dt_from=WINDOW_FROM, dt_to=WINDOW_TO):
    return _rows(
        conn,
        """
        SELECT bucket_start, numeric_value, quality_code, sample_count
        FROM analytics.get_portal_space_measurement_series(%s, %s, %s, %s, %s, %s)
        ORDER BY bucket_start
        """,
        (uid, space, parameter, dt_from, dt_to, resolution),
    )


def _energy(conn, uid, site, resolution, dt_from, dt_to):
    return _rows(
        conn,
        """
        SELECT bucket_start, import_consumption_kwh, export_consumption_kwh,
               source_interval_count
        FROM analytics.get_portal_site_energy_consumption(%s, %s, %s, %s, %s)
        ORDER BY bucket_start
        """,
        (uid, site, dt_from, dt_to, resolution),
    )


# ---------------------------------------------------------------------------
# portal_user_can_access_space
# ---------------------------------------------------------------------------

def test_access_space_global_and_org_and_selected(conn) -> None:
    def can(uid, space):
        return _rows(
            conn,
            "SELECT analytics.portal_user_can_access_space(%s, %s)",
            (uid, space),
        )[0][0]

    assert can(_uid(conn, "global"), SPACE_A) is True
    assert can(_uid(conn, "global"), SPACE_B) is True
    assert can(_uid(conn, "org_a"), SPACE_A) is True
    assert can(_uid(conn, "org_a"), SPACE_B) is False      # cross-org denied
    assert can(_uid(conn, "org_b"), SPACE_A) is False      # cross-org denied
    assert can(_uid(conn, "sel_a"), SPACE_A) is True       # site assigned
    # unknown space -> False, never an error
    assert can(_uid(conn, "global"),
               "ffffffff-ffff-ffff-ffff-ffffffffffff") is False


# ---------------------------------------------------------------------------
# get_portal_space_measurement_series -- tenant isolation
# ---------------------------------------------------------------------------

def test_measurements_cross_org_user_gets_zero_rows(conn) -> None:
    assert _measurements(conn, _uid(conn, "org_b"), SPACE_A, "TEMPERATURE", "raw") == []
    assert _measurements(conn, _uid(conn, "org_b"), SPACE_A, "DEW_POINT", "raw") == []


def test_measurements_global_user_sees_space_a(conn) -> None:
    rows = _measurements(conn, _uid(conn, "global"), SPACE_A, "TEMPERATURE", "raw")
    assert len(rows) == 6
    assert {float(r[1]) for r in rows} == {20.0, 21.0, 22.0}
    assert all(r[2] is None for r in rows)      # quality_code NULL pass-through
    assert all(r[3] == 1 for r in rows)         # raw sample_count


def test_measurements_org_scoped_user_sees_own_space(conn) -> None:
    rows = _measurements(conn, _uid(conn, "org_a"), SPACE_A, "HUMIDITY", "raw")
    assert {float(r[1]) for r in rows} == {50.0, 51.0, 52.0}


def test_measurements_selected_sites_user_sees_assigned_site_space(conn) -> None:
    rows = _measurements(conn, _uid(conn, "sel_a"), SPACE_A, "TEMPERATURE", "raw")
    assert len(rows) == 6


def test_measurements_unknown_space_zero_rows(conn) -> None:
    assert _measurements(
        conn, _uid(conn, "global"),
        "ffffffff-ffff-ffff-ffff-ffffffffffff", "TEMPERATURE", "raw",
    ) == []


# ---------------------------------------------------------------------------
# get_portal_space_measurement_series -- resolution semantics
# ---------------------------------------------------------------------------

def test_measurements_1h_averages_native_values(conn) -> None:
    rows = _measurements(conn, _uid(conn, "global"), SPACE_A, "TEMPERATURE", "1h")
    assert len(rows) == 3
    # each hour has two identical values -> the average equals that value
    assert [round(float(r[1]), 6) for r in rows] == [20.0, 21.0, 22.0]
    assert all(r[2] is None for r in rows)     # averaged rows carry NULL quality
    assert all(r[3] == 2 for r in rows)        # sample_count = values averaged


def test_measurements_empty_range_is_zero_rows_not_error(conn) -> None:
    far = datetime(2000, 1, 1, tzinfo=timezone.utc)
    assert _measurements(
        conn, _uid(conn, "global"), SPACE_A, "TEMPERATURE", "raw",
        dt_from=far, dt_to=far + timedelta(hours=1),
    ) == []


# ---------------------------------------------------------------------------
# DEW_POINT -- persisted, never recomputed
# ---------------------------------------------------------------------------

def test_dew_point_returns_stored_persisted_values_verbatim(conn) -> None:
    rows = _measurements(conn, _uid(conn, "global"), SPACE_A, "DEW_POINT", "raw")
    assert len(rows) == 6
    # exactly the numbers seeded into analytics.derived_parameter_values,
    # which are NOT Magnus(temperature, humidity) for this fixture.
    assert sorted(round(float(r[1]), 6) for r in rows) == [
        7.0, 7.0, 8.0, 8.0, 9.0, 9.0
    ]


def test_dew_point_matches_persisted_table_exactly(conn) -> None:
    api_rows = _measurements(conn, _uid(conn, "global"), SPACE_A, "DEW_POINT", "raw")
    table_rows = _rows(
        conn,
        """
        SELECT d.bucket_start, d.numeric_value
        FROM analytics.derived_parameter_values d
        JOIN config.parameters p ON p.id = d.output_parameter_id
        WHERE p.code = 'DEW_POINT' AND d.space_id = %s
          AND d.bucket_start >= %s AND d.bucket_start < %s
        ORDER BY d.bucket_start
        """,
        (SPACE_A, WINDOW_FROM, WINDOW_TO),
    )
    assert [(r[0], float(r[1])) for r in api_rows] == [
        (r[0], float(r[1])) for r in table_rows
    ]


def test_dew_point_function_body_has_no_formula_or_view(conn) -> None:
    body = _rows(
        conn,
        "SELECT lower(pg_get_functiondef("
        "'analytics.get_portal_space_measurement_series(bigint,uuid,text,"
        "timestamptz,timestamptz,text)'::regprocedure))",
        (),
    )[0][0]
    assert "v_space_dew_point_1min" not in body
    assert "17.62" not in body and "243.12" not in body


# ---------------------------------------------------------------------------
# get_portal_space_measurement_series -- closed-set validation raises
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "parameter,resolution,swap",
    [
        ("PRESSURE", "raw", False),   # unsupported parameter
        ("TEMPERATURE", "5m", False),  # unsupported resolution
        ("TEMPERATURE", "raw", True),  # from >= to
    ],
)
def test_measurements_out_of_contract_raises_22023(conn, parameter, resolution, swap) -> None:
    dt_from, dt_to = (WINDOW_TO, WINDOW_FROM) if swap else (WINDOW_FROM, WINDOW_TO)
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        _measurements(
            conn, _uid(conn, "global"), SPACE_A, parameter, resolution,
            dt_from=dt_from, dt_to=dt_to,
        )


# ---------------------------------------------------------------------------
# get_portal_site_energy_consumption
# ---------------------------------------------------------------------------

def test_energy_cross_org_user_gets_zero_rows(conn) -> None:
    assert _energy(
        conn, _uid(conn, "org_b"), SITE_A, "1h", WINDOW_FROM, WINDOW_TO
    ) == []


def test_energy_hourly_rollup_for_accessible_site(conn) -> None:
    rows = _energy(conn, _uid(conn, "global"), SITE_A, "1h", WINDOW_FROM, WINDOW_TO)
    assert len(rows) == 3
    assert [round(float(r[1]), 6) for r in rows] == [1.0, 2.0, 3.0]
    assert [int(r[3]) for r in rows] == [4, 4, 4]


def test_energy_daily_rollup_for_accessible_site(conn) -> None:
    rows = _energy(
        conn, _uid(conn, "global"), SITE_A, "1d",
        WINDOW_FROM, WINDOW_FROM + timedelta(days=2),
    )
    assert len(rows) == 2
    assert [round(float(r[1]), 6) for r in rows] == [24.0, 25.0]


def test_energy_selected_sites_user_sees_assigned_site(conn) -> None:
    rows = _energy(conn, _uid(conn, "sel_a"), SITE_A, "1h", WINDOW_FROM, WINDOW_TO)
    assert len(rows) == 3


@pytest.mark.parametrize("resolution", ["raw", "5m", "15m"])
def test_energy_unsupported_resolution_raises(conn, resolution) -> None:
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        _energy(conn, _uid(conn, "global"), SITE_A, resolution, WINDOW_FROM, WINDOW_TO)


def test_energy_function_body_is_read_only(conn) -> None:
    body = _rows(
        conn,
        "SELECT lower(pg_get_functiondef("
        "'analytics.get_portal_site_energy_consumption(bigint,uuid,"
        "timestamptz,timestamptz,text)'::regprocedure))",
        (),
    )[0][0]
    for forbidden in (
        "insert into", "update ", "delete from",
        "load_energy", "refresh_energy", "refresh_continuous_aggregate",
        "energy_measurements", "normalized_points",
    ):
        assert forbidden not in body, forbidden


# ---------------------------------------------------------------------------
# grants / definer discipline
# ---------------------------------------------------------------------------

def test_boundary_functions_are_definer_stable_and_scoped(conn) -> None:
    rows = _rows(
        conn,
        """
        SELECT p.proname, p.prosecdef, p.provolatile,
               r.rolname AS owner,
               has_function_privilege('ems_app', p.oid, 'EXECUTE') AS ems_app_exec,
               has_function_privilege('public',  p.oid, 'EXECUTE') AS public_exec
        FROM pg_proc p
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.pronamespace = 'analytics'::regnamespace
          AND p.proname IN (
            'portal_user_can_access_space',
            'get_portal_space_measurement_series',
            'get_portal_site_energy_consumption'
          )
        ORDER BY p.proname
        """,
        (),
    )
    assert len(rows) == 3
    for name, secdef, volatile, owner, ems_app_exec, public_exec in rows:
        assert secdef is True, name
        assert volatile == "s", name           # STABLE
        assert owner == "ems_admin", name
        assert ems_app_exec is True, name
        assert public_exec is False, name
