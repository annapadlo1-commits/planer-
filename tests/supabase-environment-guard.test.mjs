import test from "node:test";
import assert from "node:assert/strict";
import { evaluateSupabaseEnvironment } from "../lib/supabase/client.ts";

const UAT_URL = "https://nhthrtpkfpmufmrmdyjg.supabase.co";
const PRODUCTION_URL = "https://bdybebzvzapihjdauehg.supabase.co";
const FOREIGN_URL = "https://foreignprojectref.supabase.co";

test("Vercel Preview fails closed when it receives the production Supabase project", () => {
  const result = evaluateSupabaseEnvironment(PRODUCTION_URL, "preview");
  assert.equal(result.allowed, false);
  assert.equal(result.projectRef, "bdybebzvzapihjdauehg");
  assert.match(result.message, /bezpiecznie zablokowany/i);
});

test("Vercel Preview accepts the designated UAT Supabase project", () => {
  const result = evaluateSupabaseEnvironment(UAT_URL, "preview");
  assert.equal(result.allowed, true);
  assert.equal(result.projectRef, "nhthrtpkfpmufmrmdyjg");
});

test("Vercel Production accepts only the designated production Supabase project", () => {
  const result = evaluateSupabaseEnvironment(PRODUCTION_URL, "production");
  assert.equal(result.allowed, true);
  assert.equal(result.projectRef, "bdybebzvzapihjdauehg");
});

test("Vercel Production fails closed when it receives the UAT Supabase project", () => {
  const result = evaluateSupabaseEnvironment(UAT_URL, "production");
  assert.equal(result.allowed, false);
  assert.match(result.message, /produkcyjne wskazuje bazę UAT/i);
});

test("Preview fails closed for every foreign or malformed project host", () => {
  for (const url of [
    FOREIGN_URL,
    "https://nhthrtpkfpmufmrmdyjg.supabase.co.evil.example",
    "not-a-supabase-url",
  ]) {
    const result = evaluateSupabaseEnvironment(url, "preview");
    assert.equal(result.allowed, false, url);
    assert.match(result.message, /zablokowany/i);
  }
});

test("missing Supabase project fails closed with a Polish repair path", () => {
  const result = evaluateSupabaseEnvironment(undefined, "preview");
  assert.equal(result.allowed, false);
  assert.match(result.message, /brakuje.*Supabase/i);
  assert.match(result.message, /Vercel.*Environment Variables/i);
});

test("local development may use UAT but never production or a foreign project", () => {
  assert.equal(evaluateSupabaseEnvironment(UAT_URL, "local").allowed, true);
  assert.equal(evaluateSupabaseEnvironment(UAT_URL, "development").allowed, true);
  assert.equal(evaluateSupabaseEnvironment(PRODUCTION_URL, "local").allowed, false);
  assert.equal(evaluateSupabaseEnvironment(FOREIGN_URL, "development").allowed, false);
});

test("missing or blank deployment environment fails closed for known projects", () => {
  for (const projectUrl of [UAT_URL, PRODUCTION_URL]) {
    for (const environment of [undefined, "", "   "]) {
      const result = evaluateSupabaseEnvironment(projectUrl, environment);
      assert.equal(result.allowed, false, `${projectUrl} / ${String(environment)}`);
      assert.match(result.message, /środowisk/i);
    }
  }
});

test("unknown deployment environment fails closed", () => {
  const result = evaluateSupabaseEnvironment(UAT_URL, "staging");
  assert.equal(result.allowed, false);
  assert.match(result.message, /środowisk/i);
});
