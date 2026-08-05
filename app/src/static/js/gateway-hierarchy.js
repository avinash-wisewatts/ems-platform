(() => {
  const rows = Array.isArray(window.gatewayHierarchy) ? window.gatewayHierarchy : [];
  const selected = window.gatewaySelected || {};
  const building = document.querySelector('[data-building]');
  const floor = document.querySelector('[data-floor]');
  const space = document.querySelector('[data-space]');
  if (!building || !floor || !space) return;
  const unique = (items, idKey, nameKey) => { const seen=new Set(); return items.filter(r=>r[idKey]&&!seen.has(String(r[idKey]))&&seen.add(String(r[idKey]))).map(r=>({id:String(r[idKey]),name:r[nameKey]||String(r[idKey])})); };
  const fill = (select, items, placeholder, value) => { select.innerHTML=''; const first=document.createElement('option'); first.value=''; first.textContent=placeholder; select.appendChild(first); items.forEach(item=>{const o=document.createElement('option');o.value=item.id;o.textContent=item.name;o.selected=item.id===String(value||'');select.appendChild(o)}); };
  const refreshSpaces=()=>fill(space, unique(rows.filter(r=>String(r.floor_id||'')===floor.value),'space_id','space_name'),'No space',selected.space_id);
  const refreshFloors=()=>{fill(floor, unique(rows.filter(r=>String(r.building_id||'')===building.value),'floor_id','floor_name'),'No floor',selected.floor_id);refreshSpaces();};
  fill(building, unique(rows,'building_id','building_name'),'Site level',selected.building_id);refreshFloors();
  building.addEventListener('change',()=>{selected.floor_id='';selected.space_id='';refreshFloors();});
  floor.addEventListener('change',()=>{selected.space_id='';refreshSpaces();});
})();
