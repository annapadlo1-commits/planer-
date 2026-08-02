-- Attach publication-state tables created by optimizer_publication_v2 to the
-- same planning revision boundary established before solver API creation.

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'published_schedules_v2',
    'published_schedule_variants_v2'
  ]
  loop
    if to_regclass(format('public.%I',v_table)) is null then
      raise exception 'PLANNING_REVISION_TABLE_MISSING: %',v_table;
    end if;
    execute format(
      'drop trigger if exists planning_revision_v2_bump on public.%I',v_table
    );
    execute format(
      'create trigger planning_revision_v2_bump '
      'before insert or update or delete or truncate on public.%I '
      'for each statement execute function solver_private.bump_planning_revision_v2()',
      v_table
    );
  end loop;
end;
$$;

comment on table public.published_schedules_v2 is
  'Immutable authoritative schedule headers; mutations advance the global planning-data revision.';
