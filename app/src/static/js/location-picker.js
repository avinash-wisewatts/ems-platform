"use strict";

/**
 * Shared cascading Building -> Floor -> Space picker.
 *
 * One picker instance is any element carrying [data-physical-location-selector].
 * Inside it:
 *   - an optional [data-location-level="site"] <select> (omit when the site
 *     is already fixed elsewhere on the page, e.g. an active-context gateway
 *     or asset form)
 *   - required [data-location-level="building"|"floor"|"space"] <select>s
 *   - a required <script type="application/json" data-location-options>
 *     holding the row catalog: [{site_id, site_name, site_code,
 *     building_id, building_name, building_code, floor_id, floor_name,
 *     floor_code, space_id, space_name, space_code}, ...]
 *   - an optional [data-location-result] hidden input, filled with the
 *     most specific selected id
 *   - an optional [data-location-path] element, filled with a human
 *     readable "Site / Building / Floor / Space" breadcrumb
 *
 * Optional container attributes:
 *   - data-location-scope-source="<CSS selector>": another <select>
 *     elsewhere on the page (e.g. a gateway picker) whose selected
 *     option's data-site attribute determines which site's rows this
 *     picker cascades through. Selecting a new option there resets and
 *     rebuilds the whole picker. Use this instead of a site-level select
 *     when the site is chosen indirectly.
 *   - data-label-style="breadcrumb": render options as
 *     "Site / Building / Floor" instead of the default "Name (CODE)".
 *   - data-placeholder-building / -floor / -space: override the
 *     unselected-option text for that level (defaults below).
 *
 * NOTE ON SCRIPT ORDER: consumers that also run their own logic on the
 * same building/floor/space selects (device-workspace.js, in particular)
 * rely on this script's change listeners firing first so the options are
 * already rebuilt by the time their own listeners read them. Always
 * include this <script> tag before any such consumer script.
 */
