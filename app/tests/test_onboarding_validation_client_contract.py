from pathlib import Path


def test_onboarding_validation_flushes_pending_checks_before_submit() -> None:
    script = Path("app/src/static/js/onboarding-validation.js").read_text()
    assert "timers.forEach" in script
    assert "await Promise.all(applicableFields.map(validateNow))" in script
    assert "form.requestSubmit" in script
    assert "validatedSubmit" in script


def test_onboarding_validation_cache_version_is_bumped() -> None:
    template = Path("app/src/templates/onboarding/layout.html").read_text()
    assert "onboarding-validation.js?v=validation-framework-2" in template


def test_validation_client_sends_field_id_for_mqtt_uid():
    script = Path(
        "app/src/static/js/onboarding-validation.js"
    ).read_text()

    assert "field: field.id || field.name" in script
    assert '"new_identifier_value"' in script

def test_validation_applies_recommended_identifier_values() -> None:
    project_root = Path(__file__).resolve().parents[2]
    script = (
        project_root
        / "app/src/static/js/onboarding-validation.js"
    ).read_text()

    assert "result.recommended_value" in script
    assert "field.value = recommendedValue" in script
    assert 'result.code === "IDENTIFIER_ADJUSTED"' in script
    assert "wisewatts:identifier-adjusted" in script


def test_validation_runs_while_fields_change() -> None:
    project_root = Path(__file__).resolve().parents[2]
    script = (
        project_root
        / "app/src/static/js/onboarding-validation.js"
    ).read_text()

    assert 'field.addEventListener("input"' in script
    assert 'field.addEventListener("change"' in script
    assert 'field.addEventListener("blur"' in script
    assert "scheduleValidation(field)" in script
    assert "void validateNow(field)" in script


def test_gateway_and_device_external_ids_are_generated() -> None:
    project_root = Path(__file__).resolve().parents[2]

    gateway_template = (
        project_root
        / "app/src/templates/onboarding/gateway.html"
    ).read_text()

    device_template = (
        project_root
        / "app/src/templates/onboarding/device.html"
    ).read_text()

    asset_template = (
        project_root
        / "app/src/templates/onboarding/asset.html"
    ).read_text()

    assert (
        'data-generated-code-from="gateway_name"'
        in gateway_template
    )
    assert (
        'data-generated-code-from="device_name"'
        in device_template
    )
    assert (
        'data-generated-code-from="asset_name"'
        in asset_template
    )
