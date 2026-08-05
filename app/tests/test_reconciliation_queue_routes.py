from pathlib import Path

from src.admin_navigation import administration_navigation


MAIN = (
    Path(__file__).parents[1] / "src/main.py"
).read_text()

TEMPLATE = (
    Path(__file__).parents[1]
    / "src/templates/reconciliation_queue.html"
).read_text()


def test_route_template_and_navigation_exist() -> None:
    assert '"/administration/reconciliation"' in MAIN
    assert 'name="reconciliation_queue.html"' in MAIN
    assert "Reconciliation queue" in TEMPLATE

    items = {
        item.key: item
        for section in administration_navigation(
            "ADMIN",
            "GLOBAL",
        )
        for item in section.items
    }

    assert "reconciliation" in items
    assert (
        items["reconciliation"].href
        == "/administration/reconciliation"
    )
