-- Snapshot slot identifiers must use the same empty-duty sentinel as worker.

begin;

do $$
declare
  v_definition text;
  v_slot_definition text;
begin
  v_definition:=pg_get_functiondef(
    'solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)'::regprocedure
  );
  v_slot_definition:=pg_get_functiondef(
    'solver_private.build_snapshot_payload_before_final_contract_v2(uuid,date,uuid,uuid,text,uuid)'::regprocedure
  );
  if position('build_snapshot_payload_before_final_contract_v2' in v_definition)=0
    or position('''-''' in v_slot_definition)=0
    or position('{slotId}' in v_slot_definition)=0
    or position('DUPLICATE_CANONICAL_SLOT_ID' in v_slot_definition)=0 then
    raise exception 'CANONICAL_SLOT_CONTRACT_NOT_ENFORCED';
  end if;
end;
$$;

do $$
declare
  v_snapshot_definition text;
  v_validator_definition text;
begin
  v_snapshot_definition:=pg_get_functiondef(
    'solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)'::regprocedure
  );
  v_validator_definition:=pg_get_functiondef(
    'solver_private.validate_variant_v2(jsonb,jsonb)'::regprocedure
  );
  if position('workTimePolicy' in v_snapshot_definition)=0
    or position('maximumMonthlyMinutes' in v_snapshot_definition)=0
    or position('minimumRestMinutes' in v_snapshot_definition)=0
    or position('build_snapshot_payload_before_final_contract_v2' in v_snapshot_definition)=0
    or position('validate_variant_before_final_contract_v2' in v_validator_definition)=0
    or position('2147483647' in v_validator_definition)=0 then
    raise exception 'FINAL_CONTRACT_SEMANTICS_NOT_ENFORCED';
  end if;
end;
$$;

rollback;
