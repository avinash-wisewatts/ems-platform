from dataclasses import dataclass

from src.onboarding.database_errors import user_facing_database_error


@dataclass
class FakeDiag:
    message_primary: str | None


class FakeDatabaseError(Exception):
    def __init__(self, message_primary: str | None):
        super().__init__(message_primary)
        self.diag = FakeDiag(message_primary)


def translate(message: str | None) -> str:
    return user_facing_database_error(
        FakeDatabaseError(message),
        fallback="The database rejected the request.",
    )


def test_asset_site_ownership_error_is_actionable_and_redacted():
    message = translate(
        "Asset organization a100 does not match site a200 organization a300."
    )

    assert message == (
        "The selected asset and site belong to different organizations."
    )
    assert "a100" not in message


def test_location_error_is_actionable():
    assert translate(
        "Gateway location 123 does not belong to organization 456 and site 789."
    ) == (
        "The selected gateway location does not belong to the gateway's "
        "organization and site."
    )


def test_parent_asset_error_is_actionable():
    assert translate(
        "Parent asset 123 does not belong to organization 456 and site 789."
    ) == (
        "The selected parent asset must belong to the same organization and site."
    )


def test_asset_device_error_is_actionable():
    assert translate(
        "Asset 123 and device 456 must belong to the same organization and site, "
        "and the device must have a gateway."
    ) == (
        "The selected asset and device must belong to the same organization and site."
    )


def test_unknown_database_message_uses_safe_fallback():
    assert translate("syntax error at or near secret_table") == (
        "The database rejected the request."
    )


def test_missing_diagnostics_uses_safe_fallback():
    class ErrorWithoutDiagnostics(Exception):
        pass

    assert user_facing_database_error(
        ErrorWithoutDiagnostics("internal detail"),
        fallback="Safe fallback.",
    ) == "Safe fallback."
