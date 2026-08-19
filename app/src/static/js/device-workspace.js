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

  const text = (value) => value == null ? '' : String(value);

  const modelCatalog = model ? [...model.options].filter((o) => o.value).map((o) => o.cloneNode(true)) : [];
  const profileCatalog = profile ? [...profile.options].filter((o) => o.value).map((o) => o.cloneNode(true)) : [];

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

  // Building/Floor/Space population and cascading is owned by
  // location-picker.js (see [data-physical-location-selector] on the
  // Installation section of this form). This script only reflects the
  // current selection into the human-readable summary line and enforces
  // the "inherit from gateway" disabled state -- it must run *after*
  // location-picker.js so the selects are already populated. Keep the
  // <script src=".../location-picker.js"> tag before this one in the
  // template.

  function updateLocationSummary() {
    if (!locationSummary) return;
    const gatewayOption = gateway?.selectedOptions[0];
    if (gateway && !gatewayOption?.value) {
      locationSummary.textContent = 'Select a gateway to view location context.';
      return;
    }
    const gatewayPath = gatewayOption?.dataset.locationPath || 'Site level';
    if (inherit?.checked) {
      locationSummary.textContent = `Effective location: ${gatewayPath} (inherited from gateway).`;
      return;
    }
    const explicit = space?.selectedOptions[0]?.value ? space.selectedOptions[0].textContent
      : floor?.selectedOptions[0]?.value ? floor.selectedOptions[0].textContent
      : building?.selectedOptions[0]?.value ? building.selectedOptions[0].textContent
      : gatewayOption ? `Site level · ${gatewayOption.textContent}` : 'Site level';
    locationSummary.textContent = `Effective location: ${explicit}.`;
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
    updateGatewayContext();
    updateLocationMode();
  });
  building?.addEventListener('change', updateLocationSummary);
  floor?.addEventListener('change', updateLocationSummary);
  space?.addEventListener('change', updateLocationSummary);
  inherit?.addEventListener('change', updateLocationMode);

  syncExternalId();
  filterCatalogs({ preserve: true });
  updateGatewayContext();
  updateLocationMode();
})();
