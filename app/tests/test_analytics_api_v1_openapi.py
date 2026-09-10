"""Phase 7 -- the /api/v1 contract is the only surface exposed via OpenAPI.

The admin-portal HTML routes are all include_in_schema=False; the Phase 7
JSON API is the first (and, in this slice, only) documented contract. This
schema becomes an input to Phase 8 frontend design.
"""

from __future__ import annotations


def _schema():
    from src.main import app

    return app.openapi()


EXPECTED_PATHS = {
    "/api/v1/sites",
    "/api/v1/sites/{site_id}/energy/consumption",
    "/api/v1/spaces/{space_id}/measurements",
}


def test_openapi_documents_the_three_v1_endpoints() -> None:
    paths = _schema()["paths"]
    assert EXPECTED_PATHS <= set(paths)
    for path in EXPECTED_PATHS:
        assert set(paths[path]) == {"get"}


def test_openapi_does_not_document_the_administration_html_surface() -> None:
    # The Phase 7 slice does not change what the pre-existing portal chooses
    # to expose; it only asserts the server-rendered /administration/* CRUD
    # surface is not part of the documented contract.
    paths = _schema()["paths"]
    assert not any(p.startswith("/administration") for p in paths)


def test_openapi_operations_are_tagged_and_named() -> None:
    paths = _schema()["paths"]
    op_ids = {
        path: paths[path]["get"]["operationId"] for path in EXPECTED_PATHS
    }
    assert op_ids == {
        "/api/v1/sites": "listAccessibleSites",
        "/api/v1/sites/{site_id}/energy/consumption": "getSiteEnergyConsumption",
        "/api/v1/spaces/{space_id}/measurements": "getSpaceMeasurements",
    }
    for path in EXPECTED_PATHS:
        assert paths[path]["get"]["tags"] == ["analytics-api-v1"]


def test_openapi_declares_error_responses() -> None:
    paths = _schema()["paths"]
    for path in EXPECTED_PATHS:
        responses = paths[path]["get"]["responses"]
        assert "200" in responses
        assert "401" in responses
    # the two resource-scoped endpoints additionally document 404 + 422
    for path in (
        "/api/v1/sites/{site_id}/energy/consumption",
        "/api/v1/spaces/{space_id}/measurements",
    ):
        responses = paths[path]["get"]["responses"]
        assert "404" in responses
        assert "422" in responses


def test_openapi_response_models_present() -> None:
    schemas = _schema()["components"]["schemas"]
    for model in (
        "SitesResponse",
        "SiteSummary",
        "MeasurementSeriesResponse",
        "MeasurementPoint",
        "EnergyConsumptionResponse",
        "EnergyConsumptionPoint",
    ):
        assert model in schemas


def test_measurement_series_response_uses_from_to_aliases() -> None:
    schema = _schema()["components"]["schemas"]["MeasurementSeriesResponse"]
    assert "from" in schema["properties"]
    assert "to" in schema["properties"]
    assert "range_from" not in schema["properties"]
