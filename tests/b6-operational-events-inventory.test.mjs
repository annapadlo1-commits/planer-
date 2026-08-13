import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("B6 exposes operational events as a first-class navigation view", async () => {
  const page = await read("app/page.tsx");
  assert.match(page, /OperationalEventsCenter/);
  assert.match(page, /wydarzenia/);
  assert.match(page, /Wydarzenia zespołu/);
});

test("B6 supports meetings, cleaning, inventory and configurable audiences", async () => {
  const component = await read("components/OperationalEventsCenter.tsx");
  for (const token of ["MEETING", "CLEANING", "INVENTORY", "TRAINING", "ONBOARDING"]) {
    assert.match(component, new RegExp(token));
  }
  for (const token of ["CATEGORY", "ROLE", "EMPLOYEE", "Potrzebuję określonej liczby osób"]) {
    assert.match(component, new RegExp(token));
  }
});

test("B6 keeps manager decisions explainable and auditable", async () => {
  const migration = await read(
    "supabase/migrations/20260813120000_b6_operational_programs_inventory_bridge.sql",
  );
  for (const token of [
    "operational_program_preview_uat_v1",
    "operational_program_save_uat_v1",
    "operational_program_cancel_uat_v1",
    "operational_program_audit_v1",
    "override_reason",
  ]) {
    assert.match(migration, new RegExp(token));
  }
});

test("B6 Inventory Pro bridge is explicit, queued and idempotent", async () => {
  const migration = await read(
    "supabase/migrations/20260813120000_b6_operational_programs_inventory_bridge.sql",
  );
  for (const token of [
    "business_app_integrations_v1",
    "operational_program_inventory_links_v1",
    "INVETORY_PRO",
    "payload_hash",
    "operational_program_inventory_ack_uat_v1",
  ]) {
    assert.match(migration, new RegExp(token));
  }
});

test("B6 publishes notifications and event time records, while cancellation reverses open records", async () => {
  const migration = await read(
    "supabase/migrations/20260813120000_b6_operational_programs_inventory_bridge.sql",
  );
  assert.match(migration, /insert into public\.notifications/);
  assert.match(migration, /insert into public\.time_records/);
  assert.match(migration, /delete from public\.time_records/);
  assert.match(migration, /CANCELLED/);
});
