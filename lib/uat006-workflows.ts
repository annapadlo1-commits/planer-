export type AutomaticShiftPeriod = "MORNING" | "MIDDLE" | "EVENING";

export const TIME_24_PATTERN = "(?:[01][0-9]|2[0-3]):[0-5][0-9]";
const TIME_24_EXACT = /^(?:[01]\d|2[0-3]):[0-5]\d$/;

export function parseTime24(value: string, label: string, optional = false) {
  const normalized = value.trim();
  if (optional && normalized === "") return null;
  if (!TIME_24_EXACT.test(normalized)) {
    throw new Error(`${label}: wpisz godzinę w formacie 24-godzinnym GG:MM, np. 18:30.`);
  }
  return normalized;
}

export function automaticShiftPeriod(startsAt: string): AutomaticShiftPeriod {
  const normalized = parseTime24(startsAt, "Godzina rozpoczęcia") as string;
  const hour = Number(normalized.slice(0, 2));
  return hour < 12 ? "MORNING" : hour < 17 ? "MIDDLE" : "EVENING";
}

export function equivalentShiftKey(input: {
  locationId: string;
  name: string;
  startsAt: string;
  endsAt: string;
  endsNextDay: boolean;
}) {
  return [
    input.locationId,
    input.name.trim().toLocaleLowerCase("pl-PL"),
    input.startsAt,
    input.endsAt,
    input.endsNextDay ? "1" : "0",
  ].join("|");
}
