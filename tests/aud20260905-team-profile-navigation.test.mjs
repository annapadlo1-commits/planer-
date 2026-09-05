import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { configurationDeepLinkFromSearch } from "../lib/product-journey.ts";

test("employee settings deep link selects the workforce employee editor", () => {
  assert.deepEqual(
    configurationDeepLinkFromSearch("?month=2026-09&employee=employee-123"),
    {
      section: "workforce",
      step: "employees",
      employeeId: "employee-123",
      createEmployee: false,
    },
  );
  assert.deepEqual(
    configurationDeepLinkFromSearch("?employee=new"),
    {
      section: "workforce",
      step: "employees",
      employeeId: null,
      createEmployee: true,
    },
  );
  assert.equal(configurationDeepLinkFromSearch("?month=2026-09"), null);
  assert.equal(configurationDeepLinkFromSearch("?employee=%20%20"), null);
});

test("settings route applies the employee deep link after navigation remount", async () => {
  const source = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
  assert.match(source, /configurationDeepLinkFromSearch\(window\.location\.search\)/u);
  assert.match(source, /setConfigurationTab\(deepLink\.section\)/u);
  assert.match(source, /setConfigurationStep\(deepLink\.step\)/u);
  assert.match(source, /setMatrixFocusEmployeeId\(deepLink\.employeeId\)/u);
});
