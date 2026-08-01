update public.optimizer_profiles
set code='PREFERENCES',name='Preferencje i równy podział'
where code='FAIR'
  and not exists(select 1 from public.optimizer_profiles p2 where p2.matrix_version_id=optimizer_profiles.matrix_version_id and p2.code='PREFERENCES');
