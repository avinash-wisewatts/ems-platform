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

    let codeWasManuallyEdited =
        siteCode && siteCode.value.trim().length > 0;

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

        siteCode.addEventListener("input", () => {
            codeWasManuallyEdited = true;
            siteCode.value = generateCode(
                siteCode.value
            );
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
