"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const form = document.getElementById("gateway_form");

    if (!form) {
        return;
    }

    const modeInputs = Array.from(
        form.querySelectorAll(
            'input[name="gateway_mode"]'
        )
    );

    const existingSection = document.getElementById(
        "existing_gateway_fields"
    );

    const createSection = document.getElementById(
        "create_gateway_fields"
    );

    const existingGateway = document.getElementById(
        "existing_gateway_id"
    );

    const gatewayName = document.getElementById(
        "gateway_name"
    );

    const gatewayModelId = document.getElementById(
        "gateway_model_id"
    );

    const setSectionEnabled = (
        section,
        enabled,
    ) => {
        if (!section) {
            return;
        }

        section.hidden = !enabled;

        section
            .querySelectorAll("input, select, textarea")
            .forEach((field) => {
                field.disabled = !enabled;
            });
    };

    const updateMode = () => {
        const mode = modeInputs.find(
            (input) => input.checked
        )?.value || "CREATE_NEW";

        const useExisting =
            mode === "USE_EXISTING";

        setSectionEnabled(
            existingSection,
            useExisting,
        );

        setSectionEnabled(
            createSection,
            !useExisting,
        );

        if (existingGateway) {
            existingGateway.required = useExisting;
        }

        gatewayName.required = !useExisting;
        gatewayModelId.required = !useExisting;
    };

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
