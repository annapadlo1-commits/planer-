import type { MatrixV2Employee, MatrixV2Workspace } from "@/lib/matrix-v2";

export type WorkforceProfileCheckKey = "profile" | "role" | "location" | "rate";

export type WorkforceProfileCheck = {
  key: WorkforceProfileCheckKey;
  label: string;
  complete: boolean;
  detail: string;
};

export type WorkforceProfileReadiness = {
  complete: boolean;
  completed: number;
  total: number;
  requiredFrom?: string;
  requiredTo?: string;
  checks: WorkforceProfileCheck[];
};

function normalizedSearchValue(value: unknown) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLocaleLowerCase("pl-PL");
}

export function employeeMatchesWorkforceQuery(data: MatrixV2Workspace, employee: MatrixV2Employee, query: string) {
  const tokens = normalizedSearchValue(query).split(/\s+/).filter(Boolean);
  if (!tokens.length) return true;
  const roleNames = data.employeeRoles
    .filter(link => link.employee_id === employee.id && link.active)
    .map(link => data.roles.find(role => role.id === link.role_id)?.name ?? "");
  const locationNames = data.employeeLocations
    .filter(link => link.employee_id === employee.id && link.active)
    .map(link => data.locations.find(location => location.id === link.location_id)?.name ?? "");
  const dutyNames = data.employeeDuties
    .filter(link => link.employee_id === employee.id && link.active)
    .map(link => data.duties.find(duty => duty.id === link.duty_id)?.name ?? "");
  const haystack = normalizedSearchValue([
    employee.firstName, employee.lastName, employee.employeeNo, employee.email,
    roleNames.join(" "), locationNames.join(" "), dutyNames.join(" "),
  ].join(" "));
  return tokens.every(token => haystack.includes(token));
}

function monthBounds(month: string) {
  const key = month.slice(0, 7);
  const [year, monthNumber] = key.split("-").map(Number);
  const lastDay = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
  return { from: `${key}-01`, to: `${key}-${String(lastDay).padStart(2, "0")}` };
}

function nextIsoDate(value: string) {
  const date = new Date(`${value}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
}

function coversRatePeriod(data: MatrixV2Workspace, employee: MatrixV2Employee, requiredFrom: string, requiredTo: string) {
  let cursor = requiredFrom;
  const rates = data.employeePayRates
    .filter(rate => rate.employee_id === employee.id && rate.active && rate.valid_from <= requiredTo && (rate.valid_to ?? "9999-12-31") >= requiredFrom)
    .sort((left, right) => left.valid_from.localeCompare(right.valid_from));
  for (const rate of rates) {
    if (rate.valid_from > cursor) return false;
    const coveredTo = rate.valid_to ?? "9999-12-31";
    if (coveredTo >= requiredTo) return true;
    if (coveredTo >= cursor) cursor = nextIsoDate(coveredTo);
  }
  return false;
}

export function workforceProfileReadiness(data: MatrixV2Workspace, employee: MatrixV2Employee, month: string): WorkforceProfileReadiness {
  const employmentDatesValid = !employee.employmentStart || !employee.employmentEnd || employee.employmentEnd >= employee.employmentStart;
  const employmentContract = ["UMOWA_O_PRACE", "CZESC_ETATU"].includes(employee.contractType ?? "");
  const usesHardLimits = employmentContract || employee.workTimePolicy === "CUSTOM";
  const limitsValid = employee.maximumMonthlyMinutes >= employee.nominalMonthlyMinutes
    && (!usesHardLimits || (employee.maximumWeeklyMinutes > 0 && employee.maximumConsecutiveDays >= 1));
  const profileComplete = Boolean(employee.firstName.trim() && employee.lastName.trim() && employee.contractType && employmentDatesValid && limitsValid);
  const primaryRole = data.employeeRoles.find(link => link.employee_id === employee.id && link.active && link.is_primary);
  const standardLocation = data.employeeLocations.find(link => link.employee_id === employee.id && link.active && link.standard_allowed);
  const bounds = monthBounds(month);
  const requiredFrom = employee.employmentStart && employee.employmentStart > bounds.from ? employee.employmentStart : bounds.from;
  const requiredTo = employee.employmentEnd && employee.employmentEnd < bounds.to ? employee.employmentEnd : bounds.to;
  const employedInMonth = requiredFrom <= requiredTo;
  const rateRequired = data.financeVisible && employee.active && employedInMonth;
  const rateComplete = !rateRequired || coversRatePeriod(data, employee, requiredFrom, requiredTo);
  const checks: WorkforceProfileCheck[] = [
    { key: "profile", label: "Dane, umowa i limity", complete: profileComplete, detail: profileComplete ? "Spójne" : "Sprawdź dane współpracy i limity" },
    { key: "role", label: "Rola podstawowa", complete: Boolean(primaryRole), detail: primaryRole ? data.roles.find(role => role.id === primaryRole.role_id)?.name ?? "Przypisana" : "Wymaga przypisania" },
    { key: "location", label: "Zwykły lokal pracy", complete: Boolean(standardLocation), detail: standardLocation ? data.locations.find(location => location.id === standardLocation.location_id)?.name ?? "Przypisany" : "Wymaga przypisania" },
    ...(rateRequired ? [{ key: "rate" as const, label: "Stawka dla miesiąca", complete: rateComplete, detail: rateComplete ? `${requiredFrom}–${requiredTo}` : `Brak pełnego pokrycia ${requiredFrom}–${requiredTo}` }] : []),
  ];
  const completed = checks.filter(check => check.complete).length;
  return { complete: completed === checks.length, completed, total: checks.length, requiredFrom: rateRequired ? requiredFrom : undefined, requiredTo: rateRequired ? requiredTo : undefined, checks };
}
