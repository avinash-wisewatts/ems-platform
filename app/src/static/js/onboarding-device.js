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
    const externalId = document.getElementById(
        "device_external_id"
    );

    const category = document.getElementById(
        "device_category_id"
    );

    const vendor = document.getElementById("device_vendor");
    const model = document.getElementById("device_model");
    const protocol = document.getElementById(
        "device_protocol"
    );

    const profile = document.getElementById("profile_code");
    const newIdentifier = document.getElementById(
        "new_identifier_value"
    );

    let externalIdEdited =
        externalId.value.trim().length > 0;

    const generateCode = (value) => {
        return value
            .trim()
            .toUpperCase()
            .replace(/[^A-Z0-9]+/g, "_")
            .replace(/^_+|_+$/g, "")
            .replace(/_+/g, "_")
            .slice(0, 100);
    };

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
            externalId,
            category,
            vendor,
            model,
            protocol,
            profile,
            newIdentifier,
        ].forEach((field) => {
            field.required = !useExisting;
        });
    };

    deviceName.addEventListener("input", () => {
        if (!externalIdEdited) {
            externalId.value = generateCode(
                deviceName.value
            );
        }
    });

    externalId.addEventListener("input", () => {
        externalIdEdited = true;
        externalId.value = generateCode(
            externalId.value
        );
    });

    category.addEventListener("change", filterProfiles);

    model.addEventListener("change", () => {
        const options = Array.from(
            document.querySelectorAll(
                "#device_model_catalog option"
            )
        );

        const selected = options.find(
            (option) =>
                option.value.toLowerCase()
                === model.value.trim().toLowerCase()
        );

        if (!selected) {
            return;
        }

        if (
            !vendor.value.trim()
            && selected.dataset.vendor
        ) {
            vendor.value = selected.dataset.vendor;
        }

        if (selected.dataset.categoryId) {
            category.value =
                selected.dataset.categoryId;
            filterProfiles();
        }
    });

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
    updateExistingIdentity();
    updateMode();
});
