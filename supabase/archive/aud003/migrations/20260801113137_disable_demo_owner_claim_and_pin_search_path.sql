-- This historical migration was first recorded in production before the
-- repository was connected to Supabase Branching. Keep the intended hardening
-- replay-safe: a fresh database may encounter this version before the legacy
-- helper functions have been materialized.
do $migration$
begin
  if to_regprocedure('public.claim_demo_owner()') is not null then
    execute 'revoke execute on function public.claim_demo_owner() from authenticated';
  end if;
  if to_regprocedure(
      'public.shift_minutes(timestamp with time zone,timestamp with time zone)'
    ) is not null then
    execute $sql$
      alter function public.shift_minutes(
        timestamp with time zone,timestamp with time zone
      ) set search_path = ''
    $sql$;
  end if;
end;
$migration$;
