import re
from dataclasses import dataclass
from typing import Any
from uuid import UUID


CODE_PATTERN = re.compile(r"^[A-Z0-9_]+$")
LOCATION_CODE_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]*$")
MQTT_UID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){7}$"
)

ALLOWED_PROTOCOLS = {
    "MQTT",
    "MODBUS TCP",
    "MODBUS RTU",
    "BACNET",
    "OPC-UA",
    "HTTP API",
}

ALLOWED_IDENTIFIER_TYPES = {
    "MQTT_UID",
}

ALLOWED_RELATIONSHIPS = {
    "PRIMARY_METER",
    "SECONDARY_METER",
    "SECONDARY_METER",
    "TEMPERATURE_SENSOR",
    "HUMIDITY_SENSOR",
    "FLOW_SENSOR",
    "PRESSURE_SENSOR",
    "STATUS_INPUT",
    "RUN_STATUS",
    "FAULT_STATUS",
    "CONTROLLER",
}


class OnboardingValidationError(ValueError):
    """
    Structured application-level validation error.

    Existing validation call sites may continue passing only a message.
    The affected HTML field is inferred from stable message prefixes.
    """

    FIELD_PREFIXES: tuple[tuple[str, str], ...] = (
        ("Organization mode", "organization_mode"),
        ("Existing organization", "existing_organization_id"),
        ("Organization name", "organization_name"),
        ("Organization code", "organization_code"),
        ("Organization description", "organization_description"),
        ("Site mode", "site_mode"),
        ("Existing site", "existing_site_id"),
        ("Site name", "site_name"),
        ("Site code", "site_code"),
        ("Site timezone", "site_timezone"),
        ("Site address", "site_address"),
        ("Location mode", "location_mode"),
        ("Existing space", "existing_space_id"),
        ("Building name", "building_name"),
        ("Building code", "building_code"),
        ("Floor name", "floor_name"),
        ("Floor code", "floor_code"),
        ("Space name", "space_name"),
        ("Space code", "space_code"),
        ("Gateway mode", "gateway_mode"),
        ("Existing gateway", "existing_gateway_id"),
        ("Gateway name", "gateway_name"),
        ("Gateway external ID", "gateway_external_id"),
        ("Gateway vendor", "gateway_vendor"),
        ("Gateway model", "gateway_model"),
        ("Gateway protocol", "gateway_protocol"),
        ("Device mode", "device_mode"),
        ("Existing device", "existing_device_id"),
        ("Device name", "device_name"),
        ("Device external ID", "device_external_id"),
        ("Device model vendor", "device_model_vendor"),
        ("Device model", "device_model"),
        ("Device category", "device_category_id"),
        ("Firmware version", "firmware_version"),
        ("Device protocol", "device_protocol"),
        ("Device profile", "profile_code"),
        ("Identifier type", "identifier_type"),
        ("Identifier value", "identifier_value"),
        ("MQTT UID", "identifier_value"),
        ("Asset mode", "asset_mode"),
        ("Existing asset", "existing_asset_id"),
        ("Asset name", "asset_name"),
        ("Asset type", "asset_type_id"),
        ("Device relationship", "relationship_type"),
        ("Relationship", "relationship_type"),
    )

    def __init__(
        self,
        message: str,
        field_name: str | None = None,
    ) -> None:
        self.message = message
        self.field_name = field_name or self._infer_field_name(message)
        super().__init__(message)

    @classmethod
    def _infer_field_name(cls, message: str) -> str | None:
        normalized = message.strip().lower()

        for prefix, field_name in cls.FIELD_PREFIXES:
            if normalized.startswith(prefix.lower()):
                return field_name

        if "device category" in normalized:
            return "device_category_id"

        if "relationship" in normalized:
            return "relationship_type"

        if "existing space" in normalized:
            return "existing_space_id"

        if "existing asset" in normalized:
            return "existing_asset_id"

        return None


