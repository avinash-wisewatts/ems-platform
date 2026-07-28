from src.reconciliation_queue_service import ISSUE_TYPES, summarize_reconciliation_queue

def test_issue_types_are_canonical():
    assert len(ISSUE_TYPES) == 6
    assert "FAILED_GRAFANA_PROVISIONING" in ISSUE_TYPES

def test_summary_counts_severity():
    rows=[{"severity":"HIGH"},{"severity":"MEDIUM"},{"severity":"LOW"},{"severity":"HIGH"}]
    assert summarize_reconciliation_queue(rows)=={"total":4,"high":2,"medium":1,"low":1}
