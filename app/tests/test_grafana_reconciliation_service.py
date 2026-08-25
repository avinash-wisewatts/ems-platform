import pytest
from src.onboarding.grafana_reconciliation_service import reconcile_grafana_tenant

@pytest.mark.asyncio
async def test_existing_mapping_is_reused_and_repaired(monkeypatch):
    async def context(**kwargs): return {"organization_id":"o1","organization_name":"Org One","mapped_grafana_org_id":7,"provisioning_grafana_org_id":9}
    class Client:
        async def list_organizations(self): return [{"id":7,"name":"Org One"}]
        async def provision_organization(self, **kwargs):
            assert kwargs["existing_org_id"]==7
            return {
                "grafana_org_id": 7,
                "datasource_action": "updated",
                "datasource_uid": "ems-timescaledb",
                "datasource_name": "EMS TimescaleDB",
                "datasource_version": 2,
            }
    async def apply(**kwargs): return {"success":True,"reconciliation_status":"REPAIRED","grafana_org_id":kwargs["grafana_org_id"]}
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.get_grafana_reconciliation_context",context)
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.GrafanaClient",Client)
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.apply_grafana_reconciliation_mapping",apply)
    result=await reconcile_grafana_tenant(portal_user_id=1,organization_id="o1")
    assert result["grafana_org_id"]==7
    assert result["datasource_action"]=="updated"
    assert result["datasource_uid"]=="ems-timescaledb"

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

@pytest.mark.asyncio
async def test_datasource_write_failure_propagates_uncaught(monkeypatch):
    """
    Regression test: if GrafanaClient.provision_organization() raises
    (e.g. the version-did-not-increase check added after the live
    stale-password incident), reconcile_grafana_tenant() must not swallow
    it -- it has to propagate so the route's existing GrafanaApiError
    handler can render a real failure instead of a false 200.
    """
    from src.grafana_client import GrafanaApiError

    async def context(**kwargs): return {"organization_id":"o1","organization_name":"Org One","mapped_grafana_org_id":7,"provisioning_grafana_org_id":7}
    class Client:
        async def list_organizations(self): return [{"id":7,"name":"Org One"}]
        async def provision_organization(self, **kwargs):
            raise GrafanaApiError(
                "Datasource ems-timescaledb update did not take effect: "
                "version remained 1 in Grafana organization 7 "
                "(expected greater than 1)."
            )
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.get_grafana_reconciliation_context",context)
    monkeypatch.setattr("src.onboarding.grafana_reconciliation_service.GrafanaClient",Client)
    with pytest.raises(GrafanaApiError, match="did not take effect"):
        await reconcile_grafana_tenant(portal_user_id=1,organization_id="o1")
