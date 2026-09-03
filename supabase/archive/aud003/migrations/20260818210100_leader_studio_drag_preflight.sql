create or replace function public.optimizer_leader_assignment_drag_preview_uat_v1(
  p_variant_id uuid,
  p_source_assignment_id uuid,
  p_target_assignment_id uuid default null,
  p_target_issue_id bigint default null
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_result jsonb;
  v_detail text;
  v_error text;
begin
  begin
    v_result:=public.optimizer_leader_assignment_drag_uat_v1(
      p_variant_id,
      p_source_assignment_id,
      p_target_assignment_id,
      p_target_issue_id,
      'Niemutująca kontrola przeciągnięcia w Studio lidera'
    );
    raise exception 'LEADER_DRAG_PREVIEW_ROLLBACK' using detail=v_result::text;
  exception when others then
    get stacked diagnostics v_error=message_text,v_detail=pg_exception_detail;
    if v_error='LEADER_DRAG_PREVIEW_ROLLBACK' then
      return coalesce(v_detail,'{}')::jsonb||jsonb_build_object('valid',true);
    end if;
    return jsonb_build_object('valid',false,'errorCode',v_error);
  end;
end;
$$;

revoke all on function public.optimizer_leader_assignment_drag_preview_uat_v1(uuid,uuid,uuid,bigint)
  from public,anon,authenticated;
grant execute on function public.optimizer_leader_assignment_drag_preview_uat_v1(uuid,uuid,uuid,bigint)
  to authenticated;
