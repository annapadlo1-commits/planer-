import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";

import {
  solverErrorMessage,
  validateLeaderDraft,
} from "../lib/solver-v2.ts";

function defaultWorkloadEmployees(){
  return [
    {employeeId:"employee-1",totalMonthlyMinutes:0,nominalMonthlyMinutes:9600,overtimeMinutes:0,preferenceViolations:2},
    {employeeId:"employee-2",totalMonthlyMinutes:4800,nominalMonthlyMinutes:9600,overtimeMinutes:120,preferenceViolations:1},
    {employeeId:"employee-3",totalMonthlyMinutes:10000,nominalMonthlyMinutes:9600,overtimeMinutes:400,preferenceViolations:0},
  ];
}

function draftValidationClient(options={}){
  const {
    validationRevision=7,
    workloadRevision=7,
    workloadVariantId="variant-1",
    workloadEmployees=defaultWorkloadEmployees(),
  }=options;
  const calls=[];
  return {
    calls,
    rpc:async(name,args)=>{
      calls.push({name,args});
      if(name==="optimizer_leader_draft_validate_uat_v1")return {data:{
        variantId:"variant-1",
        revision:validationRevision,
        valid:true,
        validation:{hardViolations:0,unfilledCount:2,assignmentCount:11},
      },error:null};
      if(name==="optimizer_variant_workload_distribution_uat_v1")return {data:Object.hasOwn(options,"workloadPayload")
        ?options.workloadPayload
        :{variantId:workloadVariantId,revision:workloadRevision,employees:workloadEmployees},error:null};
      throw new Error(`Unexpected RPC ${name}`);
    },
  };
}

test("whole leader-draft validation combines hard rules with the exact workload revision",async()=>{
  const client=draftValidationClient();
  const result=await validateLeaderDraft(client,"variant-1");

  assert.deepEqual(client.calls.map(call=>call.name).sort(),[
    "optimizer_leader_draft_validate_uat_v1",
    "optimizer_variant_workload_distribution_uat_v1",
  ]);
  assert.deepEqual(client.calls.map(call=>call.args),[
    {p_variant_id:"variant-1"},
    {p_variant_id:"variant-1"},
  ]);
  assert.deepEqual(result,{
    variantId:"variant-1",
    revision:7,
    workloadRevision:7,
    valid:true,
    hardViolations:0,
    unfilledCount:2,
    assignmentCount:11,
    zeroHoursCount:1,
    belowTargetCount:2,
    overtimeMinutes:520,
    preferenceViolations:3,
  });
});

test("whole leader-draft validation fails closed when the workload belongs to another revision",async()=>{
  const client=draftValidationClient({validationRevision:7,workloadRevision:8});

  await assert.rejects(
    validateLeaderDraft(client,"variant-1"),
    /LEADER_DRAFT_VALIDATION_REVISION_MISMATCH:7:8/,
  );
  assert.match(
    solverErrorMessage("LEADER_DRAFT_VALIDATION_REVISION_MISMATCH:7:8"),
    /Szkic zmienił się podczas kontroli całego grafiku/,
  );
});

test("an empty workload roster still carries and verifies its authoritative revision",async()=>{
  const result=await validateLeaderDraft(
    draftValidationClient({workloadEmployees:[]}),
    "variant-1",
  );

  assert.equal(result.revision,7);
  assert.equal(result.workloadRevision,7);
  assert.equal(result.zeroHoursCount,0);
  assert.equal(result.belowTargetCount,0);
  assert.equal(result.overtimeMinutes,0);
  assert.equal(result.preferenceViolations,0);
});

test("whole-draft zero-hour count excludes employees without a monthly target",async()=>{
  const result=await validateLeaderDraft(draftValidationClient({workloadEmployees:[
    {employeeId:"targetless",totalMonthlyMinutes:0,nominalMonthlyMinutes:0,overtimeMinutes:0,preferenceViolations:0},
    {employeeId:"with-target",totalMonthlyMinutes:0,nominalMonthlyMinutes:9600,overtimeMinutes:0,preferenceViolations:0},
  ]}),"variant-1");

  assert.equal(result.zeroHoursCount,1);
  assert.equal(result.belowTargetCount,1);
});

