import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { QUICK_WORKBOOK_SHEETS, quickWorkbookContractErrors } from "../lib/workbook-contract.ts";

test("every field in the simple workbook has complete user guidance",()=>{
  for(const [sheet,definition] of Object.entries(QUICK_WORKBOOK_SHEETS)){
    assert.ok(definition.purpose.length>20,`${sheet}: purpose`);
    assert.ok(definition.when.length>20,`${sheet}: when`);
    for(const field of definition.headers){
      const doc=definition.fields[field];
      assert.ok(doc,`${sheet}.${field}: missing definition`);
      for(const key of ["purpose","input","allowed","example","effect","blank","application"]){
        assert.ok(String(doc[key]??"").trim(),`${sheet}.${field}.${key}`);
      }
      assert.doesNotMatch(`${doc.purpose} ${doc.input} ${doc.blank}`,/zgodnie z celem zakładki|dane rozszerzające konfigurację/i);
    }
  }
});

test("simple workbook contract contains no normalized duplicate employee sheets",()=>{
  const headers=Object.fromEntries(Object.entries(QUICK_WORKBOOK_SHEETS).map(([sheet,definition])=>[sheet,[...definition.headers]]));
  assert.deepEqual(quickWorkbookContractErrors(headers),[]);
  for(const forbidden of ["Role pracowników","Lokale pracowników","Kompetencje pracowników","Finanse pracowników","Scenariusze","Strategie","Kryteria strategii","Warianty scenariuszy"]){
    assert.equal(forbidden in QUICK_WORKBOOK_SHEETS,false,forbidden);
  }
  assert.ok(QUICK_WORKBOOK_SHEETS.Pracownicy.headers.includes("Rola podstawowa"));
  assert.ok(QUICK_WORKBOOK_SHEETS.Pracownicy.headers.includes("Rola dodatkowa 1"));
  assert.equal(QUICK_WORKBOOK_SHEETS.Pracownicy.headers.includes("Sposób użycia"),false);
});

test("frontend and importer enforce the same additional-role rule",async()=>{
  const [editor,parser]=await Promise.all([
    readFile(new URL("../components/MatrixV2Editor.tsx",import.meta.url),"utf8"),
    readFile(new URL("../lib/matrix-workbook-import.ts",import.meta.url),"utf8"),
  ]);
  assert.match(editor,/assignmentMode:isPrimary\?"STANDARD":"BACKUP"/);
  assert.doesNotMatch(editor,/standardowa dodatkowa/);
  assert.doesNotMatch(editor,/Sposób użycia roli<select/);
  assert.match(parser,/assignmentMode:isPrimary\?"STANDARD":"BACKUP"/);
});

test("solver snapshot never converts a capability into an employee role",async()=>{
  const migration=await readFile(new URL("../supabase/migrations/20260816183000_explicit_employee_roles_only_uat.sql",import.meta.url),"utf8");
  assert.match(migration,/where not \(grant_row\.value \? 'sourceDutyId'\)/);
  assert.match(migration,/jsonb_array_length\(v_grants\) > 0/);
  assert.match(migration,/role eligibility comes only from explicit employee role grants/i);
  assert.doesNotMatch(migration,/join public\.matrix_duties_v2/u);
});
