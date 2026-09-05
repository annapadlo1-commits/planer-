export type WorkforceFinanceRateRow = {
  sourceRow: number;
  rateId: string;
  employeeNo: string;
  validFrom: string;
  validTo: string;
  baseRate: string;
  currency: string;
  contractType: string;
  active: boolean;
};

export type WorkforceFinanceWorkbookPayload = {
  payRates: WorkforceFinanceRateRow[];
  _sourceLayout: "GRAFIK_PRO_FINANCE_V1";
  _workbook: {
    companyBoundaryId: string;
  };
};

function cell(row: Record<string, unknown>, ...names: string[]) {
  const normalizeHeader = (value: string) => value.trim()
    .replace(/\s*[\r\n]+\s*(?:WYMAGANE|OPCJONALNE|SYSTEM)\s*$/iu, "")
    .toLocaleLowerCase("pl-PL");
  const key = Object.keys(row).find(candidate => names.some(name =>
    normalizeHeader(candidate) === normalizeHeader(name),
  ));
  return key === undefined ? "" : String(row[key] ?? "").trim();
}

function booleanCell(value: string, defaultValue = true) {
  if (!value) return defaultValue;
  const normalized = value.replace(/[☑☐✓✔]/gu, "").trim().toLocaleLowerCase("pl-PL");
  return ["1", "tak", "true", "yes", "x"].includes(normalized);
}

function normalizeContract(value: string) {
  const key = value.toLocaleUpperCase("pl-PL").replace(/[^A-ZĄĆĘŁŃÓŚŹŻ0-9]/g, "");
  if (!key) return "";
  if (["UMOWAOPRACĘ", "UMOWAOPRACE", "UOP"].includes(key)) return "UMOWA_O_PRACE";
  if (["UMOWAZLECENIE", "ZLECENIE", "UZ"].includes(key)) return "ZLECENIE";
  if (["CZĘŚĆETATU", "CZESCETATU", "UMOWAOPRACĘCZĘŚĆETATU", "UMOWAOPRACECZESCETATU"].includes(key)) return "CZESC_ETATU";
  if (key === "B2B") return "B2B";
  if (["INNE", "OTHER"].includes(key)) return "INNE";
  return value.trim().toLocaleUpperCase("pl-PL");
}

type ExcelDateCodeParser = (value: number) => { y: number; m: number; d: number } | null | undefined;

function normalizeDate(value: string, parseDateCode?: ExcelDateCodeParser) {
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return trimmed;
  if (/^\d{5}(?:\.\d+)?$/.test(trimmed) && parseDateCode) {
    const parsed = parseDateCode(Number(trimmed));
    if (parsed) return `${String(parsed.y).padStart(4, "0")}-${String(parsed.m).padStart(2, "0")}-${String(parsed.d).padStart(2, "0")}`;
  }
  const match = trimmed.match(/^(\d{1,2})[./-](\d{1,2})[./-](\d{2}|\d{4})$/);
  if (!match) return trimmed;
  const year = match[3].length === 2 ? 2000 + Number(match[3]) : Number(match[3]);
  return `${String(year).padStart(4, "0")}-${String(Number(match[2])).padStart(2, "0")}-${String(Number(match[1])).padStart(2, "0")}`;
}

export function normalizeWorkforceFinanceRows(
  rows: Record<string, unknown>[],
  parseDateCode?: ExcelDateCodeParser,
): Omit<WorkforceFinanceWorkbookPayload, "_workbook"> {
  const payRates = rows.map((row, index) => ({
    sourceRow: index + 2,
    rateId: cell(row, "ID stawki", "rateId", "Pay rate ID"),
    employeeNo: cell(row, "Numer pracownika", "employeeNo", "Employee number"),
    validFrom: normalizeDate(cell(row, "Obowiązuje od", "validFrom", "Valid from"), parseDateCode),
    validTo: normalizeDate(cell(row, "Obowiązuje do", "validTo", "Valid to"), parseDateCode),
    baseRate: cell(row, "Stawka godzinowa", "baseRate", "Hourly rate").replace(",", "."),
    currency: cell(row, "Waluta", "currency", "Currency").toLocaleUpperCase("pl-PL"),
    contractType: normalizeContract(cell(row, "Rodzaj umowy", "contractType", "Contract type")),
    active: booleanCell(cell(row, "Aktywna", "active", "Active"), true),
  })).filter(row => row.employeeNo || row.rateId || row.validFrom || row.baseRate);

  return { payRates, _sourceLayout: "GRAFIK_PRO_FINANCE_V1" };
}

export async function readWorkforceFinanceWorkbook(file: File): Promise<WorkforceFinanceWorkbookPayload> {
  const XLSX = await import("xlsx");
  const workbook = XLSX.read(await file.arrayBuffer(), { type: "array", cellDates: false });
  const sheetName = workbook.SheetNames.find(name => [
    "Finanse pracowników", "Stawki pracowników", "Employee Finance", "Pay Rates",
  ].some(expected => name.toLocaleLowerCase("pl-PL") === expected.toLocaleLowerCase("pl-PL")));
  const rows = sheetName
    ? XLSX.utils.sheet_to_json<Record<string, unknown>>(workbook.Sheets[sheetName], { defval: "", raw: false, dateNF: "yyyy-mm-dd" })
    : [];

  const metaSheet = workbook.Sheets._META;
  const metaRows = metaSheet
    ? XLSX.utils.sheet_to_json<Record<string, unknown>>(metaSheet, { defval: "", raw: false })
    : [];
  const meta = new Map(metaRows.map(row => [
    String(row.Klucz ?? row.key ?? "").trim(),
    String(row.Wartość ?? row.Wartosc ?? row.value ?? "").trim(),
  ]));

  return {
    ...normalizeWorkforceFinanceRows(rows, value => XLSX.SSF.parse_date_code(value)),
    _workbook: { companyBoundaryId: meta.get("companyBoundaryId") ?? "" },
  };
}
