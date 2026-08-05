(() => {
    const form = document.querySelector("[data-user-scope-form]");
    if (!form) return;

    const radios = [...form.querySelectorAll('input[name="access_scope_mode"]')];
    const organizationField = form.querySelector("[data-scope-organization-field]");
    const organizationInput = form.querySelector("[data-scope-organization]");
    const sitesField = form.querySelector("[data-scope-sites-field]");
    const siteOptions = [...form.querySelectorAll("[data-site-organization]")];
    const noSitesMessage = form.querySelector("[data-no-sites-message]");

    const selectedMode = () => radios.find((radio) => radio.checked)?.value || "";

    const refresh = () => {
        const mode = selectedMode();
        const organizationId = organizationInput?.value || "";
        const organizationRequired = mode === "ORGANIZATION" || mode === "SELECTED_SITES";
        const sitesRequired = mode === "SELECTED_SITES";

        if (organizationField) {
            organizationField.hidden = !organizationRequired;
        }

        if (organizationInput && organizationInput.tagName === "SELECT") {
            organizationInput.disabled = !organizationRequired;
            organizationInput.required = organizationRequired;
        }

        if (sitesField) {
            sitesField.hidden = !sitesRequired;
        }

        let visibleSiteCount = 0;
        siteOptions.forEach((option) => {
            const belongsToOrganization = !organizationId || option.dataset.siteOrganization === organizationId;
            const visible = sitesRequired && belongsToOrganization;
            option.hidden = !visible;
            const checkbox = option.querySelector('input[type="checkbox"]');
            if (checkbox) checkbox.disabled = !visible;
            if (visible) visibleSiteCount += 1;
        });

        if (noSitesMessage) {
            noSitesMessage.hidden = !sitesRequired || visibleSiteCount > 0;
        }
    };

    radios.forEach((radio) => radio.addEventListener("change", refresh));
    organizationInput?.addEventListener("change", refresh);
    refresh();
})();
