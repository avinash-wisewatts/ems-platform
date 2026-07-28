from src.context.models import AdministrationContext
from src.context.session import (
    deserialize_administration_context,
    serialize_administration_context,
)


ORG_ID = "11111111-1111-4111-8111-111111111111"
SITE_ID = "22222222-2222-4222-8222-222222222222"
LOCATION_ID = "33333333-3333-4333-8333-333333333333"
ENTITY_ID = "44444444-4444-4444-8444-444444444444"


def test_context_round_trip() -> None:
    context = AdministrationContext(
        active_organization_id=ORG_ID,
        active_organization_name="Organization One",
        active_organization_code="ORG_1",
        active_site_id=SITE_ID,
        active_site_name="Site One",
        active_site_code="SITE_1",
        active_location_id=LOCATION_ID,
        active_entity_type="ASSET",
        active_entity_id=ENTITY_ID,
    )

    assert deserialize_administration_context(
        serialize_administration_context(context)
    ) == context


def test_context_payload_fails_closed_when_malformed() -> None:
    assert deserialize_administration_context(None) is None
    assert deserialize_administration_context([]) is None
    assert deserialize_administration_context({}) is None
    assert (
        deserialize_administration_context(
            {
                "context_version": 1,
                "active_organization_id": "not-a-uuid",
            }
        )
        is None
    )


def test_context_rejects_unknown_entity_type() -> None:
    assert (
        deserialize_administration_context(
            {
                "context_version": 1,
                "active_organization_id": ORG_ID,
                "active_entity_type": "SECRET",
                "active_entity_id": ENTITY_ID,
            }
        )
        is None
    )


def test_context_rejects_child_without_parent() -> None:
    assert (
        deserialize_administration_context(
            {
                "context_version": 1,
                "active_site_id": SITE_ID,
            }
        )
        is None
    )
    assert (
        deserialize_administration_context(
            {
                "context_version": 1,
                "active_location_id": LOCATION_ID,
            }
        )
        is None
    )


def test_context_rejects_incompatible_version() -> None:
    assert (
        deserialize_administration_context(
            {
                "context_version": 2,
                "active_organization_id": ORG_ID,
            }
        )
        is None
    )
