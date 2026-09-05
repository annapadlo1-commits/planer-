import type { MatrixV2Workspace } from "./matrix-v2.ts";

export async function buildWorkforceFinanceTemplate(
  data: MatrixV2Workspace,
  companyBoundaryId: string,
) {
  const XLSX = await import("xlsx");
  const workbook = XLSX.utils.book_new();
  const instructions = XLSX.utils.aoa_to_sheet([
    ["SZAFUNEK — zbiorcza aktualizacja stawek", "Zasada"],
    ["Co można zrobić", "W jednym pliku dodasz nowe okresy stawek, poprawisz istniejące i wyłączysz błędne wpisy dla całego zespołu."],
    ["Tożsamość pracownika", "Nie zmieniaj kolumny Numer pracownika. Imię, nazwisko i daty zatrudnienia są tylko informacją pomocniczą."],
    ["Nowa stawka", "Dodaj nowy wiersz, pozostaw ID stawki puste i podaj Numer pracownika, okres, kwotę, walutę oraz aktywność. Forma współpracy pochodzi z profilu pracownika."],
    ["Zmiana istniejącej stawki", "Zachowaj ID stawki i popraw wybrane dane w tym samym wierszu."],
    ["Wyłączenie wpisu", "Zachowaj ID stawki i wpisz NIE w kolumnie Aktywna. Wpis nie jest usuwany — pozostaje w historii."],
    ["Okresy", "Aktywne okresy jednej osoby nie mogą się nakładać. Puste Obowiązuje do oznacza stawkę bez daty końcowej."],
    ["Kwota", "Wpisz kwotę godzinową w złotych, np. 32,50. System zapisuje ją z dokładnością do grosza."],
    ["Bezpieczeństwo", "Najpierw zobaczysz podgląd zmian. Cały plik zapisuje się atomowo: jeden błąd zatrzyma wszystkie wiersze."],
  ]);
  instructions["!cols"] = [{ wch: 34 }, { wch: 108 }];
  XLSX.utils.book_append_sheet(workbook, instructions, "Instrukcja");

  const headers = ["ID stawki", "Numer pracownika", "Imię i nazwisko", "Zatrudniony od", "Zatrudniony do", "Obowiązuje od", "Obowiązuje do", "Stawka godzinowa", "Waluta", "Aktywna"];
  const draftStart = String(data.matrixVersion.effective_from ?? data.month ?? new Date().toISOString()).slice(0, 10);
  const rows = data.employees.filter(employee => employee.active).flatMap(employee => {
    const rates = (data.employeePayRates ?? []).filter(rate => rate.employee_id === employee.id && rate.active)
      .sort((left, right) => left.valid_from.localeCompare(right.valid_from));
    const employeeName = `${employee.firstName} ${employee.lastName}`.trim();
    if (!rates.length) return [["", employee.employeeNo, employeeName, employee.employmentStart ?? "", employee.employmentEnd ?? "", employee.employmentStart && employee.employmentStart > draftStart ? employee.employmentStart : draftStart, "", "", data.matrixVersion.settings?.currency ?? "PLN", "TAK"]];
    return rates.map(rate => [rate.id, employee.employeeNo, employeeName, employee.employmentStart ?? "", employee.employmentEnd ?? "", rate.valid_from, rate.valid_to ?? "", rate.base_rate_minor / 100, rate.currency, rate.active ? "TAK" : "NIE"]);
  });
  const sheet = XLSX.utils.aoa_to_sheet([headers, ...rows]);
  sheet["!autofilter"] = { ref: `A1:J${Math.max(1, rows.length + 1)}` };
  sheet["!freeze"] = { xSplit: 0, ySplit: 1 };
  sheet["!cols"] = [{ wch: 38 }, { wch: 20 }, { wch: 28 }, { wch: 17 }, { wch: 17 }, { wch: 17 }, { wch: 17 }, { wch: 22 }, { wch: 12 }, { wch: 12 }];
  XLSX.utils.book_append_sheet(workbook, sheet, "Finanse pracowników");
  const dictionaries = XLSX.utils.aoa_to_sheet([
    ["POLE", "WARTOŚĆ", "OPIS"],
    ["Aktywna", "TAK", "Wpis obowiązuje"],
    ["Aktywna", "NIE", "Wyłącz wpis bez usuwania historii"],
  ]);
  dictionaries["!cols"] = [{ wch: 24 }, { wch: 24 }, { wch: 48 }];
  XLSX.utils.book_append_sheet(workbook, dictionaries, "Słowniki");
  XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet([
    ["Klucz", "Wartość"],
    ["workbookMode", "FINANCE_IMPORT"],
    ["contractVersion", "1"],
    ["companyBoundaryId", companyBoundaryId],
  ]), "_META");
  const raw = XLSX.write(workbook, { type: "array", bookType: "xlsx" });
  const { polishFinanceWorkbook } = await import("./excel-workbook-polish.ts");
  return {
    bytes: await polishFinanceWorkbook(raw),
    fileName: `szafunek-finanse-pracownikow-${String(data.month ?? draftStart).slice(0, 7)}.xlsx`,
  };
}
