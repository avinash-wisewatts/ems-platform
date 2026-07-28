import pytest
from src.onboarding.grafana_reconciliation_service import reconcile_grafana_tenant

@pytest.mark.asyncio
async def test_existing_mapping_is_reused_and_repaired(monkeypatch):
    async def context(**kwargs): return {"organization_id":"o1","organization_name":"Org One","mapped_grafana_org_id":7,"provisioning_grafana_org_id":9}
    class Client:
        async def list_organizations(self): return [{"id":7,"name":"Org One"}]
        async def provision_organization(self, **kwargs): assert kwargs["existing_org_id"]==7; return 7
    async def apply(**kwargs): return {"success":True,"reconciliation_status":"REPAIRED","grafana_org_id":kwargs["grafana_org_id"]}
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.get_grafana_reconciliation_context",context)
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.GrafanaClient",Client)
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.apply_grafana_reconciliation_mapping",apply)
    result=await reconcile_grafana_tenant(portal_user_id=1,organization_id="o1")
    assert result["grafana_org_id"]==7

@pytest.mark.asyncio
async def test_missing_authoritative_mapping_is_not_reassigned(monkeypatch):
    async def context(**kwargs): return {"organization_id":"o1","organization_name":"Org One","mapped_grafana_org_id":7,"provisioning_grafana_org_id":7}
    class Client:
        async def list_organizations(self): return [{"id":8,"name":"Org One"}]
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.get_grafana_reconciliation_context",context)
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.GrafanaClient",Client)
    result=await reconcile_grafana_tenant(portal_user_id=1,organization_id="o1")
    assert result["success"] is False
    assert result["reconciliation_status"]=="MISSING_GRAFANA_ORGANIZATION"
