import assert from "node:assert/strict";
import test from "node:test";

import {
  assignmentStyle,
  availabilityLabel,
  dateLabel,
  dutyStyle,
  locationStyle,
  money,
  monthLabel,
  monthWeeks,
  preferenceLevelLabel,
  publicationStatus,
  reasonLabel,
  roleStyle,
  shortDayLabel,
  stablePaletteIndex,
  timeLabel,
  timestampLabel,
  workloadHours,
  workloadReason,
  workloadReasonCode,
} from "../lib/solver-v2-workspace-presentation.ts";

test("workspace presentation keeps deterministic colours and combines role and location tokens", () => {
  assert.equal(stablePaletteIndex("role-a", 6), stablePaletteIndex("role-a", 6));
  assert.ok(stablePaletteIndex("role-a", 6) >= 0 && stablePaletteIndex("role-a", 6) < 6);
  assert.equal(stablePaletteIndex("role-a", 0), 0);
  assert.equal(stablePaletteIndex("role-a", -1), 0);

  const role = roleStyle("role-a");
  const location = locationStyle("location-a");
  assert.deepEqual(roleStyle("role-a"), role);
  assert.deepEqual(locationStyle("location-a"), location);
  assert.deepEqual(role, {
    "--role-accent": "#b44785",
    "--role-background": "#fcecf5",
  });
  assert.deepEqual(location, {
    "--location-accent": "#246b9c",
    "--location-background": "#eaf5ff",
  });
  assert.deepEqual(dutyStyle("duty-a"), {
    color: "#3f5f8a",
    backgroundColor: "#edf3ff",
  });
  assert.deepEqual(assignmentStyle("role-a", "location-a"), { ...role, ...location });
  assert.match(String(role["--role-accent"]), /^#[0-9a-f]{6}$/iu);
  assert.match(String(location["--location-background"]), /^#[0-9a-f]{6}$/iu);
  assert.match(String(dutyStyle("duty-a").backgroundColor), /^#[0-9a-f]{6}$/iu);
});

test("workspace presentation keeps calendar boundaries and Polish fallbacks", () => {
  const leapFebruary = monthWeeks("2024-02");
  assert.equal(leapFebruary.length, 5);
  assert.deepEqual(leapFebruary[0], ["2024-01-29", "2024-01-30", "2024-01-31", "2024-02-01", "2024-02-02", "2024-02-03", "2024-02-04"]);
  assert.equal(leapFebruary.at(-1)?.at(-1), "2024-03-03");

  const yearBoundary = monthWeeks("2025-12");
  assert.equal(yearBoundary[0][0], "2025-12-01");
  assert.equal(yearBoundary.at(-1)?.at(-1), "2026-01-04");
  assert.match(shortDayLabel("2026-01-01"), /1/u);
  assert.match(dateLabel("2026-01-01"), /1 stycznia/u);
  assert.match(monthLabel("2024-02"), /luty 2024/u);
  assert.equal(dateLabel("invalid"), "Termin zmiany");
  assert.equal(monthLabel("invalid"), "Wybrany miesiąc");
  assert.equal(timeLabel("invalid", "Europe/Warsaw"), "invalid");
  assert.equal(timestampLabel("invalid", "Europe/Warsaw"), null);
  assert.equal(timestampLabel(null, "Europe/Warsaw"), null);
});

test("workspace presentation keeps finance, workload and status explanations unchanged", () => {
  assert.equal(money(null, "PLN"), "Bez limitu");
  assert.match(money(1234, "PLN"), /12,34/u);
  assert.equal(money(1234, "INVALID"), "12,34 INVALID");
  assert.equal(workloadHours(90), "1,5 h");
  assert.equal(publicationStatus("PUBLISHED"), "Opublikowany");
  assert.equal(publicationStatus("ARCHIVED"), "Zarchiwizowany");
  assert.equal(publicationStatus(), "Gotowy do publikacji");

  const row = {
    maximumMonthlyMinutes: 0,
    totalMonthlyMinutes: 0,
    reasonCode: "ON_TARGET",
    hardUnavailableDays: 0,
    availableWindowDays: 0,
  };
  assert.match(workloadReason(row), /zgodny z ustawionym miesięcznym wymiarem/u);
  assert.equal(workloadReasonCode(row), "ON_TARGET");
  assert.match(workloadReason({ ...row, maximumMonthlyMinutes: 60, totalMonthlyMinutes: 120 }), /przekracza twardy limit o 1 h/u);
  assert.equal(workloadReasonCode({ ...row, maximumMonthlyMinutes: 60, totalMonthlyMinutes: 120 }), "ABOVE_MAXIMUM");
  assert.match(workloadReason({ ...row, reasonCode: "AVAILABILITY_LIMITED", hardUnavailableDays: 3 }), /3 dni/u);
  assert.match(workloadReason({ ...row, reasonCode: "AVAILABILITY_WINDOW_LIMITED", availableWindowDays: 4 }), /4 dniach/u);
  assert.match(workloadReason({ ...row, reasonCode: "MAXIMUM_REACHED" }), /twardy miesięczny limit/u);
  assert.match(workloadReason({ ...row, reasonCode: "TARGET_NOT_SET" }), /Nie ustawiono miesięcznego celu/u);
  assert.match(workloadReason({ ...row, reasonCode: "ABOVE_NOMINAL" }), /przekracza miesięczny wymiar/u);
  assert.match(workloadReason({ ...row, reasonCode: "UNKNOWN" }), /reguł całego zespołu/u);

  assert.equal(reasonLabel("MONTHLY_LIMIT"), "Przekroczony indywidualny limit miesięczny");
  assert.equal(reasonLabel("UNKNOWN"), "UNKNOWN");
  assert.equal(availabilityLabel("AVAILABLE"), "Dostępny • wolne okno i limit dzienny");
  assert.equal(availabilityLabel("UNKNOWN"), "Wymaga sprawdzenia");
  assert.equal(preferenceLevelLabel("PREFERRED"), "preferowana");
  assert.equal(preferenceLevelLabel("UNKNOWN"), "UNKNOWN");
});
