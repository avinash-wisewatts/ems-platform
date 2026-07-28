(() => {
  const category=document.querySelector('[name="device_category_id"]');
  const model=document.querySelector('[name="device_model_id"]');
  const profile=document.querySelector('[name="profile_id"]');
  if(!category||!model||!profile)return;
  function filter(){const id=category.value;
    for(const o of model.options){if(!o.value)continue;o.hidden=!!id&&o.dataset.category!==id;}
    for(const o of profile.options){if(!o.value)continue;const ids=(o.dataset.categories||'').split(',');o.hidden=!!id&&!ids.includes(id);}
    if(model.selectedOptions[0]?.hidden)model.value=''; if(profile.selectedOptions[0]?.hidden)profile.value='';
  }
  category.addEventListener('change',filter); filter();
})();
