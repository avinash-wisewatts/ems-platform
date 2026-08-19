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
        ("Sub-sector", "sub_sector_id"),
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
