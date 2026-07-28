"use strict";

(() => {
    const RULES = {
        organization: [
            "existing_organization_id",
            "organization_name",
            "organization_code",
            "organization_timezone",
        ],
        site: [
            "existing_site_id",
            "site_name",
            "site_code",
            "site_timezone",
            "site_address",
        ],
        location: [
            "existing_space_id",
            "building_name",
            "building_code",
            "floor_name",
            "floor_code",
            "space_name",
            "space_code",
        ],
        gateway: [
            "existing_gateway_id",
            "gateway_name",
            "gateway_external_id",
            "gateway_vendor",
            "gateway_model",
            "gateway_protocol",
        ],
        device: [
            "existing_device_id",
            "device_name",
            "device_external_id",
            "device_vendor",
            "device_model",
            "device_category_id",
            "device_protocol",
            "profile_code",
            "new_identifier_value",
        ],
        asset: [
            "existing_asset_id",
            "asset_name",
            "asset_external_id",
            "asset_type_id",
            "metering_requirement",
            "relationship_type",
        ],
    };

    const formToObject = (form) => {
        const result = {};
        new FormData(form).forEach((value, key) => { result[key] = String(value); });
        return result;
    };

    const isApplicable = (field) => {
        if (field.disabled || field.type === "hidden" || field.closest("[hidden]")) return false;
        const modePanel = field.closest("[data-mode-panel]");
        return !modePanel || !modePanel.hidden;
    };

    const messageNode = (field) => {
        let node = document.getElementById(`${field.id}_validation`);
        if (!node) {
            node = document.createElement("span");
            node.id = `${field.id}_validation`;
            node.className = "field-validation-message";
            node.setAttribute("aria-live", "polite");
            field.insertAdjacentElement("afterend", node);
        }
        return node;
    };

    document.addEventListener("DOMContentLoaded", () => {
        const form = document.querySelector("form[id$='_form']");
        if (!form) return;

        const step = form.id.replace(/_form$/, "");
        const fields = (RULES[step] || []).map((id) => document.getElementById(id)).filter(Boolean);
        if (!fields.length) return;

        const submit = form.querySelector('button[type="submit"], input[type="submit"]');
        const invalid = new Set();
        const pending = new Set();
        const timers = new Map();
        const sequence = new Map();
        let validatedSubmit = false;

        const syncSubmit = () => {
            if (!submit) return;
            submit.disabled = invalid.size > 0 || pending.size > 0;
            submit.setAttribute("aria-disabled", String(submit.disabled));
        };

        const setState = (field, result, isPending = false) => {
            const node = messageNode(field);
            pending.delete(field.id);
            invalid.delete(field.id);
            field.removeAttribute("aria-invalid");
            field.classList.remove("is-validating", "is-invalid");

            if (isPending) {
                pending.add(field.id);
                field.classList.add("is-validating");
                node.textContent = "Checking…";
            } else if (!result.valid) {
                invalid.add(field.id);
                field.classList.add("is-invalid");
                field.setAttribute("aria-invalid", "true");
                node.textContent = result.message || "Check this value.";
            } else if (result.code === "IDENTIFIER_ADJUSTED") {
                node.textContent = result.message
                    || "A unique identifier was generated.";
            } else {
                node.textContent = "";
            }

            syncSubmit();
        };

        const validateNow = async (field) => {
            if (!isApplicable(field) || !String(field.value || "").trim()) {
                setState(field, {valid: true});
                return true;
            }

            const requestNumber = (sequence.get(field.id) || 0) + 1;
            sequence.set(field.id, requestNumber);
            setState(field, {valid: true}, true);

            try {
                const response = await fetch("/onboarding/validate-field", {
                    method: "POST",
                    credentials: "same-origin",
                    headers: {"Content-Type": "application/json", "Accept": "application/json"},
                    body: JSON.stringify({
                        draft: form.querySelector('[name="draft_token"]')?.value || null,
                        step,
                        field: field.id || field.name,
                        value: field.value,
                        form: formToObject(form),
                    }),
                });
                const result = await response.json();
                if (sequence.get(field.id) !== requestNumber) return false;

                const recommendedValue = String(
                    result.recommended_value || ""
                ).trim();

                if (
                    recommendedValue
                    && recommendedValue !== String(field.value || "").trim()
                ) {
                    field.value = recommendedValue;
                    field.dataset.systemGenerated = "true";

                    field.dispatchEvent(
                        new CustomEvent(
                            "wisewatts:identifier-adjusted",
                            {
                                bubbles: true,
                                detail: {
                                    value: recommendedValue,
                                    message: result.message || "",
                                },
                            },
                        ),
                    );
                }

                setState(field, result);
                return Boolean(result.valid);
            } catch (_error) {
                if (sequence.get(field.id) === requestNumber) {
                    setState(field, {valid: false, message: "Validation is temporarily unavailable."});
                }
                return false;
            }
        };

        const scheduleValidation = (field) => {
            window.clearTimeout(timers.get(field.id));
            timers.set(field.id, window.setTimeout(() => {
                timers.delete(field.id);
                void validateNow(field);
            }, 350));
        };

        fields.forEach((field) => {
            field.addEventListener("change", () => {
                void validateNow(field);
            });

            field.addEventListener("blur", () => {
                void validateNow(field);
            });

            if (
                field.tagName === "INPUT"
                || field.tagName === "TEXTAREA"
            ) {
                field.addEventListener("input", () => {
                    scheduleValidation(field);
                });
            }

            field.addEventListener(
                "wisewatts:value-generated",
                () => {
                    void validateNow(field);
                },
            );
        });

        form.addEventListener("submit", async (event) => {
            if (validatedSubmit) return;
            event.preventDefault();

            timers.forEach((timer) => window.clearTimeout(timer));
            timers.clear();

            if (!form.checkValidity()) {
                form.reportValidity();
                return;
            }

            const applicableFields = fields.filter(isApplicable);
            const results = await Promise.all(applicableFields.map(validateNow));
            const firstInvalid = applicableFields.find((field, index) => !results[index] || invalid.has(field.id));
            if (firstInvalid) {
                firstInvalid.focus();
                return;
            }

            validatedSubmit = true;
            form.requestSubmit(submit || undefined);
        });
    });
})();
