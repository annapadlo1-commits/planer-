import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migrationDirectory = new URL("supabase/migrations/", root);
const migrationNames = (await readdir(migrationDirectory)).filter((name) =>
  name.endsWith("_aud014_evidence_backed_fk_indexes.sql"),
);

assert.equal(
  migrationNames.length,
  1,
  "musi istnieć dokładnie jedna migracja AUD-014 z trzema indeksami",
);

const migration = await readFile(
  new URL(migrationNames[0], migrationDirectory),
  "utf8",
);
const catalog = JSON.parse(
  await readFile(
    new URL("supabase/baseline/aud003/uat-catalog-2026-09-03.json", root),
    "utf8",
  ),
);

const expectedIndexes = new Map([
  [
    "application_access_directory_v1_auth_user_id_fk_idx",
    ["application_access_directory_v1", "auth_user_id"],
  ],
  ["audit_log_actor_id_fk_idx", ["audit_log", "actor_id"]],
  [
    "employee_preferences_employee_id_fk_idx",
    ["employee_preferences", "employee_id"],
  ],
]);

const expectedConstraints = new Map([
  [
    "application_access_directory_v1_auth_user_id_fkey",
    [
      "application_access_directory_v1",
      "FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL",
    ],
  ],
  [
    "audit_log_actor_id_fkey",
    ["audit_log", "FOREIGN KEY (actor_id) REFERENCES auth.users(id)"],
  ],
  [
    "employee_preferences_employee_id_fkey",
    [
      "employee_preferences",
      "FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE",
    ],
  ],
]);

test("AUD-014 adds exactly the three evidence-backed FK indexes", () => {
  const actual = new Map(
    [...migration.matchAll(
      /create index if not exists ([a-z0-9_]+)\s+on public\.([a-z0-9_]+) \(([^)]+)\);/giu,
    )].map((match) => [match[1], [match[2], match[3]]]),
  );
  assert.deepEqual(actual, expectedIndexes);
});

test("AUD-014 bounds lock waits and verifies exact usable index definitions", () => {
  assert.match(migration, /set local lock_timeout='5s'/u);
  assert.match(migration, /set local statement_timeout='60s'/u);
  assert.match(migration, /index_row\.indisvalid is not true/u);
  assert.match(migration, /index_row\.indisready is not true/u);
  assert.match(migration, /index_row\.indpred is not null/u);
  assert.match(migration, /pg_catalog\.pg_get_indexdef/u);
  assert.match(migration, /AUD014_INDEX_DEFINITION_MISMATCH/u);
});

test("AUD-014 refuses every project except the exact UAT ref before DDL", () => {
  assert.match(
    migration,
    /control\.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'[\s\S]*control\.config->>'projectRef'='nhthrtpkfpmufmrmdyjg'/u,
  );
  assert.match(migration, /raise exception 'AUD014_WRONG_SUPABASE_PROJECT'/u);
  assert.ok(
    migration.indexOf("AUD014_WRONG_SUPABASE_PROJECT") <
      migration.indexOf("create index if not exists"),
    "guard projektu musi poprzedzać pierwsze DDL indeksu",
  );
});

test("AUD-014 is index-only and leaves data, constraints, RLS and grants untouched", () => {
  assert.doesNotMatch(
    migration,
    /\b(?:insert|update|delete|alter table|drop|policy|grant|revoke|truncate)\b/iu,
  );
  assert.equal(
    (migration.match(/create index if not exists/giu) ?? []).length,
    3,
  );
});

test("the preserved exact-UAT catalog proves all three FK shapes", () => {
  assert.equal(catalog.projectRef, "nhthrtpkfpmufmrmdyjg");
  for (const [name, [relation, definition]] of expectedConstraints) {
    const constraint = catalog.constraints.find((entry) => entry.name === name);
    assert.deepEqual(
      [constraint?.relation, constraint?.definition],
      [relation, definition],
      `niezgodny dowód katalogowy dla ${name}`,
    );
  }
});

test("the preserved catalog has no leading index for any selected FK", () => {
  for (const [, [relation, column]] of expectedIndexes) {
    const leadingIndexes = catalog.indexes.filter(
      (entry) =>
        entry.schema === "public" &&
        entry.relation === relation &&
        new RegExp(`\\(\\s*"?${column}"?(?:\\s|,|\\))`, "iu").test(
          entry.definition,
        ),
    );
    assert.deepEqual(
      leadingIndexes,
      [],
      `${relation}.${column} ma już indeks prowadzący w dowodzie katalogowym`,
    );
  }
});
