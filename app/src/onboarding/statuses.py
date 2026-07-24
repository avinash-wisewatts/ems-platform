"""Canonical administration status definitions used by the portal.

Database CHECK constraints remain authoritative for persisted values. This
module gives application validation and Jinja templates one shared, immutable
source for the same closed codes and user-facing text.
"""

from dataclasses import dataclass
from types import MappingProxyType
from typing import Final


@dataclass(frozen=True, slots=True)
class StatusDefinition:
    """A canonical code with its user-facing label and description."""

    code: str
    label: str
    description: str


def _definition(code: str, label: str, description: str) -> StatusDefinition:
    return StatusDefinition(code=code, label=label, description=description)


_STATUS_DEFINITIONS = {
    "ORGANIZATION_LIFECYCLE": (
        _definition("DRAFT", "Draft", "Organization record exists but is not ready for normal customer operation."),
        _definition("ACTIVE", "Active", "Organization is an operational EMS tenant."),
        _definition("SUSPENDED", "Suspended", "Organization is temporarily disabled while history is retained."),
        _definition("DECOMMISSIONED", "Decommissioned", "Organization has been permanently retired from active operation."),
    ),
    "SITE_LIFECYCLE": (
        _definition("DRAFT", "Draft", "Site record exists but onboarding is incomplete."),
        _definition("ACTIVE", "Active", "Site is operational and may participate in onboarding and reporting."),
        _definition("INACTIVE", "Inactive", "Site is temporarily not operational while history is retained."),
        _definition("DECOMMISSIONED", "Decommissioned", "Site has been retired from active operation."),
    ),
    "ASSET_LIFECYCLE": (
        _definition("DRAFT", "Draft", "Asset master record exists but commissioning has not started."),
        _definition("COMMISSIONING", "Commissioning", "Asset is being prepared and validated for operational use."),
        _definition("ACTIVE", "Active", "Asset has passed required commissioning rules."),
        _definition("INACTIVE", "Inactive", "Asset is temporarily not operating while history is retained."),
        _definition("DECOMMISSIONED", "Decommissioned", "Asset has been retired from active operation."),
    ),
    "GATEWAY_LIFECYCLE": (
        _definition("REGISTERED", "Registered", "Gateway identity exists and configuration may begin."),
        _definition("COMMISSIONING", "Commissioning", "Gateway installation or connectivity validation is in progress."),
        _definition("INACTIVE", "Inactive", "Gateway is intentionally disabled or temporarily out of use."),
        _definition("DECOMMISSIONED", "Decommissioned", "Gateway has been retired while history is retained."),
    ),
    "DEVICE_LIFECYCLE": (
        _definition("DISCOVERED", "Discovered", "Device was detected but has not been formally registered."),
        _definition("REGISTERED", "Registered", "Device identity and core metadata have been saved."),
        _definition("UNASSIGNED", "Unassigned", "Device is tenant-owned and valid but has no functional assignment."),
        _definition("COMMISSIONING", "Commissioning", "Device profile, channels, relationships, or telemetry are being validated."),
        _definition("ACTIVE", "Active", "Device is approved for operational use."),
        _definition("INACTIVE", "Inactive", "Device is intentionally disabled or temporarily removed from service."),
        _definition("DECOMMISSIONED", "Decommissioned", "Device has been permanently retired while history is retained."),
    ),
    "COMMISSIONING_STATUS": (
        _definition("NOT_STARTED", "Not started", "No commissioning attempt has been made."),
        _definition("IN_PROGRESS", "In progress", "Commissioning work is underway."),
        _definition("BLOCKED", "Blocked", "Mandatory requirements are missing or invalid."),
        _definition("READY", "Ready", "All mandatory checks passed and activation is permitted."),
        _definition("COMMISSIONED", "Commissioned", "Commissioning completed successfully."),
        _definition("FAILED", "Failed", "A commissioning attempt failed and the reason is retained."),
    ),
    "GRAFANA_PROVISIONING_STATUS": (
        _definition("NOT_STARTED", "Not started", "Grafana provisioning has not yet been attempted."),
        _definition("PENDING", "Pending", "Grafana provisioning is running or awaiting completion."),
        _definition("PROVISIONED", "Provisioned", "Grafana tenant resources were created successfully."),
        _definition("FAILED", "Failed", "Grafana provisioning did not complete successfully."),
    ),
    "TELEMETRY_AVAILABILITY": (
        _definition("NEVER_SEEN", "Never seen", "No telemetry has ever been received for the device."),
        _definition("RECEIVING", "Receiving", "Valid telemetry is arriving within the expected interval."),
        _definition("STALE", "Stale", "Telemetry was received previously but is older than the warning threshold."),
        _definition("SILENT", "Silent", "No telemetry has arrived beyond the critical threshold."),
        _definition("INVALID_PROFILE", "Invalid profile", "Telemetry is arriving but cannot be normalized with the assigned profile."),
        _definition("UNMAPPED", "Unmapped", "Telemetry is arriving for a known device without a required functional mapping."),
        _definition("VALIDATED", "Validated", "Telemetry passed profile, timestamp, value, and expected-point checks."),
    ),
    "METERING_REQUIREMENT": (
        _definition("DIRECT_METER_REQUIRED", "Direct meter required", "Asset requires a qualifying primary energy meter for commissioning."),
        _definition("DESCENDANT_COVERAGE_ALLOWED", "Descendant coverage allowed", "Asset coverage may be satisfied by required directly metered descendants."),
        _definition("NOT_REQUIRED", "Metering not required", "Asset is intentionally excluded from energy-meter coverage."),
    ),
    "METER_COVERAGE_STATUS": (
        _definition("CONFIGURED", "Configured", "All required qualifying meter relationships are present."),
        _definition("MISSING_DIRECT_METER", "Missing direct meter", "A required qualifying primary meter relationship is missing."),
        _definition("PARTIALLY_CONFIGURED", "Partially configured", "Some but not all required descendants are correctly metered."),
        _definition("MISSING_DESCENDANT_COVERAGE", "Missing descendant coverage", "Required descendant assets are not adequately metered."),
        _definition("NO_REQUIRED_DESCENDANTS", "No required descendants", "No active descendant currently requires a direct meter."),
        _definition("EXCLUDED", "Excluded", "Asset is excluded from energy-meter coverage evaluation."),
        _definition("OUT_OF_SCOPE_INACTIVE", "Out of scope inactive", "Inactive or decommissioned asset is outside active coverage evaluation."),
    ),
}

STATUS_DEFINITIONS: Final = MappingProxyType(_STATUS_DEFINITIONS)


def status_options(domain: str) -> tuple[StatusDefinition, ...]:
    """Return ordered definitions for a canonical status domain."""

    try:
        return STATUS_DEFINITIONS[domain]
    except KeyError as exc:
        raise ValueError(f"Unknown status domain: {domain}") from exc


def status_codes(domain: str) -> frozenset[str]:
    """Return the accepted canonical codes for validation."""

    return frozenset(option.code for option in status_options(domain))
