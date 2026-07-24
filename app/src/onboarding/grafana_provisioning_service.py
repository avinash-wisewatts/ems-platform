from typing import Any

from src.grafana_client import GrafanaApiError, GrafanaClient
from src.onboarding.organization_service import (
    get_grafana_provisioning,
    mark_grafana_provisioning_complete,
    mark_grafana_provisioning_failed,
    mark_grafana_provisioning_pending,
)


async def provision_grafana_for_organization(
    *,
    organization_id: str,
    organization_name: str,
) -> dict[str, Any]:
    """
    Provision Grafana resources for one EMS organization.

    EMS organization creation is authoritative and is never rolled back when
    Grafana provisioning fails.
    """

    existing_state = await get_grafana_provisioning(
        organization_id
    )

    existing_grafana_org_id = None

    if existing_state is not None:
        existing_grafana_org_id = existing_state.get(
            "grafana_org_id"
        )

    await mark_grafana_provisioning_pending(
        organization_id
    )

    client = GrafanaClient()

    try:
        grafana_org_id = await client.provision_organization(
            organization_name=organization_name,
            existing_org_id=existing_grafana_org_id,
        )

    except GrafanaApiError as exc:
        return await mark_grafana_provisioning_failed(
            organization_id,
            str(exc),
        )

    return await mark_grafana_provisioning_complete(
        organization_id,
        grafana_org_id,
    )
