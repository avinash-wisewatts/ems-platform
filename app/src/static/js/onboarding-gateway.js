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

    const gatewayVendor = document.getElementById(
        "gateway_vendor"
    );

    const gatewayModel = document.getElementById(
        "gateway_model"
    );

    const gatewayProtocol = document.getElementById(
        "gateway_protocol"
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
        gatewayVendor.required = !useExisting;
        gatewayModel.required = !useExisting;
        gatewayProtocol.required = !useExisting;
    };

    gatewayModel.addEventListener("change", () => {
        const modelOptions = Array.from(
            document.querySelectorAll(
                "#gateway_model_catalog option"
            )
        );

        const selectedModel = modelOptions.find(
            (option) =>
                option.value.toLowerCase()
                === gatewayModel.value.trim().toLowerCase()
        );

        if (!selectedModel) {
            return;
        }

        if (
            !gatewayVendor.value.trim()
            && selectedModel.dataset.vendor
        ) {
            gatewayVendor.value =
                selectedModel.dataset.vendor;
        }

        if (selectedModel.dataset.protocol) {
            gatewayProtocol.value =
                selectedModel.dataset.protocol;
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
