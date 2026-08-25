import json
from pathlib import Path
from typing import Any

import httpx

from src.config import get_settings


DASHBOARD_DIRECTORY = Path("/app/grafana-dashboards")
DATASOURCE_UID = "ems-timescaledb"
DATASOURCE_NAME = "EMS TimescaleDB"
FOLDER_UID = "ems"
FOLDER_TITLE = "EMS"


class GrafanaApiError(RuntimeError):
    """Raised when Grafana rejects or cannot complete provisioning."""


def _describe_write_response(response: httpx.Response) -> str:
    """
    Summarize a write response for a verification-failure error message.

    Only describes the *response* Grafana sent back (status code, any
    redirect target, a truncated response body) -- never the request that
    produced it, so this can never echo the datasource password back into
    an error message, log, or rendered page.
    """

    location = response.headers.get("location")
    redirect_note = f" Redirected to: {location}." if location else ""
    body_preview = response.text[:200].replace("\n", " ")

    return (
        f"Write response was HTTP {response.status_code}.{redirect_note} "
        f"Body preview: {body_preview!r}"
    )


class GrafanaClient:
    """Small async client for Grafana organization provisioning."""

    def __init__(self) -> None:
        settings = get_settings()
        self.datasource_password = settings.grafana_db_password
        self.base_url = settings.grafana_url.rstrip("/")
        self.auth = httpx.BasicAuth(
            settings.grafana_admin_user,
            settings.grafana_admin_password,
        )

    async def _request(
        self,
        method: str,
        path: str,
        *,
        org_id: int | None = None,
        json_payload: dict[str, Any] | None = None,
    ) -> httpx.Response:
        headers: dict[str, str] = {}

        if org_id is not None:
            headers["X-Grafana-Org-Id"] = str(org_id)

        try:
            async with httpx.AsyncClient(
                base_url=self.base_url,
                auth=self.auth,
                timeout=15.0,
            ) as client:
                response = await client.request(
                    method,
                    path,
                    headers=headers,
                    json=json_payload,
                )
        except httpx.HTTPError as exc:
            raise GrafanaApiError(
                f"Grafana request failed: {exc}"
            ) from exc

        if response.status_code >= 400:
            raise GrafanaApiError(
                f"Grafana returned HTTP {response.status_code}: "
                f"{response.text}"
            )

        return response

    async def list_organizations(self) -> list[dict[str, Any]]:
        response = await self._request("GET", "/api/orgs")
        return response.json()

    async def create_organization(self, name: str) -> int:
        response = await self._request(
            "POST",
            "/api/orgs",
            json_payload={"name": name},
        )

        payload = response.json()
        organization_id = payload.get("orgId")

        if not isinstance(organization_id, int):
            raise GrafanaApiError(
                "Grafana organization response did not include orgId."
            )

        return organization_id

    async def get_datasource_by_uid(
        self,
        org_id: int,
    ) -> dict[str, Any] | None:
        try:
            response = await self._request(
                "GET",
                f"/api/datasources/uid/{DATASOURCE_UID}",
                org_id=org_id,
            )
        except GrafanaApiError as exc:
            if "HTTP 404" in str(exc):
                return None
            raise

        return response.json()

    def _datasource_payload(self) -> dict[str, Any]:
        """
        Build the canonical TimescaleDB datasource configuration.

        Shared by create_datasource() and update_datasource() so the two
        operations cannot drift apart from each other.
        """

        return {
            "name": DATASOURCE_NAME,
            "uid": DATASOURCE_UID,
            "type": "grafana-postgresql-datasource",
            "access": "proxy",
            "url": "timescaledb:5432",
            "database": "ems",
            "user": "grafana_reader",
            "isDefault": True,
            "jsonData": {
                "sslmode": "disable",
                "postgresVersion": 1600,
                "timescaledb": True,
                "maxOpenConns": 10,
                "maxIdleConns": 5,
                "connMaxLifetime": 14400,
            },
            "secureJsonData": {
                "password": self.datasource_password,
            },
        }

    async def create_datasource(
        self,
        org_id: int,
    ) -> dict[str, Any]:
        write_response = await self._request(
            "POST",
            "/api/datasources",
            org_id=org_id,
            json_payload=self._datasource_payload(),
        )

        verified = await self.get_datasource_by_uid(org_id)

        if verified is None:
            raise GrafanaApiError(
                f"Datasource {DATASOURCE_UID} was not found in Grafana "
                f"organization {org_id} immediately after creation; the "
                "write did not take effect. "
                f"{_describe_write_response(write_response)}"
            )

        return verified

    async def update_datasource(
        self,
        org_id: int,
        previous_version: int | None,
    ) -> dict[str, Any]:
        """
        Reconcile an existing datasource to the current canonical
        configuration, including the current EMS_GRAFANA_DB_PASSWORD.

        Grafana does not merge secureJsonData on PUT: fields omitted from
        secureJsonData are left as previously stored, but a password
        included here is always applied, which is exactly the update this
        method exists to make. The UID-based endpoint is used so the
        existing stable "ems-timescaledb" identity is never replaced.

        A PUT that Grafana accepts (HTTP < 400) is not, on its own, proof
        the datasource was actually changed -- it only proves the request
        was well-formed. Grafana increments the datasource's `version`
        field on every write it actually persists, so this method re-reads
        the datasource after the PUT and requires `version` to have
        increased. Without this check, a request that Grafana silently
        accepted without applying (or applied to a different record than
        expected) would be indistinguishable from a genuine repair -- which
        is exactly the failure mode this method exists to rule out.
        """

        write_response = await self._request(
            "PUT",
            f"/api/datasources/uid/{DATASOURCE_UID}",
            org_id=org_id,
            json_payload=self._datasource_payload(),
        )

        verified = await self.get_datasource_by_uid(org_id)

        if verified is None:
            raise GrafanaApiError(
                f"Datasource {DATASOURCE_UID} was not found in Grafana "
                f"organization {org_id} immediately after update. "
                f"{_describe_write_response(write_response)}"
            )

        new_version = verified.get("version")

        if (
            previous_version is not None
            and new_version is not None
            and new_version <= previous_version
        ):
            raise GrafanaApiError(
                f"Datasource {DATASOURCE_UID} update did not take effect: "
                f"version remained {new_version} in Grafana organization "
                f"{org_id} (expected greater than {previous_version}). "
                f"{_describe_write_response(write_response)}"
            )

        return verified

    async def ensure_folder(self, org_id: int) -> None:
        try:
            await self._request(
                "GET",
                f"/api/folders/{FOLDER_UID}",
                org_id=org_id,
            )
            return
        except GrafanaApiError as exc:
            if "HTTP 404" not in str(exc):
                raise

        await self._request(
            "POST",
            "/api/folders",
            org_id=org_id,
            json_payload={
                "uid": FOLDER_UID,
                "title": FOLDER_TITLE,
            },
        )

    async def import_dashboards(self, org_id: int) -> None:
        dashboard_files = sorted(
            DASHBOARD_DIRECTORY.rglob("*.json")
        )

        if not dashboard_files:
            raise GrafanaApiError(
                "No Grafana dashboard JSON files were found."
            )

        for dashboard_file in dashboard_files:
            dashboard = json.loads(
                dashboard_file.read_text(encoding="utf-8")
            )

            await self._request(
                "POST",
                "/api/dashboards/db",
                org_id=org_id,
                json_payload={
                    "dashboard": dashboard,
                    "folderUid": FOLDER_UID,
                    "overwrite": True,
                },
            )

    async def provision_organization(
        self,
        *,
        organization_name: str,
        existing_org_id: int | None = None,
    ) -> dict[str, Any]:
        """
        Ensure the Grafana organization and its EMS resources exist.

        Existing mappings take precedence over name matching.

        Returns a result describing what actually happened -- not just the
        resolved organization id -- so callers (and, ultimately, the admin
        UI) can distinguish "created", "updated", and can surface the
        verified post-write datasource version rather than merely reporting
        that no HTTP error occurred.
        """

        grafana_org_id = existing_org_id

        if grafana_org_id is None:
            organizations = await self.list_organizations()

            matching_organization = next(
                (
                    organization
                    for organization in organizations
                    if organization.get("name") == organization_name
                ),
                None,
            )

            if matching_organization is not None:
                grafana_org_id = int(
                    matching_organization["id"]
                )
            else:
                grafana_org_id = await self.create_organization(
                    organization_name
                )

        datasource = await self.get_datasource_by_uid(
            grafana_org_id
        )

        if datasource is None:
            verified_datasource = await self.create_datasource(
                grafana_org_id
            )
            datasource_action = "created"
        else:
            verified_datasource = await self.update_datasource(
                grafana_org_id,
                datasource.get("version"),
            )
            datasource_action = "updated"

        await self.ensure_folder(grafana_org_id)
        await self.import_dashboards(grafana_org_id)

        return {
            "grafana_org_id": grafana_org_id,
            "datasource_action": datasource_action,
            "datasource_uid": DATASOURCE_UID,
            "datasource_name": DATASOURCE_NAME,
            "datasource_version": verified_datasource.get("version"),
        }
