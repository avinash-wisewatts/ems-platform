from typing import Any

from src.grafana_client import GrafanaClient
from src.onboarding.organization_service import (
    apply_grafana_reconciliation_mapping,
    get_grafana_reconciliation_context,
)


async def reconcile_grafana_tenant(
    *, portal_user_id: int, organization_id: str,
) -> dict[str, Any]:
    """Detect and safely repair one EMS-to-Grafana tenant contract."""
    context = await get_grafana_reconciliation_context(
        portal_user_id=portal_user_id,
        organization_id=organization_id,
    )
    client = GrafanaClient()
    organizations = await client.list_organizations()
    by_id = {int(row["id"]): row for row in organizations if row.get("id") is not None}
    name_matches = [
        row for row in organizations
        if row.get("name") == context["organization_name"]
    ]
    mapped_id = context.get("mapped_grafana_org_id")
    provisioning_id = context.get("provisioning_grafana_org_id")

    if mapped_id is not None:
        mapped_id = int(mapped_id)
        if mapped_id not in by_id:
            return {
                **context,
                "success": False,
                "reconciliation_status": "MISSING_GRAFANA_ORGANIZATION",
                "failure_reason": (
                    "The authoritative Grafana organization ID is missing. "
                    "Automatic reassignment is prohibited."
                ),
            }
        await client.provision_organization(
            organization_name=context["organization_name"],
            existing_org_id=mapped_id,
        )
        reason = (
            "Realigned provisioning state to the authoritative mapping."
            if provisioning_id != mapped_id
            else "Verified and repaired tenant resources idempotently."
        )
        return await apply_grafana_reconciliation_mapping(
            portal_user_id=portal_user_id,
            organization_id=organization_id,
            grafana_org_id=mapped_id,
            repair_reason=reason,
        )

    if len(name_matches) > 1:
        return {
            **context,
            "success": False,
            "reconciliation_status": "AMBIGUOUS_GRAFANA_NAME",
            "failure_reason": "Multiple Grafana organizations have the EMS organization name.",
        }

    if len(name_matches) == 1:
        grafana_org_id = int(name_matches[0]["id"])
        await client.provision_organization(
            organization_name=context["organization_name"],
            existing_org_id=grafana_org_id,
        )
        return await apply_grafana_reconciliation_mapping(
            portal_user_id=portal_user_id,
            organization_id=organization_id,
            grafana_org_id=grafana_org_id,
            repair_reason="Adopted the unique same-name unowned Grafana organization.",
        )

    grafana_org_id = await client.provision_organization(
        organization_name=context["organization_name"],
        existing_org_id=None,
    )
    return await apply_grafana_reconciliation_mapping(
        portal_user_id=portal_user_id,
        organization_id=organization_id,
        grafana_org_id=grafana_org_id,
        repair_reason="Created the missing Grafana organization and tenant resources.",
    )
