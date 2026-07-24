import pytest

from src.main import safe_login_redirect_path


@pytest.mark.parametrize(
    ("submitted", "expected"),
    [
        (None, "/onboarding/organization"),
        ("", "/onboarding/organization"),
        ("onboarding/device", "/onboarding/organization"),
        ("https://evil.example", "/onboarding/organization"),
        ("//evil.example/path", "/onboarding/organization"),
        ("\\\\evil.example\\path", "/onboarding/organization"),
        ("/onboarding/device", "/onboarding/device"),
        (
            "/onboarding/device?draft_token=abc",
            "/onboarding/device?draft_token=abc",
        ),
        ("/", "/"),
    ],
)
def test_safe_login_redirect_path(
    submitted: str | None,
    expected: str,
) -> None:
    assert safe_login_redirect_path(submitted) == expected


@pytest.mark.parametrize(
    "submitted",
    [
        "/onboarding\r\nLocation: https://evil.example",
        "/onboarding\\r\\nLocation:https://evil.example",
    ],
)
def test_login_redirect_rejects_header_injection(
    submitted: str,
) -> None:
    assert (
        safe_login_redirect_path(submitted)
        == "/onboarding/organization"
    )
