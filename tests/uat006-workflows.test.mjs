import assert from "node:assert/strict";
import test from "node:test";
import {
  automaticShiftPeriod,
  equivalentShiftKey,
  parseTime24,
} from "../lib/uat006-workflows.ts";

test("24-hour input accepts independently editable minutes", () => {
  assert.equal(parseTime24("10:05", "Od"), "10:05");
  assert.equal(parseTime24("23:59", "Do"), "23:59");
  assert.equal(parseTime24("", "Okno", true), null);
  assert.throws(() => parseTime24("06:60", "Do"), /GG:MM/);
  assert.throws(() => parseTime24("6:30", "Od"), /GG:MM/);
  assert.throws(() => parseTime24("06:30 PM", "Od"), /GG:MM/);
});

test("shift preference bucket is derived and never required from the user", () => {
  assert.equal(automaticShiftPeriod("00:00"), "MORNING");
  assert.equal(automaticShiftPeriod("11:59"), "MORNING");
  assert.equal(automaticShiftPeriod("12:00"), "MIDDLE");
  assert.equal(automaticShiftPeriod("16:59"), "MIDDLE");
  assert.equal(automaticShiftPeriod("17:00"), "EVENING");
});

test("equivalent shifts share one logical key regardless of name casing", () => {
  const base={locationId:"krucza",startsAt:"15:00",endsAt:"23:00",endsNextDay:false};
  assert.equal(
    equivalentShiftKey({...base,name:"Zmiana środkowa"}),
    equivalentShiftKey({...base,name:"  ZMIANA ŚRODKOWA  "}),
  );
  assert.notEqual(
    equivalentShiftKey({...base,name:"Zmiana środkowa"}),
    equivalentShiftKey({...base,name:"Zmiana środkowa",startsAt:"16:00"}),
  );
});
