from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

MAIN = Path("app/src/main.py").read_text()
DETAIL = Path("app/src/templates/device_detail.html").read_text()
EDIT = Path("app/src/templates/device_edit.html").read_text()
CREATE = Path("app/src/templates/device_create.html").read_text()
ONBOARDING = Path("app/src/templates/onboarding.html").read_text()
RESULT = Path("app/src/templates/onboarding_result.html").read_text()
SQL = Path(
    "postgres/migrations/177_device_commissioning_experience_and_controlled_activation.sql"
).read_text()


def test_device_headers_link_to_operational_lifecycle():
    assert '#operational-lifecycle' in DETAIL
    assert '#operational-lifecycle' in EDIT
    assert 'commissioning_display_status' in DETAIL
    assert 'commissioning_display_status' in EDIT


def test_operational_section_is_compact_and_expandable():
    assert 'id="operational-lifecycle"' in DETAIL
    assert 'commissioning-readiness-details' in DETAIL
    assert 'Asset assignment requirement' in DETAIL
    assert 'Operational policy' not in DETAIL


def test_user_facing_asset_assignment_terminology():
    assert 'Asset assignment requirement' in CREATE
    assert 'Asset assignment requirement' in EDIT
    assert 'Required before commissioning' in CREATE
    assert 'Optional' in EDIT


def test_onboarding_calls_out_pending_commissioning():
    assert 'Commissioning pending' in ONBOARDING
    assert 'Commissioning pending' in RESULT
    assert 'review readiness and complete commissioning' in RESULT


def test_commission_failures_return_to_device_context():
    assert 'commissioning_error=' in MAIN
    assert '#operational-lifecycle' in MAIN
    assert 'DEVICE_COMMISSIONING_BLOCKERS' in MAIN


def test_controlled_activation_remains_guarded():
    assert "current_setting('ems.controlled_device_commissioning_id', TRUE)" in SQL
    assert "set_config(" in SQL
    assert "current_user = 'ems_admin'" in SQL
    assert "Use the controlled commissioning action" in SQL
    assert "CREATE OR REPLACE FUNCTION admin.commission_device" in SQL
    assert "to_regclass('admin.portal_users')" in SQL


def test_device_create_page_does_not_reference_missing_device_context() -> None:
    route = MAIN.split('async def device_create_page', 1)[1].split('@app.post', 1)[0]
    assert '_device_commissioning_context(device)' not in route


def test_device_create_submit_error_context_does_not_reference_missing_device() -> None:
    route = MAIN.split('async def create_device_administration', 1)[1].split('async def _accessible_device_or_none', 1)[0]
    assert '_device_commissioning_context(device)' not in route


def test_device_edit_routes_supply_commissioning_display_context() -> None:
    get_route = MAIN.split('async def device_edit_page', 1)[1].split('@app.post', 1)[0]
    post_route = MAIN.split('async def device_edit_submit', 1)[1].split('@app.post', 1)[0]
    assert '**_device_commissioning_context(device)' in get_route
    assert '**_device_commissioning_context(device)' in post_route


def test_active_onboarding_templates_show_commissioning_pending_notes() -> None:
    device_template = (ROOT / 'app/src/templates/onboarding/device.html').read_text()
    result_template = (ROOT / 'app/src/templates/onboarding/result.html').read_text()
    assert 'Commissioning pending' in device_template
    assert 'After onboarding, open this device from the Devices tab' in device_template
    assert 'Commissioning pending' in result_template
    assert 'The device was created successfully' in result_template
