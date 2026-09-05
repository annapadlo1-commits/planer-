import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { buildBaseline, formatRoutineDefinition } from '../scripts/aud003/build-baseline.mjs';

function decodeEscapedBody(sql) {
 const match = /\bAS E'([\s\S]*)'$/u.exec(sql);
 assert.ok(match, 'Expected escape-string body');
 let out = '';
 for(let i=0; i<match[1].length; i++) {
  const c=match[1][i];
  if(c==="'") { assert.equal(match[1][++i], "'"); out+="'"; }
  else if(c==='\\') { const next=match[1][++i]; assert.ok(['\\','r'].includes(next)); out+=next==='r'?'\r':'\\'; }
  else out+=c;
 }
 return out;
}

test('MRG-RVW-04 generated SQL has LF without altering captured routine bodies', async () => {
 const capture = JSON.parse(await readFile(new URL('../supabase/baseline/aud003/uat-catalog-2026-09-03.json', import.meta.url), 'utf8'));
 const before = JSON.stringify(capture);
 const sql = buildBaseline(capture);
 assert.equal(sql.includes('\r'), false, 'Generated SQL must encode CR rather than retain raw CR bytes');
 assert.equal(JSON.stringify(capture), before, 'Captured source must remain unchanged');
 let changed=0;
 for(const routine of capture.routines) {
  const original=routine.definition.trimEnd(), formatted=formatRoutineDefinition(original);
  if(original.includes('\r')) {
   const body=/\bAS (\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$)([\s\S]*)\1$/u.exec(original);
   assert.ok(body);
   assert.deepEqual(Buffer.from(decodeEscapedBody(formatted)), Buffer.from(body[2]));
   changed++;
  } else assert.equal(formatted, original);
 }
 assert.ok(changed>0, 'Real CR-bearing routines must be exercised');
});

test('MRG-RVW-04 preserves quotes, backslashes, CR literals and nested dollar tokens exactly', () => {
 for(const delimiter of ['$function$','$$','$custom_1$']) {
  const nested=delimiter==='$$'?'$inner$':'$$';
  const body=`\r\nBEGIN\r\n RETURN 'Zażółć''\r\ngęślą' || E'\\\\r' || ${nested}tekst${nested}; -- '\\\r\nEND;\r\n`;
  const original=`CREATE OR REPLACE FUNCTION public.probe() RETURNS text LANGUAGE plpgsql\n AS ${delimiter}${body}${delimiter}\n`;
  const formatted=formatRoutineDefinition(original);
  assert.equal(formatted.includes('\r'), false);
  assert.equal(decodeEscapedBody(formatted), body);
 }
});

test('MRG-RVW-04 refuses unexpected CR outside a recognized routine body', () => {
 assert.throws(()=>formatRoutineDefinition("CREATE FUNCTION public.f() RETURNS text\r\n AS $function$abc\r\n$function$"), /CR_OUTSIDE_ROUTINE_BODY/u);
 assert.throws(()=>formatRoutineDefinition("CREATE FUNCTION public.f() RETURNS text AS 'abc\r\ndef'"), /CR_ROUTINE_REQUIRES_DOLLAR_QUOTED_BODY/u);
 assert.throws(()=>formatRoutineDefinition("CREATE FUNCTION public.f() RETURNS text AS $$abc$$def\r\n$$"), /AMBIGUOUS_ROUTINE_BODY_DELIMITER/u);
});

test('MRG-RVW-04 new JSON evidence has LF and one terminal newline', async () => {
 const attributes=await readFile(new URL('../.gitattributes',import.meta.url),'utf8');
 assert.match(attributes,/^supabase\/baseline\/aud003\/uat-catalog-2026-09-03\.json text eol=lf$/mu);
 for(const file of ['supabase/archive/aud003/legacy-ledger.manifest.json','supabase/baseline/aud003/uat-catalog-2026-09-03.json']) {
  const text=await readFile(new URL('../'+file, import.meta.url),'utf8');
  assert.equal(text.includes('\r'),false,file);
  assert.match(text,/[^\n]\n$/u,file);
  assert.doesNotThrow(()=>JSON.parse(text));
 }
});
