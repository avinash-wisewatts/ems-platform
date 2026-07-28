"use strict";

window.WiseWattsCode = Object.freeze({
    generate(value, maxLength = 100) {
        return String(value || "")
            .normalize("NFKD")
            .replace(/[\u0300-\u036f]/g, "")
            .trim()
            .toUpperCase()
            .replace(/[^A-Z0-9]+/g, "_")
            .replace(/^_+|_+$/g, "")
            .replace(/_+/g, "_")
            .slice(0, maxLength)
            .replace(/_+$/g, "");
    },

    bind(root = document) {
        root.querySelectorAll("[data-generated-code-from]").forEach((field) => {
            const source = root.getElementById(field.dataset.generatedCodeFrom);
            if (!source) return;
            const update = () => {
                field.value = window.WiseWattsCode.generate(source.value);
                field.dispatchEvent(new Event("change", { bubbles: true }));
            };
            source.addEventListener("input", update);
            if (!field.value) update();
        });
    },
});

document.addEventListener("DOMContentLoaded", () => {
    window.WiseWattsCode.bind(document);
});
