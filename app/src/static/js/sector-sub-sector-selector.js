"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const sectorSelect = document.getElementById("sector_id");
    const subSectorSelect = document.getElementById("sub_sector_id");

    if (!sectorSelect || !subSectorSelect) {
        return;
    }

    async function loadSubSectors(sectorId, preselectId) {
        subSectorSelect.innerHTML = "";
        if (!sectorId) {
            subSectorSelect.appendChild(new Option("Select a sector first", ""));
            return;
        }
        subSectorSelect.appendChild(new Option("Loading…", ""));
        const response = await fetch(
            "/administration/api/sub-sectors?sector_id=" + encodeURIComponent(sectorId)
        );
        const subSectors = response.ok ? await response.json() : [];
        subSectorSelect.innerHTML = "";
        subSectorSelect.appendChild(new Option("Select sub-sector", ""));
        subSectors.forEach((subSector) => {
            const option = new Option(subSector.name, subSector.id);
            if (preselectId && subSector.id === preselectId) {
                option.selected = true;
            }
            subSectorSelect.appendChild(option);
        });
    }

    sectorSelect.addEventListener("change", () => {
        loadSubSectors(sectorSelect.value, "");
    });

    const initialSubSectorId = subSectorSelect.getAttribute("data-selected-value");
    if (sectorSelect.value) {
        loadSubSectors(sectorSelect.value, initialSubSectorId);
    }
});
