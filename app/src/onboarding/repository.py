from typing import Any

from src.database import database_connection


async def list_device_profiles() -> list[dict[str, Any]]:
    """
    Return active payload profiles with controlled category compatibility.
    """
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    profile_code,
                    profile_name,
                    manufacturer,
                    model,
                    firmware_version,
                    description,
                    device_category_ids,
                    device_category_names
                FROM admin.v_active_device_profiles
                ORDER BY profile_code
                """
            )
            return await cursor.fetchall()


async def list_asset_types() -> list[dict[str, Any]]:
    """Return operational asset types available for onboarding."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    name,
                    description
                FROM admin.v_asset_types
                ORDER BY name, id
                """
            )
            return await cursor.fetchall()


async def list_device_categories() -> list[dict[str, Any]]:
    """Return controlled physical-device categories."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    name,
                    description
                FROM admin.v_device_categories
                ORDER BY name
                """
            )
            return await cursor.fetchall()


async def list_assets() -> list[dict[str, Any]]:
    """
    Return existing operational assets available for controlled attachment.

    The database function still validates that the chosen asset belongs to the
    organization and site submitted with the onboarding request.
    """
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    organization_id,
                    organization_code,
                    site_id,
                    site_code,
                    space_id,
                    parent_asset_id,
                    asset_type_id,
                    asset_type_name,
                    asset_name,
                    status,
                    metering_requirement
                FROM admin.v_assets
                WHERE status IS NULL
                   OR lower(status) = 'active'
                ORDER BY
                    organization_code,
                    site_code,
                    asset_name,
                    id
                """
            )
            return await cursor.fetchall()


async def list_spaces() -> list[dict[str, Any]]:
    """Return existing tenant-aware spaces for controlled asset placement."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    organization_id,
                    organization_code,
                    site_id,
                    site_code,
                    building_id,
                    building_code,
                    building_name,
                    floor_id,
                    floor_code,
                    floor_name,
                    space_code,
                    space_name
                FROM admin.v_spaces
                ORDER BY
                    organization_code,
                    site_code,
                    building_code,
                    floor_code,
                    space_code,
                    id
                """
            )
            return await cursor.fetchall()


async def list_organizations() -> list[dict[str, Any]]:
    """Return active organizations available to the onboarding wizard."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    organization_code,
                    organization_name,
                    description,
                    is_active
                FROM admin.v_organizations
                ORDER BY organization_name, organization_code, id
                """
            )
            return await cursor.fetchall()


async def list_sites() -> list[dict[str, Any]]:
    """
    Return active sites with organization ownership.

    Browser filtering improves usability, while the database onboarding
    function remains the authoritative ownership validator.
    """
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    organization_id,
                    organization_code,
                    organization_name,
                    site_code,
                    site_name,
                    timezone,
                    address,
                    is_active
                FROM admin.v_sites
                ORDER BY
                    organization_name,
                    site_name,
                    site_code,
                    id
                """
            )
            return await cursor.fetchall()


async def list_gateways() -> list[dict[str, Any]]:
    """Return gateways with organization, site, and location ownership."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    organization_id,
                    organization_code,
                    organization_name,
                    site_id,
                    site_code,
                    site_name,
                    space_id,
                    space_code,
                    space_name,
                    gateway_model_id,
                    gateway_vendor,
                    gateway_model,
                    gateway_protocol,
                    external_id,
                    gateway_name
                FROM admin.v_gateways
                ORDER BY
                    organization_name,
                    site_name,
                    gateway_name,
                    external_id,
                    id
                """
            )
            return await cursor.fetchall()


async def list_devices() -> list[dict[str, Any]]:
    """Return devices with their resolved gateway, category, and profile."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    organization_id,
                    organization_code,
                    organization_name,
                    gateway_id,
                    site_id,
                    site_code,
                    site_name,
                    gateway_external_id,
                    gateway_name,
                    device_model_id,
                    device_vendor,
                    device_model,
                    device_category_id,
                    device_category_name,
                    profile_id,
                    profile_code,
                    profile_name,
                    external_id,
                    device_name,
                    serial_number,
                    firmware_version,
                    protocol
                FROM admin.v_devices
                ORDER BY
                    organization_name,
                    site_name,
                    gateway_name,
                    device_name,
                    external_id,
                    id
                """
            )
            return await cursor.fetchall()


async def list_buildings() -> list[dict[str, Any]]:
    """Return controlled building hierarchy records."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    organization_id,
                    organization_code,
                    site_id,
                    site_code,
                    building_code,
                    building_name,
                    created_at
                FROM admin.v_buildings
                ORDER BY
                    organization_code,
                    site_code,
                    building_code,
                    id
                """
            )
            return await cursor.fetchall()


async def list_floors() -> list[dict[str, Any]]:
    """Return controlled floor hierarchy records."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    organization_id,
                    organization_code,
                    site_id,
                    site_code,
                    building_id,
                    building_code,
                    building_name,
                    floor_code,
                    floor_name,
                    created_at
                FROM admin.v_floors
                ORDER BY
                    organization_code,
                    site_code,
                    building_code,
                    floor_code,
                    id
                """
            )
            return await cursor.fetchall()


async def list_gateway_models() -> list[dict[str, Any]]:
    """Return controlled gateway manufacturer/model combinations."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    vendor,
                    model,
                    protocol,
                    created_at
                FROM admin.v_gateway_models
                ORDER BY
                    vendor,
                    model,
                    protocol,
                    id
                """
            )
            return await cursor.fetchall()


async def list_device_models() -> list[dict[str, Any]]:
    """Return controlled device model catalog records."""
    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT
                    id,
                    vendor,
                    model,
                    device_type,
                    created_at,
                    device_category_id,
                    device_category_name
                FROM admin.v_device_models
                ORDER BY
                    vendor,
                    model,
                    id
                """
            )
            return await cursor.fetchall()
