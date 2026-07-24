from typing import Any

from psycopg.errors import DatabaseError

from src.database import database_connection
from src.onboarding.forms import OnboardingValidationError
from src.onboarding.result_contract import build_onboarding_result


# Device categories are resolved by controlled catalog name, not UUID.
# This avoids coupling application rules to environment-specific identifiers.
CATEGORY_RELATIONSHIPS: dict[str, set[str]] = {
    "Energy Meter": {
        "PRIMARY_METER",
        "SECONDARY_METER",
        "SUB_METER",
    },
    "Environmental Sensor": {
        "TEMPERATURE_SENSOR",
        "HUMIDITY_SENSOR",
    },
    "Temperature Sensor": {
        "TEMPERATURE_SENSOR",
    },
    "Flow Meter": {
        "FLOW_SENSOR",
    },
    "Pressure Sensor": {
        "PRESSURE_SENSOR",
    },
    "Digital Input Module": {
        "STATUS_INPUT",
        "RUN_STATUS",
        "FAULT_STATUS",
    },
    "BMS Controller": {
        "CONTROLLER",
    },
    "PLC": {
        "CONTROLLER",
        "STATUS_INPUT",
        "RUN_STATUS",
        "FAULT_STATUS",
    },
    # A gateway is communications infrastructure rather than a device
    # attached directly to an operational asset.
    "Gateway": set(),
}


async def onboard_energy_asset(
    request_payload: dict[str, Any],
    requested_by: str,
) -> dict[str, Any]:
    """
    Validate device-to-asset compatibility and execute atomic onboarding.

    CREATE_NEW devices:
        Validate the submitted category and profile compatibility.

    USE_EXISTING devices:
        Resolve the stored category and profile from the controlled device
        lookup view. The caller does not need to resubmit device attributes.

    The restricted application role reads controlled admin views and executes
    the SECURITY DEFINER onboarding function. It cannot write directly to the
    metadata tables.
    """

    device = request_payload.get("device", {})
    asset = request_payload.get("asset", {})

    device_mode = str(
        device.get("mode") or "CREATE_NEW"
    ).strip().upper()

    relationship_type = str(
        asset.get("relationship_type") or ""
    ).strip().upper()

    async with database_connection() as connection:
        try:
            async with connection.cursor() as cursor:
                if device_mode == "CREATE_NEW":
                    device_category_id = device.get(
                        "device_category_id"
                    )
                    profile_code = device.get("profile_code")

                    await cursor.execute(
                        """
                        SELECT
                            id,
                            name
                        FROM admin.v_device_categories
                        WHERE id = %s::uuid
                        """,
                        (device_category_id,),
                    )

                    category = await cursor.fetchone()

                    if category is None:
                        raise OnboardingValidationError(
                            "The selected device category does not exist.",
                            field_name="device_category_id",
                        )

                    category_name = category["name"]

                    await cursor.execute(
                        """
                        SELECT EXISTS
                        (
                            SELECT 1
                            FROM admin.v_active_device_profiles profile
                            WHERE profile.profile_code = %s
                              AND %s::uuid = ANY(
                                  profile.device_category_ids
                              )
                        ) AS is_compatible
                        """,
                        (
                            profile_code,
                            device_category_id,
                        ),
                    )

                    profile_compatibility = await cursor.fetchone()

                    if not profile_compatibility["is_compatible"]:
                        raise OnboardingValidationError(
                            f"Device profile '{profile_code}' is not "
                            f"compatible with device category "
                            f"'{category_name}'.",
                            field_name="profile_code",
                        )

                elif device_mode == "USE_EXISTING":
                    existing_device_id = device.get(
                        "existing_device_id"
                    )

                    await cursor.execute(
                        """
                        SELECT
                            id,
                            device_category_id,
                            device_category_name,
                            profile_id,
                            profile_code
                        FROM admin.v_devices
                        WHERE id = %s::uuid
                        """,
                        (existing_device_id,),
                    )

                    existing_device = await cursor.fetchone()

                    if existing_device is None:
                        raise OnboardingValidationError(
                            "Existing device selection was not found.",
                            field_name="existing_device_id",
                        )

                    category_name = existing_device[
                        "device_category_name"
                    ]

                    if not category_name:
                        raise OnboardingValidationError(
                            "The selected existing device does not have a "
                            "controlled device category.",
                            field_name="existing_device_id",
                        )

                    if (
                        existing_device["profile_id"] is None
                        or not existing_device["profile_code"]
                    ):
                        raise OnboardingValidationError(
                            "The selected existing device does not have an "
                            "onboarding profile.",
                            field_name="existing_device_id",
                        )

                else:
                    raise OnboardingValidationError(
                        "Device mode must be CREATE_NEW or USE_EXISTING.",
                        field_name="device_mode",
                    )

                if category_name not in CATEGORY_RELATIONSHIPS:
                    raise OnboardingValidationError(
                        f"Device category '{category_name}' has no "
                        "configured asset-relationship rules."
                    )

                allowed_relationships = CATEGORY_RELATIONSHIPS[
                    category_name
                ]

                if not allowed_relationships:
                    raise OnboardingValidationError(
                        f"Device category '{category_name}' cannot be "
                        "attached directly to an operational asset."
                    )

                if relationship_type not in allowed_relationships:
                    allowed_labels = ", ".join(
                        sorted(allowed_relationships)
                    )

                    raise OnboardingValidationError(
                        f"Relationship '{relationship_type}' is not valid "
                        f"for device category '{category_name}'. Allowed "
                        f"values: {allowed_labels}.",
                        field_name="relationship_type",
                    )

                await cursor.execute(
                    """
                    SELECT admin.onboard_energy_asset(
                        %s::jsonb,
                        %s
                    ) AS onboarding_result
                    """,
                    (
                        request_payload,
                        requested_by,
                    ),
                )

                row = await cursor.fetchone()

            await connection.commit()

        except (DatabaseError, OnboardingValidationError):
            await connection.rollback()
            raise

    return build_onboarding_result(row["onboarding_result"])
