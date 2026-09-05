"use client";

import { CircleDollarSign, Plus, Save, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { MatrixV2Workspace } from "@/lib/matrix-v2";
import { getMonthlyBudgets, hydrateMonthlyBudgetLines, saveMonthlyBudgets, type MonthlyBudgetLine, type MonthlyBudgetWorkspace } from "@/lib/monthly-budgets";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { getEmployerCostComponents, saveEmployerCostComponent, type EmployerCostComponent } from "@/lib/employer-costs";

type Props = { month: string; matrix: MatrixV2Workspace | null; currency: string; close: () => void; notify: (message: string) => void; fail: (message: string) => void };

export function MonthlyBudgetDrawer({ month, matrix, currency, close, notify, fail }: Props) {
  const client = useMemo(() => createSupabaseBrowserClient(), []);
  const [workspace, setWorkspace] = useState<MonthlyBudgetWorkspace | null>(null);
  const [lines, setLines] = useState<MonthlyBudgetLine[]>([]);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [components, setComponents] = useState<EmployerCostComponent[]>([]);
  const [costForm, setCostForm] = useState({ code: "", name: "", calculationMethod: "PERCENT_BASE" as EmployerCostComponent["calculationMethod"], value: 0, contractType: "", validFrom: month, validTo: "", reason: "" });

  useEffect(() => {
    if (!client) return;
    setBusy(true);
    getMonthlyBudgets(client, month).then((value) => {
      setWorkspace(value);
      setLines(hydrateMonthlyBudgetLines(value.lines, matrix));
    }).catch((error) => fail(error instanceof Error ? error.message : String(error))).finally(() => setBusy(false));
    getEmployerCostComponents(client, month).then(setComponents).catch((error) => fail(error instanceof Error ? error.message : String(error)));
  }, [client, fail, matrix, month]);

  const change = (index: number, patch: Partial<MonthlyBudgetLine>) => setLines((current) => current.map((line, itemIndex) => itemIndex === index ? { ...line, ...patch } : line));
  const add = () => setLines((current) => [...current, { scopeType: "COMPANY", metricType: "COST", enforcement: "TARGET", limitValue: 0, currency, costBasis: "WAGES", distributionMode: "MONTHLY" }]);

  async function save() {
    if (!client) return;
    setBusy(true);
    try {
      const result = await saveMonthlyBudgets(client, month, lines, note);
      setWorkspace(result); setLines(hydrateMonthlyBudgetLines(result.lines, matrix)); setNote("");
      notify(`Budżet ${month.slice(0, 7)} zapisano jako rewizję ${result.revision?.number}.`);
    } catch (error) { fail(error instanceof Error ? error.message : String(error)); }
    finally { setBusy(false); }
  }

  async function saveCostComponent() {
    if (!client) return;
    setBusy(true);
    try {
      await saveEmployerCostComponent(client, { ...costForm, validTo: costForm.validTo || null, contractType: costForm.contractType || null, active: true });
      setComponents(await getEmployerCostComponents(client, month));
      setCostForm({ code: "", name: "", calculationMethod: "PERCENT_BASE", value: 0, contractType: "", validFrom: month, validTo: "", reason: "" });
      notify("Zapisano nową, datowaną rewizję składnika kosztu pracodawcy.");
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
      <section className="employer-cost-config"><h3>Składniki pełnego kosztu pracodawcy</h3><p>System niczego nie dolicza domyślnie. „Pełny koszt” obejmuje wyłącznie poniższe jawne, datowane składniki. Wynagrodzenia pozostają osobną podstawą.</p>
        {components.map((item) => <div key={item.id}><strong>{item.name}</strong><span>{item.calculationMethod === "PERCENT_BASE" ? `${(Number(item.percentBasisPoints ?? 0) / 100).toFixed(2)}% podstawy` : item.calculationMethod === "PER_HOUR" ? `${(Number(item.rateMinorPerHour ?? 0) / 100).toFixed(2)} ${currency}/h` : `${(Number(item.amountMinor ?? 0) / 100).toFixed(2)} ${currency}/zmianę`} • od {item.validFrom}{item.validTo ? ` do ${item.validTo}` : ""} • rewizja {item.revision}</span></div>)}
        {workspace?.canEdit && <div className="employer-cost-form"><label>Kod<input value={costForm.code} onChange={(event) => setCostForm({...costForm,code:event.target.value})}/></label><label>Nazwa<input value={costForm.name} onChange={(event) => setCostForm({...costForm,name:event.target.value})}/></label><label>Sposób naliczania<select value={costForm.calculationMethod} onChange={(event) => setCostForm({...costForm,calculationMethod:event.target.value as EmployerCostComponent["calculationMethod"]})}><option value="PERCENT_BASE">Procent wynagrodzenia podstawowego</option><option value="PER_HOUR">Kwota za godzinę</option><option value="FIXED_PER_SHIFT">Kwota za zmianę</option></select></label><label>{costForm.calculationMethod === "PERCENT_BASE" ? "Procent" : `Kwota (${currency})`}<input type="number" min="0" step="0.01" value={costForm.calculationMethod === "PERCENT_BASE" ? costForm.value / 100 : costForm.value / 100} onChange={(event) => setCostForm({...costForm,value:Math.round(Number(event.target.value)*100)})}/></label><label>Typ umowy (opcjonalnie)<input value={costForm.contractType} onChange={(event) => setCostForm({...costForm,contractType:event.target.value})}/></label><label>Od<input type="date" value={costForm.validFrom} onChange={(event) => setCostForm({...costForm,validFrom:event.target.value})}/></label><label>Do (opcjonalnie)<input type="date" value={costForm.validTo} onChange={(event) => setCostForm({...costForm,validTo:event.target.value})}/></label><label>Podstawa / powód<input value={costForm.reason} onChange={(event) => setCostForm({...costForm,reason:event.target.value})}/></label><button className="secondary-button" disabled={busy || !costForm.code.trim() || !costForm.name.trim() || costForm.reason.trim().length < 5} onClick={() => void saveCostComponent()}><Plus/> Dodaj datowaną rewizję</button></div>}
      </section>
    </div>
  </aside></>;
}
