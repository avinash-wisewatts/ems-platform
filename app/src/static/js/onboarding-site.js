"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const form = document.getElementById("site_form");

    if (!form) {
        return;
    }

    const modeInputs = Array.from(
        form.querySelectorAll('input[name="site_mode"]')
    );

    const existingSection = document.getElementById(
        "existing_site_fields"
    );

    const createSection = document.getElementById(
        "create_site_fields"
    );

    const existingSite = document.getElementById(
        "existing_site_id"
    );

    const siteName = document.getElementById(
        "site_name"
    );

    const siteCode = document.getElementById(
        "site_code"
    );

    const siteTimezone = document.getElementById(
        "site_timezone"
    );

    const codeWasManuallyEdited = false;

    const generateCode = (value) => window.WiseWattsCode.generate(value);

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

        if (existingSite) {
            existingSite.required = useExisting;
        }

        if (siteName) {
            siteName.required = !useExisting;
        }

        if (siteCode) {
            siteCode.required = !useExisting;
        }

        if (siteTimezone) {
            siteTimezone.required = !useExisting;
        }
    };

    if (siteName && siteCode) {
        siteName.addEventListener("input", () => {
            if (!codeWasManuallyEdited) {
                siteCode.value = generateCode(
                    siteName.value
                );
            }
        });
    }

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
