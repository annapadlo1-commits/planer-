-- Durable, server-side history for Leader Studio working copies.
-- Every completed edit stores the whole editable assignment/issue state. Undo
-- and redo restore one atomic checkpoint and then run the canonical validator.

create table if not exists solver_private.leader_variant_history_v2 (
  seq bigint generated always as identity primary key,
  variant_id uuid not null references public.plan_variants_v2(id) on delete cascade,
  revision integer not null,
  label text not null,
  snapshot jsonb not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);

create index if not exists leader_variant_history_variant_seq_v2
  on solver_private.leader_variant_history_v2(variant_id,seq);

create table if not exists solver_private.leader_variant_history_cursor_v2 (
  variant_id uuid primary key references public.plan_variants_v2(id) on delete cascade,
  current_seq bigint not null references solver_private.leader_variant_history_v2(seq) on delete cascade,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table solver_private.leader_variant_history_v2 enable row level security;
alter table solver_private.leader_variant_history_cursor_v2 enable row level security;
revoke all on solver_private.leader_variant_history_v2,
  solver_private.leader_variant_history_cursor_v2 from public,anon,authenticated;

create or replace function solver_private.leader_variant_snapshot_v2(p_variant_id uuid)
returns jsonb language sql stable security definer set search_path=''
as $$
  select jsonb_build_object(
    'assignments',coalesce((select jsonb_agg(to_jsonb(a) order by a.id)
      from public.plan_assignments_v2 a where a.variant_id=p_variant_id),'[]'::jsonb),
    'duties',coalesce((select jsonb_agg(to_jsonb(d) order by d.assignment_id,d.duty_id)
      from public.plan_assignment_duties_v2 d
      join public.plan_assignments_v2 a on a.id=d.assignment_id
      where a.variant_id=p_variant_id),'[]'::jsonb),
    'issues',coalesce((select jsonb_agg(to_jsonb(i) order by i.id)
      from public.plan_issues_v2 i where i.variant_id=p_variant_id),'[]'::jsonb)
  );
$$;

create or replace function solver_private.record_leader_variant_history_v2(
  p_variant_id uuid,p_revision integer,p_label text,p_actor uuid
) returns bigint language plpgsql security definer set search_path=''
as $$
declare v_cursor bigint; v_seq bigint;
begin
  select current_seq into v_cursor
  from solver_private.leader_variant_history_cursor_v2 where variant_id=p_variant_id for update;
  if v_cursor is not null then
    delete from solver_private.leader_variant_history_v2
      where variant_id=p_variant_id and seq>v_cursor;
  end if;
  insert into solver_private.leader_variant_history_v2(variant_id,revision,label,snapshot,created_by)
  values(p_variant_id,p_revision,left(coalesce(nullif(trim(p_label),''),'Zmiana w Studio'),240),
    solver_private.leader_variant_snapshot_v2(p_variant_id),p_actor)
  returning seq into v_seq;
  insert into solver_private.leader_variant_history_cursor_v2(variant_id,current_seq,updated_by)
  values(p_variant_id,v_seq,p_actor)
  on conflict(variant_id) do update set current_seq=excluded.current_seq,
    updated_at=now(),updated_by=excluded.updated_by;
  return v_seq;
end;
$$;

create or replace function solver_private.capture_leader_variant_history_v2()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if new.variant_kind<>'LEADER_COPY'
    or coalesce(current_setting('solver_private.history_restore',true),'')='on' then return new; end if;
  if tg_op='INSERT' then
    if not exists(select 1 from solver_private.leader_variant_history_v2 where variant_id=new.id) then
      perform solver_private.record_leader_variant_history_v2(new.id,new.revision,'Punkt startowy',new.last_edited_by);
    end if;
  elsif new.revision is distinct from old.revision then
    perform solver_private.record_leader_variant_history_v2(new.id,new.revision,'Rewizja '||new.revision,new.last_edited_by);
  end if;
  return new;
end;
$$;

drop trigger if exists capture_leader_variant_initial_history_v2 on public.plan_variants_v2;
create constraint trigger capture_leader_variant_initial_history_v2
after insert on public.plan_variants_v2 deferrable initially deferred
for each row execute function solver_private.capture_leader_variant_history_v2();

drop trigger if exists capture_leader_variant_revision_history_v2 on public.plan_variants_v2;
create trigger capture_leader_variant_revision_history_v2
after update of revision on public.plan_variants_v2
for each row execute function solver_private.capture_leader_variant_history_v2();

create or replace function public.optimizer_leader_history_status_uat_v1(p_variant_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_cursor bigint;
begin
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  select current_seq into v_cursor from solver_private.leader_variant_history_cursor_v2
    where variant_id=p_variant_id;
  return jsonb_build_object(
    'canUndo',exists(select 1 from solver_private.leader_variant_history_v2 where variant_id=p_variant_id and seq<v_cursor),
    'canRedo',exists(select 1 from solver_private.leader_variant_history_v2 where variant_id=p_variant_id and seq>v_cursor),
    'entries',coalesce((select jsonb_agg(jsonb_build_object('seq',h.seq,'revision',h.revision,
      'label',h.label,'createdAt',h.created_at,'current',h.seq=v_cursor) order by h.seq desc)
      from solver_private.leader_variant_history_v2 h where h.variant_id=p_variant_id),'[]'::jsonb)
  );
end;
$$;

create or replace function public.optimizer_leader_history_move_uat_v1(
  p_variant_id uuid,p_direction text
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_cursor bigint; v_target solver_private.leader_variant_history_v2%rowtype;
  v_result jsonb;
begin
  if p_direction not in ('UNDO','REDO') then raise exception 'INVALID_HISTORY_DIRECTION'; end if;
  if not solver_private.can_edit_leader_variant_uat_v1(p_variant_id) then
    raise exception 'LEADER_VARIANT_NOT_EDITABLE';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('leader-edit:'||p_variant_id::text,0));
  select current_seq into v_cursor from solver_private.leader_variant_history_cursor_v2
    where variant_id=p_variant_id for update;
  if p_direction='UNDO' then
    select * into v_target from solver_private.leader_variant_history_v2
      where variant_id=p_variant_id and seq<v_cursor order by seq desc limit 1;
  else
    select * into v_target from solver_private.leader_variant_history_v2
      where variant_id=p_variant_id and seq>v_cursor order by seq limit 1;
  end if;
  if v_target.seq is null then raise exception 'HISTORY_STEP_NOT_AVAILABLE'; end if;
  perform set_config('solver_private.history_restore','on',true);
  delete from public.plan_assignments_v2 where variant_id=p_variant_id;
  delete from public.plan_issues_v2 where variant_id=p_variant_id;
  insert into public.plan_assignments_v2(id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at)
  select id,variant_id,shift_id,slot_key,employee_id,role_id,locked,explanation,created_at
  from jsonb_populate_recordset(null::public.plan_assignments_v2,v_target.snapshot->'assignments');
  insert into public.plan_assignment_duties_v2(assignment_id,duty_id)
  select assignment_id,duty_id
  from jsonb_populate_recordset(null::public.plan_assignment_duties_v2,v_target.snapshot->'duties');
  insert into public.plan_issues_v2(id,variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at)
  select id,variant_id,shift_id,slot_key,issue_code,severity,role_id,duty_id,
    required_count,assigned_count,message,metadata,created_at
  from jsonb_populate_recordset(null::public.plan_issues_v2,v_target.snapshot->'issues');
  v_result:=solver_private.refresh_leader_variant_uat_v1(p_variant_id,v_actor,
    case when p_direction='UNDO' then 'Cofnięcie operacji' else 'Ponowienie operacji' end);
  update solver_private.leader_variant_history_cursor_v2 set current_seq=v_target.seq,
    updated_at=now(),updated_by=v_actor where variant_id=p_variant_id;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'plan_variant_v2',p_variant_id::text,'LEADER_HISTORY_'||p_direction,
    jsonb_build_object('historySeq',v_target.seq,'historyRevision',v_target.revision));
  return v_result||jsonb_build_object('historySeq',v_target.seq,'direction',p_direction);
end;
$$;

revoke all on function solver_private.leader_variant_snapshot_v2(uuid),
  solver_private.record_leader_variant_history_v2(uuid,integer,text,uuid),
  solver_private.capture_leader_variant_history_v2() from public,anon,authenticated;
revoke all on function public.optimizer_leader_history_status_uat_v1(uuid),
  public.optimizer_leader_history_move_uat_v1(uuid,text) from public,anon,authenticated;
grant execute on function public.optimizer_leader_history_status_uat_v1(uuid),
  public.optimizer_leader_history_move_uat_v1(uuid,text) to authenticated;