test("an empty workload roster cannot conceal a revision race",async()=>{
  await assert.rejects(
    validateLeaderDraft(
      draftValidationClient({workloadRevision:8,workloadEmployees:[]}),
      "variant-1",
    ),
    /LEADER_DRAFT_VALIDATION_REVISION_MISMATCH:7:8/,
  );
});

test("whole-draft validation fails closed for malformed workload envelopes",async()=>{
  for(const [label,workloadPayload,error] of [
    ["missing employees",{variantId:"variant-1",revision:7},/WORKLOAD_EMPLOYEES_INVALID/],
    ["missing revision",{variantId:"variant-1",employees:[]},/WORKLOAD_REVISION_INVALID/],
    ["malformed revision",{variantId:"variant-1",revision:"not-a-revision",employees:[]},/WORKLOAD_REVISION_INVALID/],
    ["wrong variant",{variantId:"variant-2",revision:7,employees:[]},/WORKLOAD_VARIANT_MISMATCH:variant-1:variant-2/],
  ]){
    await assert.rejects(
      validateLeaderDraft(draftValidationClient({workloadPayload}),"variant-1"),
      error,
      label,
    );
  }
});

test("unproven zero-hour and role guards explain the fail-closed result without blaming audit mode",()=>{
  const expectations=[
    ["ROLE_BACKUP_PENALTY_UNPROVEN",/roli dodatkowej.*konieczne/is],
    ["PRIMARY_ROLE_GUARD_UNPROVEN",/roli podstawowej lub standardowej.*nieunikniony/is],
    ["ZERO_HOUR_GUARD_UNPROVEN",/0 h.*nieuniknione/is],
  ];
  for(const [code,expected] of expectations){
    const message=solverErrorMessage(code);
    assert.match(message,expected);
    assert.match(message,/Ponów generowanie albo zwiększ czas obliczeń/);
    assert.doesNotMatch(message,/tryb audytowy/i);
  }
});

test("the Studio report is bound to the current variant and revision and every edit invalidates it",async()=>{
  const panel=await readFile(new URL("../components/SolverV2Panel.tsx",import.meta.url),"utf8");

  assert.match(panel,/leaderDraftValidation\?\.variantId===leaderVariant\.id/);
  assert.match(panel,/leaderDraftValidation\.revision===leaderVariant\.revision/);
  for(const field of [
    "hardViolations","unfilledCount","assignmentCount","zeroHoursCount","belowTargetCount",
    "overtimeMinutes","preferenceViolations",
  ])assert.match(panel,new RegExp(`leaderDraftValidation\\.${field}`));
  assert.match(panel,/Wakaty i ostrzeżenia miękkie są jawne w raporcie, ale zgodnie z kontraktem nie blokują przekazania/);
  assert.match(panel,/const studioBusy=busy\|\|leaderWorkspaceBusy/);
  assert.match(panel,/if\(nextBusy\)setLeaderDraftValidation\(null\)/);
  assert.match(panel,/onLeaderBusyChange=\{handleLeaderWorkspaceBusyChange\}/);
  assert.match(panel,/disabled=\{studioBusy\} onClick=\{\(\)=>void checkLeaderDraft\(\)\}/);
  assert.match(panel,/disabled=\{studioBusy\|\|!leaderDraftValidationCurrent\|\|!leaderDraftValidation\?\.valid\}/);
  const closeLeaderStudio=panel.slice(panel.indexOf('aria-label="Zamknij Studio lidera"'),panel.indexOf('aria-label="Zamknij Studio lidera"')+1200);
  assert.match(closeLeaderStudio,/setLeaderWorkspaceBusy\(false\);setLeaderStudioOpen\(false\)/);
  assert.doesNotMatch(closeLeaderStudio,/setLeaderVariant\(null\)/,
    "zamknięcie Studia nie może zgubić dokładnej wersji lidera przeznaczonej do publikacji");
});
