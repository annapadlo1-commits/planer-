import test from "node:test";
import assert from "node:assert/strict";
import { evaluateSupabaseEnvironment } from "../lib/supabase/client.ts";

const UAT_URL = "https://nhthrtpkfpmufmrmdyjg.supabase.co";
const PRODUCTION_URL = "https://bdybebzvzapihjdauehg.supabase.co";

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

test("Vercel Production fails closed when it receives the UAT Supabase project", () => {
  const result = evaluateSupabaseEnvironment(UAT_URL, "production");
  assert.equal(result.allowed, false);
  assert.match(result.message, /produkcyjne wskazuje bazę UAT/i);
});
