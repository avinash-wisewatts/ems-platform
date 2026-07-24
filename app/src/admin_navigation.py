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

_PLATFORM_ITEMS = (
    NavigationItem("organizations","Organizations","◉","/administration/organizations","Manage EMS tenants.",
),
    _USER_MANAGEMENT,
)

_TENANT_ITEMS = (
    NavigationItem("sites", "Sites", "⌖", None, "Manage organization sites."),
    NavigationItem("locations", "Locations", "⌗", None, "Manage buildings, floors, and spaces."),
    NavigationItem("assets", "Assets", "◆", None, "Manage independent asset inventory."),
    NavigationItem("gateways", "Gateways", "◇", None, "Register and manage gateways."),
    NavigationItem("devices", "Devices", "▣", None, "Register and manage devices."),
    NavigationItem("relationships", "Relationships", "⇄", None, "Manage asset-device assignments."),
)

_OPERATIONS_ITEMS = (
    NavigationItem("commissioning", "Commissioning", "✓", None, "Review readiness and commission entities."),
    NavigationItem("audit", "Audit", "◷", None, "Review administration audit history."),
)


def administration_navigation(role_code: str | None) -> tuple[NavigationSection, ...]:
    """Return role-aware administration navigation without granting access."""

    sections: list[NavigationSection] = [
        NavigationSection("Workspace", (_OVERVIEW, _ONBOARDING)),
    ]

    if role_code == "PLATFORM_ADMIN":
        sections.append(NavigationSection("Platform", _PLATFORM_ITEMS))
    elif role_code == "ORG_ADMIN":
        sections.append(
            NavigationSection(
                "Organization administration",
                (_USER_MANAGEMENT,),
            )
        )

    sections.extend(
        (
            NavigationSection("Tenant administration", _TENANT_ITEMS),
            NavigationSection("Operations", _OPERATIONS_ITEMS),
        )
    )
    return tuple(sections)
