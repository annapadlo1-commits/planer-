"use client";

import { CircleDollarSign, Plus, Save, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { MatrixV2Workspace } from "@/lib/matrix-v2";
import { getMonthlyBudgets, saveMonthlyBudgets, type MonthlyBudgetLine, type MonthlyBudgetWorkspace } from "@/lib/monthly-budgets";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type Props = { month: string; matrix: MatrixV2Workspace | null; currency: string; close: () => void; notify: (message: string) => void; fail: (message: string) => void };

export function MonthlyBudgetDrawer({ month, matrix, currency, close, notify, fail }: Props) {
  const client = useMemo(() => createSupabaseBrowserClient(), []);
  const [workspace, setWorkspace] = useState<MonthlyBudgetWorkspace | null>(null);
  const [lines, setLines] = useState<MonthlyBudgetLine[]>([]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!client) return;
    setBusy(true);
    getMonthlyBudgets(client, month).then((value) => {
      setWorkspace(value);
      setLines(value.lines.map((line) => ({
        ...line,
        locationId: matrix?.locations.find((item) => item.logicalId === line.locationLogicalId)?.id ?? null,
        categoryId: matrix?.roleCategories?.find((item) => item.logicalId === line.categoryLogicalId)?.id ?? null,
        roleId: matrix?.roles.find((item) => item.logicalId === line.roleLogicalId)?.id ?? null,
      })));
    }).catch((error) => fail(error instanceof Error ? error.message : String(error))).finally(() => setBusy(false));
  }, [client, fail, matrix, month]);

  const change = (index: number, patch: Partial<MonthlyBudgetLine>) => setLines((current) => current.map((line, itemIndex) => itemIndex === index ? { ...line, ...patch } : line));
  const add = () => setLines((current) => [...current, { scopeType: "COMPANY", metricType: "COST", enforcement: "TARGET", limitValue: 0, currency, costBasis: "WAGES", distributionMode: "MONTHLY" }]);

  async function save() {
    if (!client) return;
    setBusy(true);
    try {
      const result = await saveMonthlyBudgets(client, month, lines, note);
      setWorkspace(result); setLines(result.lines); setNote("");
      notify(`Budżet ${month.slice(0, 7)} zapisano jako rewizję ${result.revision?.number}.`);
    } catch (error) { fail(error instanceof Error ? error.message : String(error)); }
    finally { setBusy(false); }
  }

  return <><button className="drawer-scrim top" onClick={close} /><aside className="drawer matrix-v2-drawer top monthly-budget-drawer">
    <div className="drawer-head"><div><p className="eyebrow">GRAFIK • BUDŻET MIESIĘCZNY</p><h2>Budżet na {month.slice(0, 7)}</h2><small>{workspace?.revision ? `Aktywna rewizja ${workspace.revision.number}` : "Nie ustawiono jeszcze budżetu"}</small></div><button className="icon-button" onClick={close}><X /></button></div>
    <div className="drawer-content"><div className="solver-v2-notice"><CircleDollarSign /><span><strong>Budżety działają równocześnie</strong><small>Budżet szczegółowy nie zastępuje nadrzędnego. Jedna zmiana ma jeden koszt, który jest sprawdzany w każdym pasującym zakresie. Zmiana kwoty tworzy osobną rewizję, nie nową wersję konfiguracji firmy.</small></span></div>
      {lines.map((line, index) => <article className="monthly-budget-line" key={line.id ?? index}>
        <label>Zakres<select disabled={!workspace?.canEdit} value={line.scopeType} onChange={(event) => change(index, { scopeType: event.target.value as MonthlyBudgetLine["scopeType"], locationId: null, categoryId: null, roleId: null })}><option value="COMPANY">Cała firma</option><option value="LOCATION">Lokal</option><option value="CATEGORY">Kategoria</option><option value="LOCATION_CATEGORY">Lokal i kategoria</option><option value="ROLE">Rola</option></select></label>
        {["LOCATION", "LOCATION_CATEGORY"].includes(line.scopeType) && <label>Lokal<select disabled={!workspace?.canEdit} value={line.locationId ?? ""} onChange={(event) => change(index, { locationId: event.target.value })}><option value="">Wybierz lokal</option>{matrix?.locations.filter((item) => item.active).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>}
        {["CATEGORY", "LOCATION_CATEGORY"].includes(line.scopeType) && <label>Kategoria<select disabled={!workspace?.canEdit} value={line.categoryId ?? ""} onChange={(event) => change(index, { categoryId: event.target.value })}><option value="">Wybierz kategorię</option>{matrix?.roleCategories?.filter((item) => item.active).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>}
        {line.scopeType === "ROLE" && <label>Rola<select disabled={!workspace?.canEdit} value={line.roleId ?? ""} onChange={(event) => change(index, { roleId: event.target.value })}><option value="">Wybierz rolę</option>{matrix?.roles.filter((item) => item.active).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>}
        <label>Typ<select disabled={!workspace?.canEdit} value={line.metricType} onChange={(event) => change(index, { metricType: event.target.value as MonthlyBudgetLine["metricType"] })}><option value="COST">Koszt</option><option value="HOURS">Godziny</option><option value="LABOR_PERCENT">Koszt pracy / sprzedaż (%)</option></select></label>
        <label>{line.metricType === "COST" ? `Limit (${line.currency ?? currency})` : line.metricType === "HOURS" ? "Limit godzin" : "Limit procentowy"}<input disabled={!workspace?.canEdit} type="number" min="0" step="0.01" value={line.limitValue} onChange={(event) => change(index, { limitValue: Number(event.target.value) })} /></label>
        {line.metricType === "LABOR_PERCENT" && <label>Planowana sprzedaż ({line.currency ?? currency})<input disabled={!workspace?.canEdit} type="number" min="0" step="0.01" value={line.referenceValue ?? 0} onChange={(event) => change(index, { referenceValue: Number(event.target.value), currency: line.currency ?? currency })} /></label>}
        <label>Egzekwowanie<select disabled={!workspace?.canEdit} value={line.enforcement} onChange={(event) => change(index, { enforcement: event.target.value as MonthlyBudgetLine["enforcement"] })}><option value="HARD">HARD — nie przekraczaj</option><option value="TARGET">TARGET — dąż do celu</option><option value="MONITORING">MONITORING — tylko raportuj</option></select></label>
        {line.metricType === "COST" && <label>Zakres kosztu<select disabled={!workspace?.canEdit} value={line.costBasis ?? "WAGES"} onChange={(event) => change(index, { costBasis: event.target.value as "WAGES" | "FULL_EMPLOYER_COST" })}><option value="WAGES">Wynagrodzenia</option><option value="FULL_EMPLOYER_COST">Pełny koszt pracodawcy</option></select></label>}
        {workspace?.canEdit && <button className="icon-button" aria-label="Usuń pozycję" onClick={() => setLines((current) => current.filter((_, itemIndex) => itemIndex !== index))}><Trash2 /></button>}
      </article>)}
      {!lines.length && !busy && <p>Brak budżetów dla tego miesiąca.</p>}
      {workspace?.canEdit && <><button className="secondary-button" onClick={add}><Plus /> Dodaj zakres</button><label>Powód zmiany<input value={note} onChange={(event) => setNote(event.target.value)} placeholder="Np. zatwierdzony budżet operacyjny na miesiąc" /></label><button className="primary-button full" disabled={busy || !note.trim()} onClick={() => void save()}><Save /> Zapisz nową rewizję budżetu</button></>}
    </div>
  </aside></>;
}
