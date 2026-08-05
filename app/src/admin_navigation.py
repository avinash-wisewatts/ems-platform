from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class NavigationItem:
    key: str
    label: str
    icon: str
    href: str | None
    description: str


@dataclass(frozen=True, slots=True)
class NavigationSection:
    label: str
    items: tuple[NavigationItem, ...]


_OVERVIEW = NavigationItem(
    key="overview",
    label="Overview",
    icon="⌂",
    href="/administration",
    description="Administration workspace and delivery status.",
)

_ONBOARDING = NavigationItem(
    key="onboarding",
    label="Onboarding",
    icon="＋",
    href="/onboarding",
    description="Continue using the guided onboarding wizard.",
)

_USER_MANAGEMENT = NavigationItem(
    "users",
    "Users",
    "♙",
    "/administration/users",
    "Manage platform and tenant users.",
)

_ORGANIZATIONS = NavigationItem(
    "organizations",
    "Organizations",
    "◉",
    "/administration/organizations",
    "Manage EMS tenants.",
)

_TENANT_ITEMS = (
    NavigationItem(
        "sites",
        "Sites",
        "⌖",
        "/administration/sites",
        "Manage organization sites.",
    ),
    NavigationItem(
        "locations",
        "Locations",
        "⌗",
        "/administration/locations",
        "Manage buildings, floors, and spaces.",
    ),
    NavigationItem(
        "assets",
        "Assets",
        "◆",
        "/administration/assets",
        "Manage independent asset inventory.",
    ),
    NavigationItem(
        "gateways",
        "Gateways",
        "◇",
        "/administration/gateways",
        "Register and manage gateways.",
    ),
    NavigationItem(
        "devices",
        "Devices",
        "▣",
        "/administration/devices",
        "Register and manage devices.",
    ),
    NavigationItem(
        "metering-coverage",
        "Metering coverage",
        "◫",
        "/administration/metering-coverage",
        "Review asset metering policy and configuration coverage.",
    ),
)

_OPERATIONS_ITEMS = (
    NavigationItem(
        "commissioning",
        "Commissioning",
        "✓",
        "/administration/commissioning",
        "Review readiness and commission entities.",
    ),
    NavigationItem(
        "telemetry-validation",
        "Telemetry validation",
        "≈",
        "/administration/telemetry-validation",
        "Review device configuration and data health.",
    ),
    NavigationItem(
        "reconciliation",
        "Reconciliation",
        "!",
        "/administration/reconciliation",
        "Resolve operational configuration and provisioning issues.",
    ),
    NavigationItem(
        "audit",
        "Audit",
        "◷",
        None,
        "Review administration audit history.",
    ),
)


def administration_navigation(
    role_code: str | None,
    access_scope_mode: str | None = None,
) -> tuple[NavigationSection, ...]:
    """Return role-and-scope-aware navigation without granting access."""

    sections: list[NavigationSection] = [
        NavigationSection("Workspace", (_OVERVIEW, _ONBOARDING)),
    ]

    if role_code == "ADMIN":
        administration_items = (
            (_ORGANIZATIONS, _USER_MANAGEMENT)
            if access_scope_mode == "GLOBAL"
            else (_USER_MANAGEMENT,)
        )

        sections.append(
            NavigationSection(
                (
                    "Platform administration"
                    if access_scope_mode == "GLOBAL"
                    else "Organization administration"
                ),
                administration_items,
            )
        )

    sections.extend(
        (
            NavigationSection(
                "Tenant administration",
                _TENANT_ITEMS,
            ),
            NavigationSection(
                "Operations",
                _OPERATIONS_ITEMS,
            ),
        )
    )

    return tuple(sections)
