"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const form = document.getElementById("organization_form");

    if (!form) {
        return;
    }

    const modeInputs = Array.from(
        form.querySelectorAll(
            'input[name="organization_mode"]'
        )
    );

    const existingSection = document.getElementById(
        "existing_organization_fields"
    );

    const createSection = document.getElementById(
        "create_organization_fields"
    );

    const existingSelect = document.getElementById(
        "existing_organization_id"
    );

    const organizationName = document.getElementById(
        "organization_name"
    );

    const organizationCode = document.getElementById(
        "organization_code"
    );

    const codeWasManuallyEdited = false;

    const generateCode = (value) => window.WiseWattsCode.generate(value);

    const setSectionEnabled = (
        section,
        enabled,
    ) => {
        section.hidden = !enabled;

        section
            .querySelectorAll("input, select, textarea")
            .forEach((field) => {
                field.disabled = !enabled;
            });
    };

    const updateMode = () => {
        const selectedMode = modeInputs.find(
            (input) => input.checked
        )?.value || "CREATE_NEW";

        const useExisting =
            selectedMode === "USE_EXISTING";

        setSectionEnabled(
            existingSection,
            useExisting,
        );

        setSectionEnabled(
            createSection,
            !useExisting,
        );

        existingSelect.required = useExisting;
        organizationName.required = !useExisting;
        organizationCode.required = !useExisting;
    };

    organizationName.addEventListener("input", () => {
        if (!codeWasManuallyEdited) {
            organizationCode.value = generateCode(
                organizationName.value
            );
        }
    });

    modeInputs.forEach((input) => {
        input.addEventListener("change", updateMode);
    });

    form.addEventListener("submit", (event) => {
        updateMode();

        if (!form.checkValidity()) {
            event.preventDefault();
            form.reportValidity();
        }
    });

    updateMode();
});
