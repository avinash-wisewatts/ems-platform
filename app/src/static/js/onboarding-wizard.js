"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const form = document.querySelector(".onboarding-form");

    if (!form) {
        return;
    }

    const steps = Array.from(
        form.querySelectorAll("[data-wizard-step]")
    );

    const showStep = (stepNumber) => {
        steps.forEach((step) => {
            const isActive =
                step.dataset.wizardStep === String(stepNumber);

            step.classList.toggle("is-active", isActive);
        });

        const activeStep = form.querySelector(
            `[data-wizard-step="${stepNumber}"]`
        );

        activeStep?.scrollIntoView({
            behavior: "smooth",
            block: "start",
        });
    };

    const setSectionState = (
        section,
        enabled,
        requiredFieldIds = []
    ) => {
        if (!section) {
            return;
        }

        section.hidden = !enabled;

        section
            .querySelectorAll("input, select, textarea")
            .forEach((field) => {
                field.disabled = !enabled;
                field.required =
                    enabled &&
                    requiredFieldIds.includes(field.id);
            });
    };

    const organizationModeInputs = Array.from(
        form.querySelectorAll(
            'input[name="organization_mode"]'
        )
    );

    const existingOrganizationFields =
        document.getElementById(
            "existing_organization_fields"
        );

    const createOrganizationFields =
        document.getElementById(
            "create_organization_fields"
        );

    const updateOrganizationMode = () => {
        const mode = organizationModeInputs.find(
            (input) => input.checked
        )?.value || "CREATE_NEW";

        const useExisting = mode === "USE_EXISTING";

        setSectionState(
            existingOrganizationFields,
            useExisting,
            ["existing_organization_id"]
        );

        setSectionState(
            createOrganizationFields,
            !useExisting,
            [
                "organization_name",
                "organization_code",
            ]
        );
    };

    organizationModeInputs.forEach((input) => {
        input.addEventListener(
            "change",
            updateOrganizationMode
        );
    });

    form
        .querySelectorAll(".wizard-next")
        .forEach((button) => {
            button.addEventListener("click", () => {
                const currentStep = button.closest(
                    "[data-wizard-step]"
                );

                if (!currentStep) {
                    return;
                }

                const fields = Array.from(
                    currentStep.querySelectorAll(
                        "input, select, textarea"
                    )
                ).filter((field) => !field.disabled);

                const firstInvalid = fields.find(
                    (field) => !field.checkValidity()
                );

                if (firstInvalid) {
                    firstInvalid.reportValidity();
                    firstInvalid.focus();
                    return;
                }

                showStep(button.dataset.nextStep);
            });
        });

    form
        .querySelectorAll(".wizard-back")
        .forEach((button) => {
            button.addEventListener("click", () => {
                showStep(button.dataset.previousStep);
            });
        });

    updateOrganizationMode();

    const errorField = form.dataset.errorField;
    const errorElement = errorField
        ? form.elements.namedItem(errorField)
        : null;

    if (errorElement instanceof HTMLElement) {
        const errorStep = errorElement.closest(
            "[data-wizard-step]"
        );

        if (errorStep) {
            showStep(errorStep.dataset.wizardStep);
            return;
        }
    }

    showStep(1);
});
