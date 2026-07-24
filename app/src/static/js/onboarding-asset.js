"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const form = document.getElementById("asset_form");

    if (!form) {
        return;
    }

    const modeInputs = Array.from(
        form.querySelectorAll('input[name="asset_mode"]')
    );

    const existingSection = document.getElementById(
        "existing_asset_fields"
    );

    const createSection = document.getElementById(
        "create_asset_fields"
    );

    const existingAsset = document.getElementById(
        "existing_asset_id"
    );

    const assetName = document.getElementById(
        "asset_name"
    );

    const assetType = document.getElementById(
        "asset_type_id"
    );

    const relationship = document.getElementById(
        "relationship_type"
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

        if (existingAsset) {
            existingAsset.required = useExisting;
        }

        assetName.required = !useExisting;
        assetType.required = !useExisting;
        relationship.required = true;
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
