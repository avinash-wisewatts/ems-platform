(() => {
  const form = document.querySelector('[data-device-form]');
  if (!form) return;

  const category = form.querySelector('[data-device-category]');
  const model = form.querySelector('[data-device-model]');
  const profile = form.querySelector('[data-device-profile]');
  const manufacturer = form.querySelector('[data-device-manufacturer]');
  const gateway = form.querySelector('[data-device-gateway]');
  const gatewayContext = form.querySelector('[data-gateway-context]');
  const inherit = form.querySelector('[data-use-gateway-location]');
  const building = form.querySelector('select[name="device_location_building_id"]');
  const floor = form.querySelector('select[name="device_location_floor_id"]');
  const space = form.querySelector('select[name="device_location_space_id"]');
  const locationSummary = form.querySelector('[data-device-location-summary]');
  const modelEmpty = form.querySelector('[data-model-empty]');
  const profileEmpty = form.querySelector('[data-profile-empty]');
  const deviceName = form.querySelector('input[name="device_name"]');
  const externalId = form.querySelector('[data-device-external-id]');
  const externalPreview = form.querySelector('[data-device-external-id-preview]');

  const rows = Array.isArray(window.deviceHierarchy) ? window.deviceHierarchy : [];
  const selected = window.deviceSelected || {};
  const text = (value) => value == null ? '' : String(value);

  const modelCatalog = model ? [...model.options].filter((o) => o.value).map((o) => o.cloneNode(true)) : [];
  const profileCatalog = profile ? [...profile.options].filter((o) => o.value).map((o) => o.cloneNode(true)) : [];
  const editFloorCatalog = !gateway && floor ? [...floor.options].filter((o) => o.value).map((o) => o.cloneNode(true)) : [];
  const editSpaceCatalog = !gateway && space ? [...space.options].filter((o) => o.value).map((o) => o.cloneNode(true)) : [];

  function generatedExternalId(value) {
    const normalized = text(value).trim().toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 100);
    return normalized || 'DEVICE';
  }

  function syncExternalId() {
    if (!externalId || !deviceName) return;
    const value = generatedExternalId(deviceName.value);
    externalId.value = value;
    if (externalPreview) externalPreview.textContent = value;
  }

  function rebuildCatalog(select, options, predicate, placeholder, selectedValue) {
    if (!select) return 0;
    const retained = selectedValue || select.value;
    select.replaceChildren();
    const blank = document.createElement('option');
    blank.value = '';
    blank.textContent = placeholder;
    select.append(blank);
    let count = 0;
    for (const source of options) {
      if (!predicate(source)) continue;
      select.append(source.cloneNode(true));
      count += 1;
    }
    if ([...select.options].some((option) => option.value === retained)) select.value = retained;
    else select.value = '';
    return count;
  }

  function filterCatalogs({ preserve = true } = {}) {
    const categoryId = text(category?.value);
    const selectedModel = preserve ? text(model?.value) : '';
    const selectedProfile = preserve ? text(profile?.value) : '';

    const modelCount = rebuildCatalog(
      model,
      modelCatalog,
      (option) => Boolean(categoryId) && text(option.dataset.category) === categoryId,
      categoryId ? 'Select compatible model' : 'Select a category first',
      selectedModel,
    );
    const profileCount = rebuildCatalog(
      profile,
      profileCatalog,
      (option) => {
        const categories = text(option.dataset.categories).split(',').map((v) => v.trim()).filter(Boolean);
        return Boolean(categoryId) && categories.includes(categoryId);
      },
      categoryId ? 'Select compatible profile' : 'Select a category first',
      selectedProfile,
    );

    if (modelEmpty) modelEmpty.hidden = !categoryId || modelCount > 0;
    if (profileEmpty) profileEmpty.hidden = !categoryId || profileCount > 0;
    if (manufacturer) manufacturer.value = model?.selectedOptions[0]?.dataset.vendor || '';
  }

  const uniqueBy = (items, key) => {
    const seen = new Set();
    return items.filter((item) => {
      const value = text(item[key]);
      if (!value || seen.has(value)) return false;
      seen.add(value);
      return true;
    });
  };

  function optionLabel(row, level) {
    const site = [row.site_name, row.site_code && `(${row.site_code})`].filter(Boolean).join(' ');
    const buildingPart = [row.building_name, row.building_code && `(${row.building_code})`].filter(Boolean).join(' ');
    const floorPart = [row.floor_name, row.floor_code && `(${row.floor_code})`].filter(Boolean).join(' ');
    const spacePart = [row.space_name, row.space_code && `(${row.space_code})`].filter(Boolean).join(' ');
    if (level === 'building') return [site, buildingPart].filter(Boolean).join(' / ');
    if (level === 'floor') return [site, buildingPart, floorPart].filter(Boolean).join(' / ');
    return [site, buildingPart, floorPart, spacePart].filter(Boolean).join(' / ');
  }

  function fillSelect(select, placeholder, items, valueKey, labelLevel, selectedValue) {
    if (!select) return;
    select.replaceChildren();
    const blank = document.createElement('option');
    blank.value = '';
    blank.textContent = placeholder;
    select.append(blank);
    for (const row of items) {
      const option = document.createElement('option');
      option.value = text(row[valueKey]);
      option.textContent = optionLabel(row, labelLevel);
      select.append(option);
    }
    if ([...select.options].some((option) => option.value === text(selectedValue))) select.value = text(selectedValue);
  }

  function rowsForGatewaySite() {
    const siteId = text(gateway?.selectedOptions[0]?.dataset.site);
    return rows.filter((row) => text(row.site_id) === siteId);
  }

  function rebuildBuildings({ preserve = true } = {}) {
    const siteRows = rowsForGatewaySite();
    const desired = preserve ? (building?.value || building?.dataset.selectedValue || selected.building_id || '') : '';
    fillSelect(building, 'Site level', uniqueBy(siteRows, 'building_id'), 'building_id', 'building', desired);
    rebuildFloors({ preserve });
  }

  function rebuildFloors({ preserve = true } = {}) {
    const buildingId = text(building?.value);
    const items = uniqueBy(rowsForGatewaySite().filter((row) => text(row.building_id) === buildingId), 'floor_id');
    const desired = preserve ? (floor?.value || floor?.dataset.selectedValue || selected.floor_id || '') : '';
    fillSelect(floor, 'No floor', items, 'floor_id', 'floor', desired);
    rebuildSpaces({ preserve });
  }

  function rebuildSpaces({ preserve = true } = {}) {
    const floorId = text(floor?.value);
    const items = uniqueBy(rowsForGatewaySite().filter((row) => text(row.floor_id) === floorId), 'space_id');
    const desired = preserve ? (space?.value || space?.dataset.selectedValue || selected.space_id || '') : '';
    fillSelect(space, 'No space', items, 'space_id', 'space', desired);
    updateLocationSummary();
  }

  function updateLocationSummary() {
    if (!locationSummary) return;
    const gatewayOption = gateway?.selectedOptions[0];
    if (!gatewayOption?.value) {
      locationSummary.textContent = 'Select a gateway to view location context.';
      return;
    }
    const gatewayPath = gatewayOption.dataset.locationPath || 'Site level';
    if (inherit?.checked) {
      locationSummary.textContent = `Effective location: ${gatewayPath} (inherited from gateway).`;
      return;
    }
    const explicit = space?.selectedOptions[0]?.value ? space.selectedOptions[0].textContent
      : floor?.selectedOptions[0]?.value ? floor.selectedOptions[0].textContent
      : building?.selectedOptions[0]?.value ? building.selectedOptions[0].textContent
      : `Site level · ${gatewayOption.textContent}`;
    locationSummary.textContent = `Effective location: ${explicit}.`;
  }


  function rebuildEditFloors({ preserve = true } = {}) {
    const desired = preserve ? (floor?.value || floor?.dataset.selectedValue || '') : '';
    rebuildCatalog(
      floor,
      editFloorCatalog,
      (option) => text(option.dataset.building) === text(building?.value),
      'No floor',
      desired,
    );
    rebuildEditSpaces({ preserve });
  }

  function rebuildEditSpaces({ preserve = true } = {}) {
    const desired = preserve ? (space?.value || space?.dataset.selectedValue || '') : '';
    rebuildCatalog(
      space,
      editSpaceCatalog,
      (option) => text(option.dataset.floor) === text(floor?.value),
      'No space',
      desired,
    );
  }

  function updateLocationMode() {
    const disabled = Boolean(inherit?.checked);
    for (const select of [building, floor, space]) {
      if (!select) continue;
      select.disabled = disabled;
      select.setAttribute('aria-disabled', disabled ? 'true' : 'false');
    }
    updateLocationSummary();
  }

  function updateGatewayContext() {
    const option = gateway?.selectedOptions[0];
    if (gatewayContext) gatewayContext.textContent = option?.value ? `Selected gateway context: ${option.textContent}.` : 'Select a gateway to load its site and physical-location hierarchy.';
  }

  deviceName?.addEventListener('input', syncExternalId);
  category?.addEventListener('change', () => filterCatalogs({ preserve: false }));
  model?.addEventListener('change', () => {
    if (manufacturer) manufacturer.value = model.selectedOptions[0]?.dataset.vendor || '';
  });
  gateway?.addEventListener('change', () => {
    if (building) building.dataset.selectedValue = '';
    if (floor) floor.dataset.selectedValue = '';
    if (space) space.dataset.selectedValue = '';
    rebuildBuildings({ preserve: false });
    updateGatewayContext();
    updateLocationMode();
  });
  building?.addEventListener('change', () => gateway ? rebuildFloors({ preserve: false }) : rebuildEditFloors({ preserve: false }));
  floor?.addEventListener('change', () => gateway ? rebuildSpaces({ preserve: false }) : rebuildEditSpaces({ preserve: false }));
  space?.addEventListener('change', updateLocationSummary);
  inherit?.addEventListener('change', updateLocationMode);

  syncExternalId();
  filterCatalogs({ preserve: true });
  if (gateway) rebuildBuildings({ preserve: true });
  else rebuildEditFloors({ preserve: true });
  updateGatewayContext();
  updateLocationMode();
})();
