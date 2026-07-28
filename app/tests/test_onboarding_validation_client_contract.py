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
