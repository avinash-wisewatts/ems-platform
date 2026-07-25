"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const selectors = document.querySelectorAll(
        "[data-physical-location-selector]"
    );

    const uniqueOptions = (
        rows,
        idField,
        nameField,
        codeField,
    ) => {
        const options = new Map();

        rows.forEach((row) => {
            const id = row[idField];

            if (!id || options.has(String(id))) {
                return;
            }

            options.set(String(id), {
                id: String(id),
                label: `${row[nameField]} (${row[codeField]})`,
            });
        });

        return Array.from(options.values());
    };

    const replaceOptions = (
        select,
        placeholder,
        options,
        selectedValue,
    ) => {
        select.replaceChildren();

        const emptyOption = document.createElement("option");
        emptyOption.value = "";
        emptyOption.textContent = placeholder;
        select.appendChild(emptyOption);

        options.forEach((option) => {
            const element = document.createElement("option");
            element.value = option.id;
            element.textContent = option.label;
            element.selected = option.id === selectedValue;
            select.appendChild(element);
        });

        select.disabled = options.length === 0;
    };

    selectors.forEach((selector) => {
        const rows = JSON.parse(
            selector.querySelector(
                "[data-location-options]"
            ).textContent
        );

        const site = selector.querySelector(
            '[data-location-level="site"]'
        );
        const building = selector.querySelector(
            '[data-location-level="building"]'
        );
        const floor = selector.querySelector(
            '[data-location-level="floor"]'
        );
        const space = selector.querySelector(
            '[data-location-level="space"]'
        );
        const result = selector.querySelector(
            "[data-location-result]"
        );
        const path = selector.querySelector(
            "[data-location-path]"
        );

        const initial = {
            building: building.dataset.selectedValue || "",
            floor: floor.dataset.selectedValue || "",
            space: space.dataset.selectedValue || "",
        };

        const selectedRow = () => {
            return rows.find((row) => {
                if (
                    space.value
                    && String(row.space_id) === space.value
                ) {
                    return true;
                }

                if (
                    floor.value
                    && String(row.floor_id) === floor.value
                ) {
                    return true;
                }

                if (
                    building.value
                    && String(row.building_id) === building.value
                ) {
                    return true;
                }

                return (
                    site.value
                    && String(row.site_id) === site.value
                );
            });
        };

        const updateResult = () => {
            result.value = (
                space.value
                || floor.value
                || building.value
                || site.value
            );

            const row = selectedRow();

            if (!row) {
                path.textContent = "No location selected.";
                return;
            }

            const parts = [
                row.site_name,
                building.value ? row.building_name : null,
                floor.value ? row.floor_name : null,
                space.value ? row.space_name : null,
            ].filter(Boolean);

            path.textContent = parts.join(" / ");
        };

        const updateSpaces = () => {
            const matching = rows.filter(
                (row) => (
                    String(row.site_id) === site.value
                    && String(row.building_id) === building.value
                    && String(row.floor_id) === floor.value
                )
            );

            replaceOptions(
                space,
                "Floor level only",
                uniqueOptions(
                    matching,
                    "space_id",
                    "space_name",
                    "space_code",
                ),
                initial.space,
            );

            initial.space = "";
            updateResult();
        };

        const updateFloors = () => {
            const matching = rows.filter(
                (row) => (
                    String(row.site_id) === site.value
                    && String(row.building_id) === building.value
                )
            );

            replaceOptions(
                floor,
                "Building level only",
                uniqueOptions(
                    matching,
                    "floor_id",
                    "floor_name",
                    "floor_code",
                ),
                initial.floor,
            );

            initial.floor = "";
            updateSpaces();
        };

        const updateBuildings = () => {
            const matching = rows.filter(
                (row) => String(row.site_id) === site.value
            );

            replaceOptions(
                building,
                "Site level only",
                uniqueOptions(
                    matching,
                    "building_id",
                    "building_name",
                    "building_code",
                ),
                initial.building,
            );

            initial.building = "";
            updateFloors();
        };

        site.addEventListener("change", updateBuildings);
        building.addEventListener("change", updateFloors);
        floor.addEventListener("change", updateSpaces);
        space.addEventListener("change", updateResult);

        updateBuildings();
    });
});
