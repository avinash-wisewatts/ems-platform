"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const form = document.getElementById("asset_form");
    if (!form) return;

    const modeInputs = Array.from(form.querySelectorAll('input[name="asset_mode"]'));
    const existingSection = document.getElementById("existing_asset_fields");
    const createSection = document.getElementById("create_asset_fields");
    const existingAsset = document.getElementById("existing_asset_id");
    const assetName = document.getElementById("asset_name");
    const assetType = document.getElementById("asset_type_id");
    const relationship = document.getElementById("relationship_type");
    const relationshipError = document.getElementById("relationship_type_error");
    const submitButton = document.getElementById("asset_submit");
    const draftToken = form.querySelector('input[name="draft_token"]')?.value || "";

    let validationController = null;
    let relationshipValid = true;
    let validationPending = false;

    const selectedMode = () => modeInputs.find((input) => input.checked)?.value || "CREATE_NEW";

    const setSectionEnabled = (section, enabled) => {
        if (!section) return;
        section.hidden = !enabled;
        section.querySelectorAll("input, select, textarea").forEach((field) => {
            field.disabled = !enabled;
        });
    };

    const updateSubmitState = () => {
        if (!submitButton) return;
        submitButton.disabled = validationPending || !relationshipValid;
        submitButton.setAttribute("aria-busy", validationPending ? "true" : "false");
        submitButton.textContent = validationPending ? "Checking…" : "Save & Continue";
    };

    const setRelationshipFeedback = ({ valid, message = "", pending = false }) => {
        relationshipValid = valid;
        validationPending = pending;
        relationship.classList.toggle("field-invalid", !valid && !pending);
        relationship.setAttribute("aria-invalid", !valid && !pending ? "true" : "false");
        relationshipError.hidden = valid || pending;
        relationshipError.textContent = valid || pending ? "" : message;
        updateSubmitState();
    };

    const validateRelationship = async () => {
        validationController?.abort();

        if (selectedMode() !== "USE_EXISTING") {
            setRelationshipFeedback({ valid: true });
            return;
        }

        const assetId = existingAsset?.value || "";
        const relationshipType = relationship?.value || "";
        if (!assetId || !relationshipType) {
            setRelationshipFeedback({ valid: false, message: "Select an existing asset and relationship type." });
            return;
        }

        validationController = new AbortController();
        setRelationshipFeedback({ valid: true, pending: true });

        const params = new URLSearchParams({
            draft: draftToken,
            asset_id: assetId,
            relationship_type: relationshipType,
        });

        try {
            const response = await fetch(`/onboarding/asset/relationship-validation?${params}`, {
                headers: { Accept: "application/json" },
                credentials: "same-origin",
                signal: validationController.signal,
            });
            const result = await response.json();
            setRelationshipFeedback({
                valid: Boolean(result.valid),
                message: result.message || "Choose a different relationship type.",
            });
        } catch (error) {
            if (error.name === "AbortError") return;
            setRelationshipFeedback({
                valid: false,
                message: "Relationship validation is temporarily unavailable. Try again.",
            });
        }
    };

    const updateMode = () => {
        const useExisting = selectedMode() === "USE_EXISTING";
        setSectionEnabled(existingSection, useExisting);
        setSectionEnabled(createSection, !useExisting);
        if (existingAsset) existingAsset.required = useExisting;
        assetName.required = !useExisting;
        assetType.required = !useExisting;
        relationship.required = true;
        void validateRelationship();
    };

    modeInputs.forEach((input) => input.addEventListener("change", updateMode));
    existingAsset?.addEventListener("change", validateRelationship);
    relationship?.addEventListener("change", validateRelationship);

    form.addEventListener("submit", (event) => {
        updateMode();
        if (!form.checkValidity() || validationPending || !relationshipValid) {
            event.preventDefault();
            form.reportValidity();
            if (!relationshipValid) relationship.focus();
        }
    });

    updateMode();
});
