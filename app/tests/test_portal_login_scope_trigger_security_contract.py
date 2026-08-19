from pathlib import Path

MIGRATION = (
    Path(__file__).parents[2]
    / "postgres/ddl/103_portal_login_scope_trigger_security.sql"
).read_text(encoding="utf-8")


def test_site_scope_trigger_is_security_definer_and_owner_controlled():
    assert "ALTER FUNCTION admin.enforce_portal_user_site_scope()" in MIGRATION
    assert "OWNER TO ems_admin" in MIGRATION
    assert "SECURITY DEFINER" in MIGRATION
    assert "SET search_path TO pg_catalog, admin, metadata" in MIGRATION


def test_site_scope_trigger_does_not_broaden_application_table_access():
    assert "GRANT SELECT ON admin.portal_users TO ems_app" not in MIGRATION
    assert "GRANT SELECT ON admin.portal_user_site_access TO ems_app" not in MIGRATION
    assert "REVOKE ALL ON FUNCTION" in MIGRATION
    assert "FROM PUBLIC" in MIGRATION
