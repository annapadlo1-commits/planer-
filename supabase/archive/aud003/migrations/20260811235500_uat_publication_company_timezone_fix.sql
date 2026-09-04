-- UAT publication must compare the requested activation date with the
-- company's local calendar day, not with the UTC date of the database session.
-- The legacy publisher remains the single validation and activation boundary;
-- this wrapper only establishes the validated company timezone for its call.

create or replace function public.matrix_v2_publish_draft_uat_v2(
  p_effective_from date default null
) returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_timezone text;
  v_effective_from date;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;

  select coalesce(nullif(version.settings->>'timezone',''),'UTC')
    into v_timezone
  from public.matrix_versions version
  where version.status='DRAFT' and version.schema_version>=2
  order by version.version desc
  limit 1;
  if v_timezone is null then raise exception 'NO_MATRIX_V2_DRAFT'; end if;
  if not exists(
    select 1 from pg_catalog.pg_timezone_names timezone_row
    where timezone_row.name=v_timezone
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;

  perform pg_catalog.set_config('TimeZone',v_timezone,true);
  v_effective_from:=coalesce(
    p_effective_from,
    (pg_catalog.clock_timestamp() at time zone v_timezone)::date
  );
  return public.matrix_v2_publish_draft(v_effective_from);
end;
$$;

revoke all on function public.matrix_v2_publish_draft_uat_v2(date)
from public,anon,authenticated;
grant execute on function public.matrix_v2_publish_draft_uat_v2(date)
to authenticated;

notify pgrst,'reload schema';