document.addEventListener("DOMContentLoaded", () => {
    const DEFAULT_PLACEHOLDERS = {
        building: "Site level",
        floor: "No floor",
        space: "No space",
    };

    const text = (value) => (value == null ? "" : String(value));

    const uniqueOptions = (rows, idField, nameField, codeField) => {
        const options = new Map();

        rows.forEach((row) => {
            const id = text(row[idField]);

            if (!id || options.has(id)) {
                return;
            }

            options.set(id, {
                id,
                name: row[nameField] || id,
                code: row[codeField] || "",
            });
        });

        return Array.from(options.values());
    };

    const breadcrumbLabel = (rows, id, idField, level) => {
        const row = rows.find(
            (candidate) => text(candidate[idField]) === id
        );

        if (!row) {
            return id;
        }

        const withCode = (name, code) =>
            [name, code && `(${code})`].filter(Boolean).join(" ");

        const parts = [
            withCode(row.site_name, row.site_code),
            withCode(row.building_name, row.building_code),
        ];

        if (level === "floor" || level === "space") {
            parts.push(withCode(row.floor_name, row.floor_code));
        }

        if (level === "space") {
            parts.push(withCode(row.space_name, row.space_code));
        }

        return parts.filter(Boolean).join(" / ");
    };

    const initPicker = (container) => {
        const optionsScript = container.querySelector(
            "[data-location-options]"
        );

        if (!optionsScript) {
            return;
        }

        const allRows = JSON.parse(optionsScript.textContent || "[]");

        const siteSelect = container.querySelector(
            '[data-location-level="site"]'
        );
        const buildingSelect = container.querySelector(
            '[data-location-level="building"]'
        );
        const floorSelect = container.querySelector(
            '[data-location-level="floor"]'
        );
        const spaceSelect = container.querySelector(
            '[data-location-level="space"]'
        );
        const resultField = container.querySelector(
            "[data-location-result]"
        );
        const pathField = container.querySelector("[data-location-path]");

        if (!buildingSelect || !floorSelect || !spaceSelect) {
            return;
        }

        const labelStyle = container.dataset.labelStyle || "name-code";

        const placeholders = {
            building:
                container.dataset.placeholderBuilding
                || DEFAULT_PLACEHOLDERS.building,
            floor:
                container.dataset.placeholderFloor
                || DEFAULT_PLACEHOLDERS.floor,
            space:
                container.dataset.placeholderSpace
                || DEFAULT_PLACEHOLDERS.space,
        };

        const scopeSourceSelector = container.dataset.locationScopeSource;
        const scopeSource = scopeSourceSelector
            ? document.querySelector(scopeSourceSelector)
            : null;

        const pending = {
            building: buildingSelect.dataset.selectedValue || "",
            floor: floorSelect.dataset.selectedValue || "",
            space: spaceSelect.dataset.selectedValue || "",
        };

        let scopedRows = allRows;

        const resolveScope = () => {
            if (!scopeSource) {
                scopedRows = allRows;
                return;
            }

            const siteId = text(
                scopeSource.selectedOptions[0]?.dataset.site
            );

            scopedRows = siteId
                ? allRows.filter((row) => text(row.site_id) === siteId)
                : [];
        };

        const populate = (select, level, rows, idField, selectedValue) => {
            const options = uniqueOptions(
                rows,
                idField,
                `${level}_name`,
                `${level}_code`
            );

            const retained = text(selectedValue);

            select.replaceChildren();

            const blank = document.createElement("option");
            blank.value = "";
            blank.textContent = placeholders[level];
            select.appendChild(blank);

            options.forEach((option) => {
                const element = document.createElement("option");
                element.value = option.id;
                element.textContent =
                    labelStyle === "breadcrumb"
                        ? breadcrumbLabel(rows, option.id, idField, level)
                        : `${option.name} (${option.code})`;
                element.selected = option.id === retained;
                select.appendChild(element);
            });

            select.disabled = options.length === 0;

            if (
                retained
                && ![...select.options].some(
                    (option) => option.value === retained
                )
            ) {
                select.value = "";
            }
        };

        const updateSummary = () => {
            if (resultField) {
                resultField.value =
                    spaceSelect.value
                    || floorSelect.value
                    || buildingSelect.value
                    || (siteSelect ? siteSelect.value : "");
            }

            if (!pathField) {
                return;
            }

            const row = scopedRows.find((candidate) => {
                if (spaceSelect.value) {
                    return text(candidate.space_id) === spaceSelect.value;
                }
                if (floorSelect.value) {
                    return text(candidate.floor_id) === floorSelect.value;
                }
                if (buildingSelect.value) {
                    return (
                        text(candidate.building_id) === buildingSelect.value
                    );
                }
                return siteSelect ? Boolean(siteSelect.value) : false;
            });

            if (!row) {
                pathField.textContent = "No location selected.";
                return;
            }

            const parts = [
                row.site_name,
                buildingSelect.value ? row.building_name : null,
                floorSelect.value ? row.floor_name : null,
                spaceSelect.value ? row.space_name : null,
            ].filter(Boolean);

            pathField.textContent = parts.join(" / ");
        };

        const rebuildSpaces = () => {
            const rows = scopedRows.filter(
                (row) => text(row.floor_id) === floorSelect.value
            );

            populate(spaceSelect, "space", rows, "space_id", pending.space);
            pending.space = "";
            updateSummary();
        };

        const rebuildFloors = () => {
            const rows = scopedRows.filter(
                (row) => text(row.building_id) === buildingSelect.value
            );

            populate(floorSelect, "floor", rows, "floor_id", pending.floor);
            pending.floor = "";
            rebuildSpaces();
        };

        const rebuildBuildings = () => {
            populate(
                buildingSelect,
                "building",
                scopedRows,
                "building_id",
                pending.building
            );
            pending.building = "";
            rebuildFloors();
        };

        buildingSelect.addEventListener("change", rebuildFloors);
        floorSelect.addEventListener("change", rebuildSpaces);
        spaceSelect.addEventListener("change", updateSummary);

        if (siteSelect) {
            siteSelect.addEventListener("change", () => {
                scopedRows = allRows.filter(
                    (row) => text(row.site_id) === siteSelect.value
                );
                rebuildBuildings();
            });
        }

        if (scopeSource) {
            scopeSource.addEventListener("change", () => {
                pending.building = "";
                pending.floor = "";
                pending.space = "";
                resolveScope();
                rebuildBuildings();
            });
        }

        if (siteSelect && siteSelect.value) {
            scopedRows = allRows.filter(
                (row) => text(row.site_id) === siteSelect.value
            );
        } else {
            resolveScope();
        }

        rebuildBuildings();
    };

    document
        .querySelectorAll("[data-physical-location-selector]")
        .forEach(initPicker);
});
