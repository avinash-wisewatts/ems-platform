import pytest

from src.auth.service import normalize_username


@pytest.mark.parametrize(
    ("submitted", "expected"),
    [
        (
            "Operator@Example.COM",
            "operator@example.com",
        ),
        (
            "  Operator@Example.COM  ",
            "operator@example.com",
        ),
        (
            "\tUSER\n",
            "user",
        ),
        (
            "",
            "",
        ),
        (
            "   ",
            "",
        ),
    ],
)
def test_normalize_username(
    submitted: str,
    expected: str,
) -> None:
    assert normalize_username(submitted) == expected
