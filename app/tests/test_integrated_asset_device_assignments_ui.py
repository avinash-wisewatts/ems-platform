from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_relationships_removed_from_sidebar_and_legacy_page_redirects():
    navigation = (ROOT / "app/src/admin_navigation.py").read_text()
    main = (ROOT / "app/src/main.py").read_text()
    assert '"relationships"' not in navigation
    assert 'RedirectResponse("/administration/assets", status_code=303)' in main


def test_asset_workspace_owns_assignment_management():
    template = (ROOT / "app/src/templates/asset_detail.html").read_text()
    assert 'id="assigned-devices"' in template
    assert 'Assign device' in template
    assert 'replace-primary-meter' in template
    assert '/remove' in template
    assert '/metadata' in template


def test_device_workspace_has_reverse_assignment_view():
    template = (ROOT / "app/src/templates/device_detail.html").read_text()
    assert 'id="asset-assignments"' in template
    assert 'Assign to asset' in template
    assert 'Manage on asset' in template