@dataclass(frozen=True)
class OnboardingForm:
    organization_mode: str
    existing_organization_id: str
    organization_name: str
    organization_code: str
    organization_description: str

    site_mode: str
    existing_site_id: str
    site_name: str
    site_code: str
    site_timezone: str
    site_address: str

    location_mode: str
    existing_space_id: str
    building_name: str
    building_code: str
    floor_name: str
    floor_code: str
    space_name: str
    space_code: str

    gateway_mode: str
    existing_gateway_id: str
    gateway_name: str
    gateway_external_id: str
    gateway_vendor: str
    gateway_model: str
    gateway_protocol: str

    device_mode: str
    existing_device_id: str
    device_name: str
    device_external_id: str
    device_model_vendor: str
    device_model: str
    device_category_id: str
    firmware_version: str
    device_protocol: str
    profile_code: str

    identifier_type: str
    identifier_value: str

    asset_mode: str
    existing_asset_id: str
    asset_name: str
    asset_type_id: str
    relationship_type: str

    @staticmethod
    def _required(value: str, field_name: str) -> str:
        normalized = value.strip()

        if not normalized:
            raise OnboardingValidationError(
                f"{field_name} is required."
            )

        return normalized

    @staticmethod
    def _code(
        value: str,
        field_name: str,
        *,
        location_code: bool = False,
    ) -> str:
        normalized = OnboardingForm._required(
            value,
            field_name,
        ).upper()

        pattern = (
            LOCATION_CODE_PATTERN
            if location_code
            else CODE_PATTERN
        )

        if not pattern.fullmatch(normalized):
            if location_code:
                raise OnboardingValidationError(
                    f"{field_name} must start with A-Z and contain only "
                    "A-Z, 0-9, and underscore."
                )

            raise OnboardingValidationError(
                f"{field_name} may contain only A-Z, 0-9, and underscore."
            )

        if len(normalized) > 100:
            raise OnboardingValidationError(
                f"{field_name} must not exceed 100 characters."
            )

        return normalized

    @staticmethod
    def _maximum_length(
        value: str,
        field_name: str,
        maximum: int,
    ) -> str:
        normalized = value.strip()

        if len(normalized) > maximum:
            raise OnboardingValidationError(
                f"{field_name} must not exceed {maximum} characters."
            )

        return normalized

    @staticmethod
    def _required_bounded(
        value: str,
        field_name: str,
        maximum: int,
    ) -> str:
        normalized = OnboardingForm._required(
            value,
            field_name,
        )

        if len(normalized) > maximum:
            raise OnboardingValidationError(
                f"{field_name} must not exceed {maximum} characters."
            )

        return normalized

    def to_request_payload(self) -> dict[str, Any]:
        organization_mode = self._required(
            self.organization_mode,
            "Organization mode",
        ).upper()

        if organization_mode not in {"CREATE_NEW", "USE_EXISTING"}:
            raise OnboardingValidationError(
                "Organization mode must be CREATE_NEW or USE_EXISTING."
            )

        organization_name: str | None = None
        organization_code: str | None = None
        existing_organization_id: str | None = None

        if organization_mode == "CREATE_NEW":
            organization_name = self._required(
                self.organization_name,
                "Organization name",
            )
            organization_code = self._code(
                self.organization_code,
                "Organization code",
            )
        else:
            try:
                existing_organization_id = str(
                    UUID(self.existing_organization_id)
                )
            except ValueError as exc:
                raise OnboardingValidationError(
                    "Existing organization selection is invalid.",
                    field_name="existing_organization_id",
                ) from exc

        site_mode = self._required(
            self.site_mode,
            "Site mode",
        ).upper()

        if site_mode not in {"CREATE_NEW", "USE_EXISTING"}:
            raise OnboardingValidationError(
                "Site mode must be CREATE_NEW or USE_EXISTING."
            )

        site_name: str | None = None
        site_code: str | None = None
        existing_site_id: str | None = None

        if site_mode == "CREATE_NEW":
            site_name = self._required(
                self.site_name,
                "Site name",
            )
            site_code = self._code(
                self.site_code,
                "Site code",
            )
            site_timezone = self._required(
                self.site_timezone,
                "Site timezone",
            )
        else:
            try:
                existing_site_id = str(UUID(self.existing_site_id))
            except ValueError as exc:
                raise OnboardingValidationError(
                    "Existing site selection is invalid.",
                    field_name="existing_site_id",
                ) from exc

            site_timezone = (
                self.site_timezone.strip() or "Asia/Kolkata"
            )

        gateway_mode = self._required(
            self.gateway_mode,
            "Gateway mode",
        ).upper()

        if gateway_mode not in {"CREATE_NEW", "USE_EXISTING"}:
            raise OnboardingValidationError(
                "Gateway mode must be CREATE_NEW or USE_EXISTING."
            )

        gateway_name: str | None = None
        gateway_external_id: str | None = None
        gateway_vendor: str | None = None
        gateway_model: str | None = None
        gateway_protocol: str | None = None
        existing_gateway_id: str | None = None

        if gateway_mode == "CREATE_NEW":
            gateway_name = self._required(
                self.gateway_name,
                "Gateway name",
            )
            gateway_external_id = self._code(
                self.gateway_external_id,
                "Gateway external ID",
            )
            gateway_vendor = self._required(
                self.gateway_vendor,
                "Gateway vendor",
            )
            gateway_model = self._required(
                self.gateway_model,
                "Gateway model",
            )
            gateway_protocol = self._required(
                self.gateway_protocol,
                "Gateway protocol",
            ).upper()
        else:
            try:
                existing_gateway_id = str(UUID(self.existing_gateway_id))
            except ValueError as exc:
                raise OnboardingValidationError(
                    "Existing gateway selection is invalid.",
                    field_name="existing_gateway_id",
                ) from exc

        device_mode = self._required(
            self.device_mode,
            "Device mode",
        ).upper()

        if device_mode not in {"CREATE_NEW", "USE_EXISTING"}:
            raise OnboardingValidationError(
                "Device mode must be CREATE_NEW or USE_EXISTING."
            )

        device_name: str | None = None
        device_external_id: str | None = None
        device_model_vendor: str | None = None
        device_model: str | None = None
        device_category_id: str | None = None
        device_protocol: str | None = None
        profile_code: str | None = None
        existing_device_id: str | None = None

        if device_mode == "CREATE_NEW":
            device_name = self._required(
                self.device_name,
                "Device name",
            )
            device_external_id = self._code(
                self.device_external_id,
                "Device external ID",
            )
            device_model_vendor = self._required(
                self.device_model_vendor,
                "Device model vendor",
            )
            device_model = self._required(
                self.device_model,
                "Device model",
            )

            try:
                device_category_id = str(UUID(self.device_category_id))
            except ValueError as exc:
                raise OnboardingValidationError(
                    "Device category is invalid."
                ) from exc

            device_protocol = self._required(
                self.device_protocol,
                "Device protocol",
            ).upper()
            profile_code = self._code(
                self.profile_code,
                "Device profile",
            )
        else:
            try:
                existing_device_id = str(UUID(self.existing_device_id))
            except ValueError as exc:
                raise OnboardingValidationError(
                    "Existing device selection is invalid.",
                    field_name="existing_device_id",
                ) from exc

        identifier_type: str | None = None
        identifier_value: str | None = None

        if device_mode == "CREATE_NEW":
            identifier_type = self._required(
                self.identifier_type,
                "Identifier type",
            ).upper()
            identifier_value = self._required(
                self.identifier_value,
                "Identifier value",
            )

            if identifier_type == "MQTT_UID":
                identifier_value = identifier_value.lower()
        else:
            supplied_type = self.identifier_type.strip()
            supplied_value = self.identifier_value.strip()

            if bool(supplied_type) != bool(supplied_value):
                raise OnboardingValidationError(
                    "Identifier type and value must be supplied together."
                )

            if supplied_type and supplied_value:
                identifier_type = supplied_type.upper()
                identifier_value = supplied_value

                if identifier_type == "MQTT_UID":
                    identifier_value = identifier_value.lower()

        asset_mode = self._required(
            self.asset_mode,
            "Asset mode",
        ).upper()

        if asset_mode not in {"CREATE_NEW", "USE_EXISTING"}:
            raise OnboardingValidationError(
                "Asset mode must be CREATE_NEW or USE_EXISTING."
            )

        relationship_type = self._required(
            self.relationship_type,
            "Relationship type",
        ).upper()

        asset_name: str | None = None
        asset_type_id: str | None = None
        existing_asset_id: str | None = None

        if asset_mode == "CREATE_NEW":
            asset_name = self._required(
                self.asset_name,
                "Asset name",
            )

            try:
                asset_type_id = str(UUID(self.asset_type_id))
            except ValueError as exc:
                raise OnboardingValidationError(
                    "Asset type is invalid."
                ) from exc
        else:
            try:
                existing_asset_id = str(UUID(self.existing_asset_id))
            except ValueError as exc:
                raise OnboardingValidationError(
                    "Existing asset selection is invalid."
                ) from exc

        address: dict[str, str] = {}

        if self.site_address.strip():
            address["full_address"] = self.site_address.strip()

        location_mode = self._required(
            self.location_mode,
            "Location mode",
        ).upper()

        if location_mode not in {
            "SITE_ONLY",
            "CREATE_LOCATION",
            "USE_EXISTING_SPACE",
        }:
            raise OnboardingValidationError(
                "Location mode is invalid."
            )

        existing_space_id: str | None = None
        building_name: str | None = None
        building_code: str | None = None
        floor_name: str | None = None
        floor_code: str | None = None
        space_name: str | None = None
        space_code: str | None = None

        if location_mode == "CREATE_LOCATION":
            building_name = self._required(
                self.building_name,
                "Building name",
            )
            building_code = self._code(
                self.building_code,
                "Building code",
                location_code=True,
            )
            floor_name = self._required(
                self.floor_name,
                "Floor name",
            )
            floor_code = self._code(
                self.floor_code,
                "Floor code",
                location_code=True,
            )
            space_name = self._required(
                self.space_name,
                "Space name",
            )
            space_code = self._code(
                self.space_code,
                "Space code",
                location_code=True,
            )

        elif location_mode == "USE_EXISTING_SPACE":
            try:
                existing_space_id = str(UUID(self.existing_space_id))
            except ValueError as exc:
                raise OnboardingValidationError(
                    "Existing space selection is invalid."
                ) from exc

        # ------------------------------------------------------------------
        # Controlled values and format validation.
        # ------------------------------------------------------------------

        if (
            gateway_mode == "CREATE_NEW"
            and gateway_protocol not in ALLOWED_PROTOCOLS
        ):
            raise OnboardingValidationError(
                "Gateway protocol is not supported."
            )

        if (
            device_mode == "CREATE_NEW"
            and device_protocol not in ALLOWED_PROTOCOLS
        ):
            raise OnboardingValidationError(
                "Device protocol is not supported."
            )

        if identifier_type is not None:
            if identifier_type not in ALLOWED_IDENTIFIER_TYPES:
                raise OnboardingValidationError(
                    "Identifier type is not supported."
                )

            if identifier_type == "MQTT_UID":
                if (
                    identifier_value is None
                    or not MQTT_UID_PATTERN.fullmatch(identifier_value)
                ):
                    raise OnboardingValidationError(
                        "MQTT UID must contain exactly eight hexadecimal byte "
                        "pairs separated by colons. Example: "
                        "80:34:28:16:09:eb:00:01"
                    )

                identifier_value = identifier_value.lower()

        if relationship_type not in ALLOWED_RELATIONSHIPS:
            raise OnboardingValidationError(
                "Device relationship is not supported."
            )

        # ------------------------------------------------------------------
        # Length limits.
        # ------------------------------------------------------------------

        bounded_fields = (
            (organization_name, "Organization name", 200),
            (site_name, "Site name", 200),
            (site_timezone, "Site timezone", 100),
            (gateway_name, "Gateway name", 200),
            (gateway_vendor, "Gateway vendor", 200),
            (gateway_model, "Gateway model", 200),
            (device_name, "Device name", 200),
            (device_model_vendor, "Device model vendor", 200),
            (device_model, "Device model", 200),
            (identifier_value, "Identifier value", 255),
        )

        for value, field_name, maximum in bounded_fields:
            if value is not None and len(value) > maximum:
                raise OnboardingValidationError(
                    f"{field_name} must not exceed {maximum} characters."
                )

        optional_bounded_fields = (
            (
                self.organization_description,
                "Organization description",
                2000,
            ),
            (
                self.site_address,
                "Site address",
                2000,
            ),
            (
                self.firmware_version,
                "Firmware version",
                100,
            ),
        )

        for value, field_name, maximum in optional_bounded_fields:
            self._maximum_length(
                value,
                field_name,
                maximum,
            )

        if asset_name is not None and len(asset_name) > 200:
            raise OnboardingValidationError(
                "Asset name must not exceed 200 characters."
            )

        for value, field_name in (
            (building_name, "Building name"),
            (floor_name, "Floor name"),
            (space_name, "Space name"),
        ):
            if value is not None and len(value) > 200:
                raise OnboardingValidationError(
                    f"{field_name} must not exceed 200 characters."
                )

        return {
            "organization": {
                "mode": organization_mode,
                "existing_organization_id": existing_organization_id,
                "name": organization_name,
                "code": organization_code,
                "description": (
                    self.organization_description.strip() or None
                    if organization_mode == "CREATE_NEW"
                    else None
                ),
            },
            "site": {
                "mode": site_mode,
                "existing_site_id": existing_site_id,
                "name": site_name,
                "code": site_code,
                "timezone": (
                    site_timezone
                    if site_mode == "CREATE_NEW"
                    else None
                ),
                "address": (
                    address
                    if site_mode == "CREATE_NEW"
                    else None
                ),
            },
            "location": {
                "mode": location_mode,
                "existing_space_id": existing_space_id,
                "building_name": building_name,
                "building_code": building_code,
                "floor_name": floor_name,
                "floor_code": floor_code,
                "space_name": space_name,
                "space_code": space_code,
            },
            "gateway": {
                "mode": gateway_mode,
                "existing_gateway_id": existing_gateway_id,
                "name": gateway_name,
                "external_id": gateway_external_id,
                "vendor": gateway_vendor,
                "model": gateway_model,
                "protocol": gateway_protocol,
            },
            "device": {
                "mode": device_mode,
                "existing_device_id": existing_device_id,
                "name": device_name,
                "external_id": device_external_id,
                "model_vendor": device_model_vendor,
                "model": device_model,
                "device_category_id": device_category_id,
                "firmware_version": (
                    self.firmware_version.strip() or None
                    if device_mode == "CREATE_NEW"
                    else None
                ),
                "protocol": device_protocol,
                "profile_code": profile_code,
            },
            "identifier": {
                "type": identifier_type,
                "value": identifier_value,
            },
            "asset": {
                "mode": asset_mode,
                "existing_asset_id": existing_asset_id,
                "name": asset_name,
                "asset_type_id": asset_type_id,
                "relationship_type": relationship_type,
                "metadata": {
                    "source": "ems_administration_portal",
                },
            },
        }
