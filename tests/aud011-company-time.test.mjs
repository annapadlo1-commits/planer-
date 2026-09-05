import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  businessMonthAt,
  CompanyTimeConfigurationError,
  initialBusinessMonth,
  parseCompanyTimeContext,
  requireIanaTimeZone,
} from "../lib/company-time.ts";

const migrationUrl = new URL(
  "../supabase/migrations/20260903140000_aud011_company_timezone_context.sql",
  import.meta.url,
);

function assertReadOnlyTimeRpc(source) {
  // SQL layout is semantic here; preserve all content except checkout CRLF.
  const sql = source.replaceAll("\r\n", "\n");
  assert.match(sql, /current_company_time_context_v1\(\)[\s\S]*?\nlanguage plpgsql\nstable\nsecurity definer\nset search_path=''/u);
  assert.match(sql, /pg_catalog\.pg_timezone_names/u);
  assert.match(sql, /pg_catalog\.timezone\(v_timezone,statement_timestamp\(\)\)/u);
  assert.doesNotMatch(sql, /Europe\/Warsaw/u);
  assert.doesNotMatch(sql, /\b(?:insert|update|delete|truncate)\b/iu);
}

test("AUD-011 computes the company month at a UTC boundary independently of the user's zone", () => {
  const instant = new Date("2026-09-30T22:30:00.000Z");
  assert.equal(businessMonthAt(instant, "Europe/Warsaw"), "2026-10");
  assert.equal(businessMonthAt(instant, "America/New_York"), "2026-09");
  assert.equal(businessMonthAt(instant, "Pacific/Kiritimati"), "2026-10");
});

test("AUD-011 remains deterministic across DST transitions", () => {
  assert.equal(businessMonthAt(new Date("2026-03-29T00:30:00.000Z"), "Europe/Warsaw"), "2026-03");
  assert.equal(businessMonthAt(new Date("2026-03-29T01:30:00.000Z"), "Europe/Warsaw"), "2026-03");
  assert.equal(businessMonthAt(new Date("2026-11-01T05:30:00.000Z"), "America/New_York"), "2026-11");
  assert.equal(businessMonthAt(new Date("2026-11-01T06:30:00.000Z"), "America/New_York"), "2026-11");
});

test("AUD-011 fails closed for a missing or invalid company timezone", () => {
  for (const value of [undefined, "", "Warsaw", "Europe/Not_A_Zone"]) {
    assert.throws(() => requireIanaTimeZone(value), CompanyTimeConfigurationError);
  }
  assert.throws(() => initialBusinessMonth(""), CompanyTimeConfigurationError);
  assert.throws(() => parseCompanyTimeContext({ timezone: "Europe/Warsaw", currentMonth: "2026-13" }), CompanyTimeConfigurationError);
});

test("AUD-011 keeps an explicit valid URL month but otherwise uses the server company month", () => {
  assert.equal(initialBusinessMonth("2026-10", "2026-08", "2026-07"), "2026-08");
  assert.equal(initialBusinessMonth("2026-10", "invalid", "2026-07"), "2026-07");
  assert.equal(initialBusinessMonth("2026-10", null, null), "2026-10");
  assert.deepEqual(parseCompanyTimeContext({
    timezone: "Europe/Warsaw",
    currentMonth: "2026-10",
    matrixVersionId: "matrix-id",
    matrixVersion: 7,
    matrixStatus: "ACTIVE",
  }), {
    timezone: "Europe/Warsaw",
    currentMonth: "2026-10",
    matrixVersionId: "matrix-id",
    matrixVersion: 7,
    matrixStatus: "ACTIVE",
  });
});

test("AUD-011 server RPC is read-only, validates IANA and precedes the month workspace read", async () => {
  const sql = await readFile(migrationUrl, "utf8");
  const provider = await readFile(new URL("../components/AppAuthProvider.tsx", import.meta.url), "utf8");
  const page = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");

  assertReadOnlyTimeRpc(sql);
  assert.ok(provider.indexOf('rpc("current_company_time_context_v1"') < provider.indexOf('rpc("matrix_v2_workspace"'));
  assert.doesNotMatch(provider, /new Date\(\)\.toISOString\(\)\.slice\(0,7\)/u);
  assert.doesNotMatch(page, /new Date\(\)\.toISOString\(\)\.slice\(0,7\)/u);
});

test("AUD-011 read-only contract accepts LF/CRLF and rejects weakened RPC security", async () => {
  const lf = (await readFile(migrationUrl, "utf8")).replaceAll("\r\n", "\n");
  for (const newline of ["\n", "\r\n"]) {
    const sql = lf.replaceAll("\n", newline);
    assertReadOnlyTimeRpc(sql);
    assert.throws(() => assertReadOnlyTimeRpc(sql.replace("stable", "volatile")));
    assert.throws(() => assertReadOnlyTimeRpc(sql.replace("set search_path=''", "set search_path='public'")));
    assert.throws(() => assertReadOnlyTimeRpc(`${sql}${newline}delete from public.matrix_versions;`));
  }
});
