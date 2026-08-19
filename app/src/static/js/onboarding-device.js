"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const form = document.getElementById("device_form");

    if (!form) {
        return;
    }

    const modeInputs = Array.from(
        form.querySelectorAll('input[name="device_mode"]')
    );

    const existingSection = document.getElementById(
        "existing_device_fields"
    );

    const createSection = document.getElementById(
        "create_device_fields"
    );

    const existingDevice = document.getElementById(
        "existing_device_id"
    );

    const existingIdentifierType = document.getElementById(
        "existing_identifier_type"
    );
    const existingIdentifierValue = document.getElementById(
        "existing_identifier_value"
    );

    const updateExistingIdentity = () => {
        if (!existingDevice) {
            return;
        }

        const selectedOption = existingDevice.options[
            existingDevice.selectedIndex
        ];
        const identifierType = selectedOption?.dataset.identifierType || "";
        const identifierValue = selectedOption?.dataset.identifierValue || "";

        if (existingIdentifierType) {
            existingIdentifierType.value = identifierType;
        }
        if (existingIdentifierValue) {
            existingIdentifierValue.value = identifierValue;
        }
    };

    const deviceName = document.getElementById("device_name");
    const category = document.getElementById(
        "device_category_id"
    );

    const model = document.getElementById("device_model_id");
    const manufacturer = document.querySelector(
        "[data-device-manufacturer]"
    );
    const modelEmptyHelp = document.querySelector(
        "[data-model-empty]"
    );
    const protocol = document.getElementById(
        "device_protocol"
    );

    const profile = document.getElementById("profile_code");
    const newIdentifier = document.getElementById(
        "new_identifier_value"
    );

    const setSectionEnabled = (section, enabled) => {
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

    const updateManufacturer = () => {
        if (!manufacturer) {
            return;
        }

        const selectedOption =
            model.options[model.selectedIndex];

        manufacturer.value =
            (selectedOption && selectedOption.dataset.vendor) || "";
    };

    const filterModels = () => {
        const selectedCategory = category.value;
        const options = Array.from(model.options);

        options.forEach((option, index) => {
            if (index === 0) {
                option.hidden = false;
                option.disabled = false;
                return;
            }

            const compatible = (
                selectedCategory
                && option.dataset.category === selectedCategory
            );

            option.hidden = !compatible;
            option.disabled = !compatible;
        });

        const selectedOption =
            model.options[model.selectedIndex];

        if (selectedOption && selectedOption.disabled) {
            model.value = "";
        }

        if (modelEmptyHelp) {
            const hasCompatibleModel = options.some(
                (option, index) => index > 0 && !option.disabled
            );

            modelEmptyHelp.hidden =
                !selectedCategory || hasCompatibleModel;
        }

        updateManufacturer();
    };

    const filterProfiles = () => {
        const selectedCategory = category.value;
        const options = Array.from(profile.options);

        options.forEach((option, index) => {
            if (index === 0) {
                option.hidden = false;
                option.disabled = false;
                return;
            }

            const categoryIds = (
                option.dataset.categoryIds || ""
            )
                .split(",")
                .map((value) => value.trim())
                .filter(Boolean);

            const compatible = (
                selectedCategory
                && categoryIds.includes(selectedCategory)
            );

            option.hidden = !compatible;
            option.disabled = !compatible;
        });

        const selectedOption =
            profile.options[profile.selectedIndex];

        if (
            selectedOption
            && selectedOption.disabled
        ) {
            profile.value = "";
        }
    };

    const updateMode = () => {
        const mode = modeInputs.find(
            (input) => input.checked
        )?.value || "CREATE_NEW";

        const useExisting = mode === "USE_EXISTING";

        setSectionEnabled(existingSection, useExisting);
        setSectionEnabled(createSection, !useExisting);

        if (existingDevice) {
            existingDevice.required = useExisting;

            if (useExisting) {
                updateExistingIdentity();
            }
        }

        [
            deviceName,
            category,
            model,
            protocol,
            profile,
            newIdentifier,
        ].forEach((field) => {
            field.required = !useExisting;
        });
    };

    category.addEventListener("change", () => {
        filterProfiles();
        filterModels();
    });

    model.addEventListener("change", updateManufacturer);

    modeInputs.forEach((input) => {
        input.addEventListener("change", updateMode);
    });

    if (existingDevice) {
        existingDevice.addEventListener(
            "change",
            updateExistingIdentity
        );
    }

    form.addEventListener("submit", (event) => {
        updateMode();

        if (!form.checkValidity()) {
            event.preventDefault();
            form.reportValidity();
        }
    });

    filterProfiles();
    filterModels();
    updateExistingIdentity();
    updateMode();
});
