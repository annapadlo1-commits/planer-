-- Snapshot slot identifiers must use the same empty-duty sentinel as worker.

begin;

do $$
declare
  v_definition text;
begin
  v_definition:=pg_get_functiondef(
    'solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)'::regprocedure
  );
  if position('''-''' in v_definition)=0
    or position('{slotId}' in v_definition)=0
    or position('DUPLICATE_CANONICAL_SLOT_ID' in v_definition)=0
    or position('build_snapshot_payload_before_slot_contract_fix_v2' in v_definition)=0 then
    raise exception 'CANONICAL_SLOT_CONTRACT_NOT_ENFORCED';
  end if;
end;
$$;

rollback;
