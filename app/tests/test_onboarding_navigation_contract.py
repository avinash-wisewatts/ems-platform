from pathlib import Path


def test_onboarding_layout_has_navigable_completed_steps():
    template = Path("app/src/templates/onboarding/layout.html").read_text()
    assert 'step_path }}?draft={{ draft_token }}' in template
    assert 'is-complete is-navigable' in template
    assert 'aria-current="step"' in template


def test_generated_code_controller_is_loaded_globally():
    base = Path("app/src/templates/base.html").read_text()
    assert "system-generated-code.js" in base
