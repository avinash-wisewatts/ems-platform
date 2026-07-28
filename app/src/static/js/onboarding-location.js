"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const form = document.getElementById("location_form");

    if (!form) {
        return;
    }

    const modeInputs = Array.from(
        form.querySelectorAll(
            'input[name="location_mode"]'
        )
    );

    const siteOnlySection = document.getElementById(
        "site_only_fields"
    );

    const createSection = document.getElementById(
        "create_location_fields"
    );

    const existingSection = document.getElementById(
        "existing_space_fields"
    );

    const existingSpace = document.getElementById(
        "existing_space_id"
    );

    const generatedPairs = [
        ["building_name", "building_code"],
        ["floor_name", "floor_code"],
        ["space_name", "space_code"],
    ];

    const manualCodeState = new Map();

    const generateCode = (value) => window.WiseWattsCode.generate(value);

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

    generatedPairs.forEach(([nameId, codeId]) => {
        const nameField = document.getElementById(nameId);
        const codeField = document.getElementById(codeId);

        manualCodeState.set(
            codeId,
            codeField.value.trim().length > 0
        );

        nameField.addEventListener("input", () => {
            if (!manualCodeState.get(codeId)) {
                codeField.value = generateCode(
                    nameField.value
                );
            }
        });
    });

    const updateMode = () => {
        const mode = modeInputs.find(
            (input) => input.checked
        )?.value || "SITE_ONLY";

        const createLocation =
            mode === "CREATE_LOCATION";

        const useExisting =
            mode === "USE_EXISTING_SPACE";

        siteOnlySection.hidden =
            mode !== "SITE_ONLY";

        setSectionEnabled(
            createSection,
            createLocation,
        );

        setSectionEnabled(
            existingSection,
            useExisting,
        );

        [
            "building_name",
            "building_code",
            "floor_name",
            "floor_code",
            "space_name",
            "space_code",
        ].forEach((fieldId) => {
            document.getElementById(fieldId).required =
                createLocation;
        });

        existingSpace.required = useExisting;
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
