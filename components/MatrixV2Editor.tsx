"use client";

import {
  AlertTriangle, Archive, Boxes, Check, ChevronRight, CircleDollarSign, Clock3,
  Download, Edit3, FileSpreadsheet, GitBranch, Layers3, Link2, MapPin, Plus,
  Save, ShieldCheck, Upload, RefreshCw, Settings, Sparkles, Target, Users, X,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {
  OBJECTIVE_METRICS, WEEKDAYS, itemName, matrixV2ErrorMessage, matrixV2Settings, objectiveName,
  type MatrixV2Budget, type MatrixV2Duty, type MatrixV2Location,
  type MatrixV2Employee,
  type MatrixV2EmployeeDuty, type MatrixV2EmployeeLocation,
  type MatrixV2EmployeeRole, type MatrixV2PayRate, type MatrixV2TimeConstraint,
  type MatrixV2NamedItem, type MatrixV2Objective, type MatrixV2PayRule,
  type MatrixV2Role, type MatrixV2RoleDuty, type MatrixV2SaveKind,
  type MatrixV2Scenario, type MatrixV2ScenarioPayRule,
  type MatrixV2Settings,
  type MatrixV2ScenarioStrategy, type MatrixV2Shift,
  type MatrixV2StaffingRule, type MatrixV2Strategy, type MatrixV2Workspace,
  type MatrixV2PublicationReadiness,
} from "@/lib/matrix-v2";

type MatrixTab = "structure" | "workforce" | "staffing" | "strategies" | "finance";
type EditableItem = MatrixV2NamedItem | MatrixV2Shift | MatrixV2RoleDuty |
  MatrixV2Scenario | MatrixV2StaffingRule | MatrixV2Strategy | MatrixV2Objective |
  MatrixV2ScenarioStrategy | MatrixV2PayRule | MatrixV2ScenarioPayRule | MatrixV2Budget |
  MatrixV2EmployeeRole | MatrixV2EmployeeLocation | MatrixV2EmployeeDuty;
type EditTarget = { kind: MatrixV2SaveKind; item?: EditableItem | Record<string, unknown> };

const assignmentModeLabel: Record<string, string> = {
  REQUIRED: "Wymagany", OPTIONAL: "Opcjonalny", EXTRA: "Dodatkowy",
};
const operationLabel: Record<string, string> = {
  SET: "Ustaw", ADD: "Dodaj", MULTIPLY: "Pomnóż", REMOVE: "Usuń wymaganie",
};
const payMethodLabel: Record<string, string> = {
  FIXED_PER_SHIFT: "Stała kwota za zmianę",
  PER_HOUR: "Kwota za godzinę",
  PERCENT_BASE: "Procent stawki podstawowej",
  MULTIPLIER: "Mnożnik stawki",
  SHIFT_DURATION_THRESHOLD_PER_HOUR: "Dodatek po długości zmiany",
  MONTHLY_THRESHOLD_PER_HOUR: "Dodatek po progu miesięcznym",
};

function time(value?: string | null) { return value ? value.slice(0, 5) : "—"; }
function money(value: number | null | undefined, currency: string) {
  if (value === undefined || value === null) return "—";
  try {
    return new Intl.NumberFormat("pl-PL", { style: "currency", currency }).format(value / 100);
  } catch {
    return `${new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 2 }).format(value / 100)} ${currency}`;
  }
}
function plural(value: number, one: string, few: string, many: string) {
  if (value === 1) return `${value} ${one}`;
  if (value >= 2 && value <= 4) return `${value} ${few}`;
  return `${value} ${many}`;
}

function scenarioHasActiveStrategy(
  scenarioId: string,
  scenarios: MatrixV2Workspace["scenarios"],
  links: MatrixV2Workspace["scenarioStrategies"],
  activeStrategyIds: Set<string>,
) {
  const scenarioById = new Map(scenarios.map(scenario => [scenario.id, scenario]));
  const resolved = new Map<string, boolean>();
  const visited = new Set<string>();
  let current = scenarioById.get(scenarioId);
  let depth = 0;

  while (current) {
    if (depth > 32 || visited.has(current.id)) return false;
    const currentId = current.id;
    visited.add(currentId);
    for (const link of links.filter(item => item.scenario_id === currentId)) {
      if (!resolved.has(link.strategy_id)) resolved.set(link.strategy_id, link.active);
    }
    if (!current.parent_scenario_id) break;
    current = scenarioById.get(current.parent_scenario_id);
    depth += 1;
  }

  return [...resolved].some(([strategyId, active]) => active && activeStrategyIds.has(strategyId));
}

export function MatrixV2Editor({
  month, data, reload, notify, fail, focusEmployeeId,
}: {
  month: string;
  data: MatrixV2Workspace;
  reload: () => Promise<void>;
  notify: (message: string) => void;
  fail: (message: string) => void;
  focusEmployeeId?: string | null;
}) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [tab, setTab] = useState<MatrixTab>("structure");
  const [busy, setBusy] = useState(false);
  const [edit, setEdit] = useState<EditTarget | null>(null);
  const [employeeEdit, setEmployeeEdit] = useState<MatrixV2Employee | "new" | null>(null);
  const [publicationReadiness,setPublicationReadiness]=useState<MatrixV2PublicationReadiness|null>(null);
  const [importOpen,setImportOpen]=useState(false);
  const settings = matrixV2Settings(data.matrixVersion);
  const mixedCurrencyItems = data.financeVisible ? [
    ...(data.payRules ?? []),
    ...(data.scenarioBudgets ?? []),
    ...(data.employeePayRates ?? []),
  ].filter(item => String(item.currency ?? "").toUpperCase() !== settings.currency) : [];

  useEffect(() => {
    if (!data.financeVisible && tab === "finance") setTab("structure");
  }, [data.financeVisible, tab]);
  useEffect(()=>{if(focusEmployeeId)setTab("workforce");},[focusEmployeeId]);

  async function createDraft() {
    if (!supabase) return;
    const name = window.prompt("Nazwa nowej wersji roboczej:", `Matrix v${data.matrixVersion.version + 1}`);
    if (!name?.trim()) return;
    setBusy(true);
    const result = await supabase.rpc("matrix_v2_create_draft", { p_name: name.trim() });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return; }
    notify("Utworzono bezpieczną wersję roboczą Matrixa.");
    await reload();
  }

  async function publishDraft() {
    if (!supabase) return;
    const effective = window.prompt("Od kiedy ta wersja ma obowiązywać?", new Date().toISOString().slice(0, 10));
    if (!effective) return;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(effective)) { fail("Podaj datę w formacie RRRR-MM-DD."); return; }
    setBusy(true);
    const readiness=await supabase.rpc("matrix_v2_publication_readiness_alpha16",{p_effective_from:effective});
    if(readiness.error){setBusy(false);fail(matrixV2ErrorMessage(readiness.error.message));return;}
    const preflight=readiness.data as MatrixV2PublicationReadiness;
    setPublicationReadiness(preflight);
    if(!preflight.ready){setBusy(false);fail(`Nie można opublikować Matrixa: ${preflight.blockers.length} blokad. Szczegóły są widoczne nad zakładkami.`);return;}
    if (!window.confirm("Kontrola gotowości nie wykryła blokad. Opublikować tę wersję Matrixa? Poprzednia wersja pozostanie w historii, a nowe grafiki użyją nowej konfiguracji.")){setBusy(false);return;}
    const result = await supabase.rpc("matrix_v2_publish_draft", { p_effective_from: effective });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return; }
    notify("Nowa wersja Matrixa została opublikowana.");
    await reload();
  }

  async function save(kind: MatrixV2SaveKind, id: string | null, payload: Record<string, unknown>) {
    if (!supabase) return false;
    setBusy(true);
    const result = await supabase.rpc("matrix_v2_admin_save_alpha16", {
      p_kind: kind, p_id: id, p_data: payload,
    });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    notify("Zmiana została zapisana w wersji roboczej.");
    await reload();
    return true;
  }

  async function saveSettings(form: HTMLFormElement) {
    try {
      const currency = formText(form, "currency").toUpperCase();
      const timezone = formText(form, "timezone");
      if (!/^[A-Z]{3}$/.test(currency)) throw new Error("Waluta musi mieć trzyliterowy kod, np. PLN, EUR lub USD.");
      if (!timezone) throw new Error("Podaj strefę czasową Matrixa.");
      const minimumRestMinutes = requiredNumber(formText(form, "minimumRestMinutes"));
      const maximumShiftsPerDay = requiredNumber(formText(form, "maximumShiftsPerDay"));
      if (minimumRestMinutes < 0) throw new Error("Minimalny odpoczynek nie może być ujemny.");
      if (maximumShiftsPerDay < 1 || maximumShiftsPerDay > 24) throw new Error("Liczba przydziałów jednego pracownika dziennie musi mieścić się w zakresie od 1 do 24.");
      await save("MATRIX_SETTINGS", null, {
        currency,
        timezone,
        minimumRestMinutes,
        maximumShiftsPerDay,
        missingAvailabilityMeansAvailable: checked(form, "missingAvailabilityMeansAvailable"),
        requireOptimal: checked(form, "requireOptimal"),
      });
    } catch (error) {
      fail(error instanceof Error ? error.message : "Sprawdź ustawienia Matrixa.");
    }
  }

  async function saveTimeConstraint(input: {
    id: string | null; employeeId: string; kind: string;
    startsAt: string; endsAt: string; note: string;
  }) {
    if (!supabase) return false;
    let start:string,end:string;
    try{
      start=matrixLocalDateTimeToIso(input.startsAt,settings.timezone);
      end=matrixLocalDateTimeToIso(input.endsAt,settings.timezone);
      if(new Date(end)<=new Date(start))throw new Error("INVALID_RANGE");
    }catch{
      fail("Podaj prawidłowy przedział dostępności w strefie czasowej Matrixa."); return false;
    }
    setBusy(true);
    const result = await supabase.rpc("employee_time_constraint_save_v2", {
      p_id: input.id,
      p_employee_id: input.employeeId,
      p_kind: input.kind,
      p_starts_at: start,
      p_ends_at: end,
      p_note: input.note || null,
    });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    notify(input.id ? "Przedział został zaktualizowany z zachowaniem historii." : "Dodano przedział czasu pracownika.");
    await reload();
    return true;
  }

  async function revokeTimeConstraint(id: string) {
    if (!supabase || !window.confirm("Usunąć ten przedział? Poprzednia wersja pozostanie w historii.")) return false;
    setBusy(true);
    const result = await supabase.rpc("employee_time_constraint_revoke_v2", { p_id: id });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    notify("Przedział został wycofany.");
    await reload();
    return true;
  }

  async function savePayRate(input: {
    id: string | null; employeeId: string; validFrom: string; validTo: string;
    amount: string; contractType: string; active: boolean;
  }) {
    if (!supabase) return false;
    const amount = optionalNumber(input.amount, 100);
    if (!input.validFrom || amount === null || amount < 0 || (input.validTo && input.validTo < input.validFrom)) {
      fail("Sprawdź daty i stawkę pracownika."); return false;
    }
    setBusy(true);
    const result = await supabase.rpc("employee_pay_rate_save_v2", {
      p_id: input.id,
      p_employee_id: input.employeeId,
      p_valid_from: input.validFrom,
      p_valid_to: input.validTo || null,
      p_base_rate_minor: amount,
      p_currency: settings.currency,
      p_contract_type: input.contractType || null,
      p_active: input.active,
    });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    notify("Stawka została zapisana w chronionej historii finansowej.");
    await reload();
    return true;
  }

  async function saveEmployeeProfile(employeeId: string | null, payload: Record<string, unknown>) {
    if (!supabase) return false;
    setBusy(true);
    const result = await supabase.rpc("matrix_v2_employee_save_alpha16", {
      p_employee_id: employeeId, p_data: payload,
    });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    setEmployeeEdit(null);
    notify(employeeId ? "Dane pracownika zapisano w wersji roboczej." : `Pracownik został dodany z numerem ${String((result.data as {employeeNo?:string}|null)?.employeeNo??"")}.`);
    await reload();
    return true;
  }

  async function setEmployeeArchived(employee: MatrixV2Employee, archive: boolean) {
    if (!supabase) return false;
    let reason: string | null = null;
    if (archive) {
      reason = window.prompt(`Powód archiwizacji: ${employee.firstName} ${employee.lastName}`, "") ?? null;
      if (reason === null) return false;
    } else if (!window.confirm(`Przywrócić pracownika ${employee.firstName} ${employee.lastName} do bieżącej wersji Matrixa?`)) return false;
    setBusy(true);
    const result = await supabase.rpc("matrix_v2_employee_archive_v2", {
      p_employee_id: employee.id, p_reason: reason, p_archive: archive,
    });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    notify(archive ? "Pracownik został zarchiwizowany w wersji roboczej." : "Pracownik został przywrócony w wersji roboczej.");
    await reload();
    return true;
  }

  const activeRoles = data.roles.filter(item => item.active);
  const activeLocations = data.locations.filter(item => item.active);
  const activeDuties = data.duties.filter(item => item.active);
  const activeShifts = data.shiftTemplates.filter(item => item.active);
  const activeScenarios = data.scenarios.filter(item => item.active);
  const activeStrategies = data.strategies.filter(item => item.active);
  const activeStrategyIds = new Set(activeStrategies.map(strategy => strategy.id));
  const defaultScenarioCount = activeScenarios.filter(item => item.is_default).length;
  const unlinkedScenarios = activeScenarios.filter(scenario => !scenarioHasActiveStrategy(
    scenario.id,
    data.scenarios,
    data.scenarioStrategies,
    activeStrategyIds,
  ));
  const incompleteStrategies = activeStrategies.filter(strategy => !data.strategyObjectives.some(objective =>
    objective.strategy_id === strategy.id && objective.active && objective.tier === 1 && objective.metric_code === "UNFILLED",
  ));

  return <section className="matrix-v2-shell">
    <header className="matrix-v2-header">
      <div>
        <p className="eyebrow">MATRIX ORGANIZACJI • MODEL DYNAMICZNY</p>
        <h2>{data.matrixVersion.name}</h2>
        <p>Role, obowiązki, scenariusze, koszty i sposoby optymalizacji są częścią wersjonowanej konfiguracji firmy.</p>
      </div>
      <div className="matrix-v2-header-actions">
        <span className={`matrix-v2-version ${data.editable ? "draft" : "active"}`}>
          {data.editable ? "WERSJA ROBOCZA" : "AKTYWNY"} • v{data.matrixVersion.version}
        </span>
        {data.editable
          ? <><button className="secondary-button" disabled={busy} onClick={()=>setImportOpen(true)}><FileSpreadsheet/> Import Excel</button><button className="primary-button" disabled={busy} onClick={() => void publishDraft()}><Check/> Opublikuj Matrix</button></>
          : <button className="primary-button" disabled={busy} onClick={() => void createDraft()}><Plus/> Nowa wersja robocza</button>}
      </div>
    </header>

    <MatrixSettingsCard settings={settings} editable={data.editable} busy={busy} save={saveSettings}/>

    {mixedCurrencyItems.length > 0 && <div className="matrix-v2-validation warning"><AlertTriangle/><span><strong>Dane finansowe mają różne waluty</strong><small>Stawki, dodatki i budżety muszą używać waluty {settings.currency}. Popraw je przed publikacją Matrixa.</small></span></div>}

    {publicationReadiness&&!publicationReadiness.ready&&<section className="matrix-v2-readiness"><div><AlertTriangle/><span><strong>Publikacja Matrixa jest zablokowana</strong><small>{publicationReadiness.blockers.length} problemów wymaga poprawy. Kliknij pracownika, aby przejść do jego danych.</small></span></div>{publicationReadiness.blockers.map(blocker=><button key={`${blocker.code}:${blocker.employeeId}`} onClick={()=>{setTab("workforce");setEmployeeEdit(data.employees.find(employee=>employee.id===blocker.employeeId)??null);}}><span><b>{blocker.employeeName}</b><small>{blocker.employeeNo} • {blocker.message}</small></span><ChevronRight/></button>)}</section>}

    <div className="matrix-v2-summary">
      <span><Users/><small>Aktywni pracownicy</small><strong>{data.workforceCounts?.active ?? data.employees.filter(employee=>employee.active).length}</strong></span>
      <span><Users/><small>Role</small><strong>{activeRoles.length}</strong></span>
      <span><MapPin/><small>Lokale</small><strong>{activeLocations.length}</strong></span>
      <span><Boxes/><small>Obowiązki</small><strong>{activeDuties.length}</strong></span>
      <span><Clock3/><small>Szablony zmian</small><strong>{activeShifts.length}</strong></span>
      <span><GitBranch/><small>Scenariusze</small><strong>{activeScenarios.length}</strong></span>
      <span><Sparkles/><small>Strategie</small><strong>{activeStrategies.length}</strong></span>
    </div>

    <nav className="matrix-v2-tabs">
      <button className={tab === "structure" ? "active" : ""} onClick={() => setTab("structure")}><Layers3/> Struktura firmy</button>
      <button className={tab === "workforce" ? "active" : ""} onClick={() => setTab("workforce")}><Users/> Pracownicy i dostępność</button>
      <button className={tab === "staffing" ? "active" : ""} onClick={() => setTab("staffing")}><Users/> Scenariusze i obsada</button>
      <button className={tab === "strategies" ? "active" : ""} onClick={() => setTab("strategies")}><Target/> Strategie wariantów</button>
      {data.financeVisible && <button className={tab === "finance" ? "active" : ""} onClick={() => setTab("finance")}><CircleDollarSign/> Dodatki i budżety</button>}
    </nav>

    {!data.editable && <div className="matrix-v2-readonly"><ShieldCheck/><span><strong>Oglądasz opublikowaną konfigurację</strong><small>Utwórz wersję roboczą, aby bezpiecznie wprowadzić zmiany bez wpływu na istniejące grafiki.</small></span></div>}

    {tab === "structure" && <StructureTab data={data} editable={data.editable} edit={setEdit}/>}
    {tab === "workforce" && <WorkforceTab data={data} month={month} editable={data.editable} busy={busy} edit={setEdit} editProfile={setEmployeeEdit} setArchived={setEmployeeArchived} saveTime={saveTimeConstraint} revokeTime={revokeTimeConstraint} saveRate={savePayRate} focusEmployeeId={focusEmployeeId}/>}
    {tab === "staffing" && <StaffingTab data={data} editable={data.editable} edit={setEdit} defaultScenarioCount={defaultScenarioCount}/>}
    {tab === "strategies" && <StrategiesTab data={data} editable={data.editable} edit={setEdit} unlinkedScenarios={unlinkedScenarios} incompleteStrategies={incompleteStrategies}/>}
    {tab === "finance" && data.financeVisible && <FinanceTab data={data} editable={data.editable} edit={setEdit}/>}

    {edit && (
      <MatrixV2Drawer key={`${edit.kind}:${String((edit.item as {id?: string} | undefined)?.id ?? "new")}`} target={edit} data={data} month={month} busy={busy} close={() => setEdit(null)} save={async (kind, id, payload) => {
        const ok = await save(kind, id, payload);
        if (ok) setEdit(null);
        return ok;
      }}/>
    )}
    {employeeEdit && <EmployeeProfileDrawer employee={employeeEdit==="new"?null:employeeEdit} data={data} month={month} busy={busy} close={()=>setEmployeeEdit(null)} save={saveEmployeeProfile}/>}
    {importOpen&&<MatrixExcelImport data={data} busy={busy} setBusy={setBusy} close={()=>setImportOpen(false)} reload={reload} notify={notify} fail={fail}/>}
  </section>;
}

function SectionHead({title, description, editable, add, disabled}: {title: string; description: string; editable: boolean; add: () => void; disabled?: boolean}) {
  return <div className="matrix-v2-section-head"><div><h3>{title}</h3><p>{description}</p></div>{editable && <button className="secondary-button" disabled={disabled} onClick={add}><Plus/> Dodaj</button>}</div>;
}

function MatrixSettingsCard({
  settings, editable, busy, save,
}: {
  settings: MatrixV2Settings;
  editable: boolean;
  busy: boolean;
  save: (form: HTMLFormElement) => Promise<void>;
}) {
  return <section className="matrix-v2-settings-card">
    <div className="matrix-v2-settings-head">
      <Settings/>
      <span><strong>Ustawienia całego Matrixa</strong><small>Jedna waluta, strefa czasowa i wspólne reguły bezpieczeństwa obowiązują wszystkie scenariusze.</small></span>
      <em>{settings.currency}</em>
    </div>
    <form key={`${settings.currency}:${settings.timezone}:${settings.minimumRestMinutes}:${settings.maximumShiftsPerDay}:${settings.missingAvailabilityMeansAvailable}:${settings.requireOptimal}`} onSubmit={event=>{event.preventDefault();void save(event.currentTarget);}}>
      <label>Waluta rozliczeniowa
        <input name="currency" required minLength={3} maxLength={3} pattern="[A-Za-z]{3}" disabled={!editable} defaultValue={settings.currency} onChange={event=>{event.currentTarget.value=event.currentTarget.value.toUpperCase();}}/>
        <small>Trzyliterowy kod, np. PLN, EUR lub USD.</small>
      </label>
      <label>Strefa czasowa
        <input name="timezone" required list="matrix-timezones" disabled={!editable} defaultValue={settings.timezone}/>
        <datalist id="matrix-timezones"><option value="Europe/Warsaw"/><option value="Europe/London"/><option value="Europe/Berlin"/><option value="UTC"/></datalist>
      </label>
      <label>Minimalny odpoczynek (minuty)
        <input name="minimumRestMinutes" type="number" min="0" step="15" required disabled={!editable} defaultValue={settings.minimumRestMinutes}/>
      </label>
      <label>Maks. przydziałów jednego pracownika dziennie
        <input name="maximumShiftsPerDay" type="number" min="1" max="24" step="1" required disabled={!editable} defaultValue={settings.maximumShiftsPerDay}/>
        <small>To limit bezpieczeństwa pracownika, nie limit liczby szablonów. W Matrixie możesz dodać dowolną liczbę zmian i krótkich bloków obsady.</small>
      </label>
      <label className="check-label"><input name="missingAvailabilityMeansAvailable" type="checkbox" disabled={!editable} defaultChecked={settings.missingAvailabilityMeansAvailable}/> Brak wpisu dostępności oznacza dostępność</label>
      <label className="check-label"><input name="requireOptimal" type="checkbox" disabled={!editable} defaultChecked={settings.requireOptimal}/> Wymagaj matematycznie optymalnego wyniku</label>
      {editable && <button className="primary-button" disabled={busy}><Save/> {busy ? "Zapisuję…" : "Zapisz ustawienia"}</button>}
    </form>
  </section>;
}

function StructureTab({data, editable, edit}: {data: MatrixV2Workspace; editable: boolean; edit: (value: EditTarget) => void}) {
  return <div className="matrix-v2-tab-content">
    <div className="matrix-v2-entity-grid">
      <EntityPanel title="Role" description="Dowolne zespoły i stanowiska" items={data.roles} editable={editable} add={() => edit({kind: "ROLE"})} edit={item => edit({kind: "ROLE", item})}/>
      <EntityPanel title="Lokale" description="Miejsca, w których powstaje grafik" items={data.locations} editable={editable} add={() => edit({kind: "LOCATION"})} edit={item => edit({kind: "LOCATION", item})}/>
      <EntityPanel title="Obowiązki" description="Umiejętności i funkcje na zmianie" items={data.duties} editable={editable} add={() => edit({kind: "DUTY"})} edit={item => edit({kind: "DUTY", item})}/>
    </div>
    <section className="matrix-v2-card">
      <SectionHead title="Zmiany i bloki zapotrzebowania" description="Dodaj dowolną liczbę pełnych zmian oraz krótkich, nakładających się bloków dodatkowej obsady. Nie ma limitu siedmiu pozycji." editable={editable} disabled={!data.locations.length} add={() => edit({kind: "SHIFT"})}/>
      <div className="matrix-v2-table">
        {data.shiftTemplates.map(shift => <button key={shift.id} onClick={() => editable && edit({kind: "SHIFT", item: shift})}>
          <span><i style={{background: shift.color ?? "#7257d8"}}/><b>{shift.name}</b><small>{itemName(data.locations, shift.location_id)}</small></span>
          <span>{time(shift.starts_at)}–{time(shift.ends_at)}{shift.ends_next_day ? " • następny dzień" : ""} • {shiftPeriodLabel(shift.shift_period)}</span>
          <span>{WEEKDAYS.filter(day => shift.day_mask.includes(day.value)).map(day => day.label).join(", ")}</span>
          <em className={shift.active ? "on" : "off"}>{shift.active ? "Aktywna" : "Wyłączona"}</em>
          {editable && <Edit3/>}
        </button>)}
        {!data.shiftTemplates.length && <p className="matrix-v2-empty">Nie dodano jeszcze szablonów zmian.</p>}
      </div>
    </section>
    <section className="matrix-v2-card">
      <SectionHead title="Obowiązki przypisane do ról" description="Określ, co jest wymagane, opcjonalne lub dodatkowe dla każdej roli." editable={editable} disabled={!data.roles.length || !data.duties.length} add={() => edit({kind: "ROLE_DUTY"})}/>
      <div className="matrix-v2-link-grid">
        {data.roleDuties.map(link => <button key={link.id} onClick={() => editable && edit({kind: "ROLE_DUTY", item: link})}>
          <Link2/><span><strong>{itemName(data.roles, link.role_id)} → {itemName(data.duties, link.duty_id)}</strong><small>{assignmentModeLabel[link.assignment_mode]}{link.minimum_count ? ` • minimum ${link.minimum_count}` : ""}{link.shift_obligation?` • obowiązek ${shiftPeriodLabel(link.shift_period)}`:" • bez ograniczenia okresu"} • {link.active ? "relacja aktywna" : "relacja wyłączona"}</small></span>{editable && <ChevronRight/>}
        </button>)}
        {!data.roleDuties.length && <p className="matrix-v2-empty">Role nie mają jeszcze przypisanych obowiązków.</p>}
      </div>
    </section>
  </div>;
}

function EntityPanel({title, description, items, editable, add, edit}: {title: string; description: string; items: MatrixV2NamedItem[]; editable: boolean; add: () => void; edit: (item: MatrixV2NamedItem) => void}) {
  return <section className="matrix-v2-card">
    <SectionHead title={title} description={description} editable={editable} add={add}/>
    <div className="matrix-v2-entities">
      {items.map(item => <button key={item.id} onClick={() => editable && edit(item)}><i style={{background: item.color ?? "#7257d8"}}/><span><strong>{item.name}</strong>{item.description && <small>{item.description}</small>}</span><em className={item.active ? "on" : "off"}>{item.active ? "Aktywna" : "Wyłączona"}</em>{editable && <Edit3/>}</button>)}
      {!items.length && <p className="matrix-v2-empty">Brak elementów.</p>}
    </div>
  </section>;
}

function localDateTimeInput(value: string | null | undefined, timezone: string) {
  if (!value) return "";
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "";
  const parts=Object.fromEntries(new Intl.DateTimeFormat("en-CA",{
    timeZone:timezone,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hourCycle:"h23",
  }).formatToParts(date).filter(part=>part.type!=="literal").map(part=>[part.type,part.value]));
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
}

function matrixLocalDateTimeToIso(value: string, timezone: string) {
  if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value))throw new Error("INVALID_LOCAL_DATETIME");
  const intended=Date.parse(`${value}:00Z`);
  if(!Number.isFinite(intended))throw new Error("INVALID_LOCAL_DATETIME");
  const offsetAt=(instant:number)=>{
    const parts=Object.fromEntries(new Intl.DateTimeFormat("en-CA",{
      timeZone:timezone,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit",hourCycle:"h23",
    }).formatToParts(new Date(instant)).filter(part=>part.type!=="literal").map(part=>[part.type,part.value]));
    return Date.UTC(Number(parts.year),Number(parts.month)-1,Number(parts.day),Number(parts.hour),Number(parts.minute),Number(parts.second))-instant;
  };
  let instant=intended-offsetAt(intended);
  instant=intended-offsetAt(instant);
  const result=new Date(instant).toISOString();
  if(localDateTimeInput(result,timezone)!==value)throw new Error("NONEXISTENT_LOCAL_DATETIME");
  return result;
}

function dateTimeLabel(value: string, timezone: string) {
  return new Intl.DateTimeFormat("pl-PL", {
    day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit",
    timeZone: timezone,
  }).format(new Date(value));
}

function shiftPeriodLabel(value?: string | null){
  return value==="MORNING"?"poranna":value==="EVENING"?"wieczorna":"środek";
}

function WorkforceTab({
  data,month,editable,busy,edit,editProfile,setArchived,saveTime,revokeTime,saveRate,focusEmployeeId,
}: {
  data: MatrixV2Workspace; month: string; editable: boolean; busy: boolean;
  edit: (value: EditTarget) => void;
  editProfile: (value: MatrixV2Employee | "new") => void;
  setArchived: (employee: MatrixV2Employee, archive: boolean) => Promise<boolean>;
  saveTime: (input: {id:string|null;employeeId:string;kind:string;startsAt:string;endsAt:string;note:string}) => Promise<boolean>;
  revokeTime: (id:string) => Promise<boolean>;
  saveRate: (input: {id:string|null;employeeId:string;validFrom:string;validTo:string;amount:string;contractType:string;active:boolean}) => Promise<boolean>;
  focusEmployeeId?:string|null;
}) {
  const employees = data.employees ?? [];
  const settings = matrixV2Settings(data.matrixVersion),currency=settings.currency,timezone=settings.timezone;
  const [employeeId,setEmployeeId] = useState(focusEmployeeId&&employees.some(employee=>employee.id===focusEmployeeId)?focusEmployeeId:employees.find(employee=>employee.active)?.id ?? employees[0]?.id ?? "");
  const [timeEdit,setTimeEdit] = useState<MatrixV2TimeConstraint | null>(null);
  const [rateEdit,setRateEdit] = useState<MatrixV2PayRate | null>(null);
  const employee = employees.find(item=>item.id===employeeId) ?? employees[0];
  const employeeRoles = (data.employeeRoles ?? []).filter(item=>item.employee_id===employee?.id);
  const employeeLocations = (data.employeeLocations ?? []).filter(item=>item.employee_id===employee?.id);
  const employeeDuties = (data.employeeDuties ?? []).filter(item=>item.employee_id===employee?.id);
  const constraints = (data.timeConstraints ?? []).filter(item=>item.employeeId===employee?.id)
    .sort((a,b)=>a.startsAt.localeCompare(b.startsAt));
  const rates = (data.employeePayRates ?? []).filter(item=>item.employee_id===employee?.id)
    .sort((a,b)=>b.valid_from.localeCompare(a.valid_from));

  useEffect(()=>{
    if (!employeeId && employees[0]) setEmployeeId(employees[0].id);
  },[employeeId,employees]);
  useEffect(()=>{if(focusEmployeeId&&employees.some(item=>item.id===focusEmployeeId))setEmployeeId(focusEmployeeId);},[focusEmployeeId,employees]);

  if (!employee) return <div className="matrix-v2-tab-content"><section className="matrix-v2-card"><SectionHead title="Pracownicy" description="Dodaj rzeczywistych pracowników, a następnie przypisz im dynamiczne role i lokale." editable={editable} add={()=>editProfile("new")}/><p className="matrix-v2-empty">Brak pracowników do skonfigurowania.</p></section></div>;

  return <div className="matrix-v2-tab-content matrix-v2-workforce">
    <section className="matrix-v2-card workforce-picker">
      <div><h3>Konfiguracja pracownika</h3><p>{data.workforceCounts?.active ?? employees.filter(item=>item.active).length} aktywnych • {data.workforceCounts?.archived ?? employees.filter(item=>!item.active).length} w archiwum. Zmiany profilu trafiają wyłącznie do wersji roboczej.</p></div>
      <label>Pracownik<select value={employee.id} onChange={event=>{setEmployeeId(event.target.value);setTimeEdit(null);setRateEdit(null);}}>{employees.map(item=><option value={item.id} key={item.id}>{item.firstName} {item.lastName} • {item.employeeNo}{item.active?"":" • archiwalny"}</option>)}</select></label>
      {editable&&<button className="secondary-button" onClick={()=>editProfile("new")}><Plus/> Dodaj pracownika</button>}
    </section>

    <section className={`matrix-v2-card workforce-profile ${employee.active?"":"archived"}`}>
      <div><Users/><span><small>{employee.employeeNo}</small><h3>{employee.firstName} {employee.lastName}</h3><p>{employee.primaryRoleId?itemName(data.roles,employee.primaryRoleId):"Brak roli podstawowej"} • {employeeLocations.filter(item=>item.active&&item.standard_allowed).map(item=>itemName(data.locations,item.location_id)).join(", ")||"Brak zwykłego lokalu pracy"}</p></span></div>
      <dl><div><dt>Status</dt><dd>{employee.active?"Aktywny":"Archiwalny"}</dd></div><div><dt>Nominał</dt><dd>{Math.round(Number(employee.nominalMonthlyMinutes??0)/60)} godz./mies.</dd></div><div><dt>Limit tygodniowy</dt><dd>{Math.round(Number(employee.maximumWeeklyMinutes??0)/60)} godz.</dd></div><div><dt>Zatrudnienie</dt><dd>{employee.employmentStart??"bez daty"}{employee.employmentEnd?` – ${employee.employmentEnd}`:""}</dd></div></dl>
      {employee.archiveReason&&<p className="matrix-v2-form-hint">Powód archiwizacji: {employee.archiveReason}</p>}
      {editable&&<div className="workforce-profile-actions"><button className="secondary-button" onClick={()=>editProfile(employee)}><Edit3/> Edytuj dane</button>{employee.active?<button className="danger-button" disabled={busy} onClick={()=>void setArchived(employee,true)}><Archive/> Archiwizuj</button>:<button className="secondary-button" disabled={busy} onClick={()=>void setArchived(employee,false)}><RefreshCw/> Przywróć</button>}</div>}
    </section>

    <div className="matrix-v2-entity-grid workforce-links">
      <WorkforceLinks title="Role" items={employeeRoles.map(item=>({
        id:item.id,label:itemName(data.roles,item.role_id),detail:[item.is_primary?"podstawowa":"dodatkowa",item.can_lead?"może prowadzić":null,!item.active?"wyłączona":null].filter(Boolean).join(" • "),item,
      }))} editable={editable} add={()=>edit({kind:"EMPLOYEE_ROLE",item:{employee_id:employee.id}})} edit={item=>edit({kind:"EMPLOYEE_ROLE",item})}/>
      <WorkforceLinks title="Lokale" items={employeeLocations.map(item=>({
        id:item.id,label:itemName(data.locations,item.location_id),detail:[item.standard_allowed?"w zwykłym limicie":null,item.overtime_allowed?"dopuszczony również w nadgodzinach":null,!item.active?"wyłączony":null].filter(Boolean).join(" • "),item,
      }))} editable={editable} add={()=>edit({kind:"EMPLOYEE_LOCATION",item:{employee_id:employee.id}})} edit={item=>edit({kind:"EMPLOYEE_LOCATION",item})}/>
      <WorkforceLinks title="Obowiązki i kompetencje" items={employeeDuties.map(item=>({
        id:item.id,label:itemName(data.duties,item.duty_id),detail:[item.role_id?itemName(data.roles,item.role_id):"wszystkie role",item.location_id?itemName(data.locations,item.location_id):"wszystkie lokale",!item.active?"wyłączony":null].filter(Boolean).join(" • "),item,
      }))} editable={editable} add={()=>edit({kind:"EMPLOYEE_DUTY",item:{employee_id:employee.id}})} edit={item=>edit({kind:"EMPLOYEE_DUTY",item})}/>
    </div>

    <section className="matrix-v2-card">
      <SectionHead title="Nadrzędne ograniczenia pracodawcy" description="Pracownik ustawia wiele okien dostępności w swoim portalu. Tutaj pracodawca zapisuje tylko nadrzędną blokadę, urlop lub L4." editable={editable} add={()=>setTimeEdit(null)}/>
      <div className="matrix-v2-time-list">
        {constraints.filter(item=>item.source==="MANAGER"||["UNAVAILABLE","LEAVE","SICKNESS"].includes(item.kind)).map(item=><article key={item.id}><Clock3/><span><strong>{item.kind==="UNAVAILABLE"?"Niedostępny":item.kind==="LEAVE"?"Urlop":"L4"}</strong><small>{dateTimeLabel(item.startsAt,timezone)} – {dateTimeLabel(item.endsAt,timezone)}{item.note?` • ${item.note}`:""}</small></span>{editable&&<><button className="secondary-button" onClick={()=>setTimeEdit(item)}><Edit3/> Edytuj</button><button className="icon-button" disabled={busy} title="Wycofaj" onClick={()=>void revokeTime(item.id)}><X/></button></>}</article>)}
        {!constraints.some(item=>item.source==="MANAGER"||["UNAVAILABLE","LEAVE","SICKNESS"].includes(item.kind))&&<p className="matrix-v2-empty">Brak nadrzędnych ograniczeń pracodawcy. Okna zadeklarowane przez pracownika są widoczne w jego portalu.</p>}
      </div>
      {editable&&<form className="matrix-v2-inline-form" key={`${employee.id}:${timeEdit?.id??"new"}`} onSubmit={event=>{event.preventDefault();const form=new FormData(event.currentTarget);void saveTime({id:timeEdit?.id??null,employeeId:employee.id,kind:String(form.get("kind")),startsAt:String(form.get("startsAt")),endsAt:String(form.get("endsAt")),note:String(form.get("note")??"")}).then(ok=>{if(ok)setTimeEdit(null);});}}>
        <label>Rodzaj<select name="kind" defaultValue={timeEdit?.kind??"UNAVAILABLE"}><option value="UNAVAILABLE">Niedostępny — blokada pracodawcy</option><option value="LEAVE">Urlop</option><option value="SICKNESS">L4</option></select></label>
        <label>Od<input name="startsAt" type="datetime-local" required defaultValue={localDateTimeInput(timeEdit?.startsAt,timezone) || `${month}-01T08:00`}/></label>
        <label>Do<input name="endsAt" type="datetime-local" required defaultValue={localDateTimeInput(timeEdit?.endsAt,timezone) || `${month}-01T16:00`}/></label>
        <label>Notatka<input name="note" defaultValue={timeEdit?.note??""}/></label>
        <button className="primary-button" disabled={busy}><Save/> {timeEdit?"Zapisz nową wersję":"Dodaj przedział"}</button>
      </form>}
    </section>

    {data.financeVisible&&<section className="matrix-v2-card">
      <div className="matrix-v2-section-head"><div><h3>Chroniona historia stawki</h3><p>Solver używa stawki obowiązującej w miesiącu grafiku; starsze okresy pozostają odtwarzalne.</p></div><ShieldCheck/></div>
      <div className="matrix-v2-time-list">
        {rates.map(item=><article key={item.id}><CircleDollarSign/><span><strong>{money(item.base_rate_minor, currency)}</strong><small>od {item.valid_from}{item.valid_to?` do ${item.valid_to}`:" • bez daty końcowej"}{item.contract_type?` • ${item.contract_type}`:""}{item.active?"":" • nieaktywna"}</small></span><button className="secondary-button" onClick={()=>setRateEdit(item)}><Edit3/> Edytuj</button></article>)}
        {!rates.length&&<p className="matrix-v2-empty">Nie zapisano jeszcze stawki v2.</p>}
      </div>
      <form className="matrix-v2-inline-form rates" key={`${employee.id}:${rateEdit?.id??"new"}`} onSubmit={event=>{event.preventDefault();const form=new FormData(event.currentTarget);void saveRate({id:rateEdit?.id??null,employeeId:employee.id,validFrom:String(form.get("validFrom")),validTo:String(form.get("validTo")??""),amount:String(form.get("amount")),contractType:String(form.get("contractType")??""),active:form.has("active")}).then(ok=>{if(ok)setRateEdit(null);});}}>
        <label>Od<input name="validFrom" type="date" required defaultValue={rateEdit?.valid_from??`${month}-01`}/></label>
        <label>Do<input name="validTo" type="date" defaultValue={rateEdit?.valid_to??""}/></label>
        <label>Stawka godzinowa ({currency})<input name="amount" type="number" min="0" step="0.01" required defaultValue={minorToInput(rateEdit?.base_rate_minor)}/></label>
        <label>Rodzaj umowy<input name="contractType" defaultValue={rateEdit?.contract_type??""}/></label>
        <label className="check-label"><input name="active" type="checkbox" defaultChecked={rateEdit?.active??true}/> Aktywna</label>
        <button className="primary-button" disabled={busy}><Save/> Zapisz stawkę</button>
      </form>
    </section>}
  </div>;
}

function WorkforceLinks({title,items,editable,add,edit}:{title:string;items:{id:string;label:string;detail:string;item:Record<string,unknown>}[];editable:boolean;add:()=>void;edit:(item:Record<string,unknown>)=>void}) {
  return <section className="matrix-v2-card"><SectionHead title={title} description="" editable={editable} add={add}/><div className="matrix-v2-entities">{items.map(row=><button key={row.id} onClick={()=>editable&&edit(row.item)}><span><strong>{row.label}</strong><small>{row.detail}</small></span>{editable&&<Edit3/>}</button>)}{!items.length&&<p className="matrix-v2-empty">Brak przypisań.</p>}</div></section>;
}

function StaffingTab({data, editable, edit, defaultScenarioCount}: {data: MatrixV2Workspace; editable: boolean; edit: (value: EditTarget) => void; defaultScenarioCount: number}) {
  return <div className="matrix-v2-tab-content">
    {defaultScenarioCount !== 1 && <div className="matrix-v2-validation warning"><AlertTriangle/><span><strong>Wymagany jest jeden scenariusz domyślny</strong><small>Publikacja będzie zablokowana, dopóki nie wybierzesz dokładnie jednego aktywnego scenariusza domyślnego.</small></span></div>}
    <section className="matrix-v2-card">
      <SectionHead title="Scenariusze operacyjne" description="Scenariusz może dziedziczyć bazową konfigurację i zmieniać tylko wybrane wartości." editable={editable} add={() => edit({kind: "SCENARIO"})}/>
      <div className="matrix-v2-scenario-grid">
        {data.scenarios.map(scenario => <article key={scenario.id} className={!scenario.active ? "inactive" : ""}>
          <i style={{background: scenario.color ?? "#7457e8"}}/>
          <span><small>{scenario.is_default ? "DOMYŚLNY" : scenario.parent_scenario_id ? `DZIEDZICZY: ${itemName(data.scenarios, scenario.parent_scenario_id)}` : "NIEZALEŻNY"}</small><h4>{scenario.name}</h4><p>{scenario.description || "Bez dodatkowego opisu"}{Object.keys(scenario.settings_overrides ?? {}).length ? ` • ${Object.keys(scenario.settings_overrides ?? {}).length} nadpis. reguł` : ""}</p></span>
          {editable && <button onClick={() => edit({kind: "SCENARIO", item: scenario})}><Edit3/> Edytuj</button>}
        </article>)}
      </div>
    </section>
    <section className="matrix-v2-card">
      <SectionHead title="Reguły wymaganej obsady" description="Każda reguła wskazuje scenariusz, zmianę, rolę i opcjonalny obowiązek." editable={editable} disabled={!data.scenarios.length || !data.shiftTemplates.length || !data.roles.length} add={() => edit({kind: "STAFFING_RULE"})}/>
      <div className="matrix-v2-table staffing">
        {data.staffingRules.map(rule => <button key={rule.id} onClick={() => editable && edit({kind: "STAFFING_RULE", item: rule})}>
          <span><b>{itemName(data.scenarios, rule.scenario_id)}</b><small>{itemName(data.shiftTemplates, rule.shift_template_id)}</small></span>
          <span>{itemName(data.roles, rule.role_id)}{rule.duty_id ? ` • ${itemName(data.duties, rule.duty_id)}` : ""}</span>
          <strong>{staffingValue(rule)}</strong>
          <em className={rule.active ? "on" : "off"}>{rule.active ? "Aktywna" : "Wyłączona"}</em>
          {editable && <Edit3/>}
        </button>)}
        {!data.staffingRules.length && <p className="matrix-v2-empty">Nie dodano jeszcze reguł obsady.</p>}
      </div>
    </section>
  </div>;
}

function staffingValue(rule: MatrixV2StaffingRule) {
  if (rule.operation === "REMOVE") return "Usuń wymaganie";
  if (rule.operation === "MULTIPLY") return `${operationLabel[rule.operation]} × ${Number(rule.multiplier_basis_points ?? 0) / 10000}`;
  return `${operationLabel[rule.operation]} ${rule.count_value ?? 0} os.`;
}

function StrategiesTab({data, editable, edit, unlinkedScenarios, incompleteStrategies}: {data: MatrixV2Workspace; editable: boolean; edit: (value: EditTarget) => void; unlinkedScenarios: MatrixV2Scenario[]; incompleteStrategies: MatrixV2Strategy[]}) {
  return <div className="matrix-v2-tab-content">
    {(unlinkedScenarios.length > 0 || incompleteStrategies.length > 0) && <div className="matrix-v2-validation warning"><AlertTriangle/><span><strong>Konfiguracja strategii wymaga uzupełnienia</strong><small>{unlinkedScenarios.length ? `${plural(unlinkedScenarios.length, "scenariusz nie ma", "scenariusze nie mają", "scenariuszy nie ma")} aktywnej strategii. ` : ""}{incompleteStrategies.length ? `${plural(incompleteStrategies.length, "strategia nie zaczyna", "strategie nie zaczynają", "strategii nie zaczyna")} się od minimalizacji braków.` : ""}</small></span></div>}
    <section className="matrix-v2-card">
      <SectionHead title="Strategie tworzenia wariantów" description="Każda aktywna strategia tworzy jeden osobno policzony wariant grafiku." editable={editable} add={() => edit({kind: "STRATEGY"})}/>
      <div className="matrix-v2-strategy-grid">
        {data.strategies.map(strategy => {
          const objectives = data.strategyObjectives.filter(item => item.strategy_id === strategy.id).sort((a,b) => a.tier-b.tier || a.sort_order-b.sort_order);
          const scenarios = data.scenarioStrategies.filter(item => item.strategy_id === strategy.id && item.active).map(item => itemName(data.scenarios, item.scenario_id));
          return <article key={strategy.id} className={!strategy.active ? "inactive" : ""}>
            <div><span><small>WARIANT OPTYMALIZACJI</small><h4>{strategy.name}</h4></span>{editable && <button onClick={() => edit({kind: "STRATEGY", item: strategy})}><Edit3/></button>}</div>
            <p>{strategy.description || "Strategia bez dodatkowego opisu."}</p>
            <div className="matrix-v2-objectives">{objectives.map(objective => <button disabled={!editable} key={objective.id} onClick={() => editable && edit({kind: "OBJECTIVE", item: objective})}><b>Poziom {objective.tier}</b><span>{objectiveName(objective.metric_code)}</span><em>{objective.direction === "MINIMIZE" ? "minimalizuj" : "maksymalizuj"}</em></button>)}</div>
            {editable && <button className="matrix-v2-add-inline" onClick={() => edit({kind: "OBJECTIVE", item: {strategy_id: strategy.id} as MatrixV2Objective})}><Plus/> Dodaj kryterium</button>}
            <small className="matrix-v2-used-by">Scenariusze: {scenarios.length ? scenarios.join(", ") : "brak"}</small>
          </article>;
        })}
      </div>
    </section>
    <section className="matrix-v2-card">
      <SectionHead title="Strategie dostępne w scenariuszach" description="Liczba aktywnych powiązań określa liczbę wariantów generowanych dla danego scenariusza." editable={editable} disabled={!data.scenarios.length || !data.strategies.length} add={() => edit({kind: "SCENARIO_STRATEGY"})}/>
      <div className="matrix-v2-link-grid">
        {data.scenarioStrategies.map(link => <button key={link.id} onClick={() => editable && edit({kind: "SCENARIO_STRATEGY", item: link})}><GitBranch/><span><strong>{itemName(data.scenarios, link.scenario_id)} → {itemName(data.strategies, link.strategy_id)}</strong><small>{link.active ? "Wariant aktywny" : "Wariant wyłączony"}{scenarioStrategySummary(link)}</small></span>{editable && <ChevronRight/>}</button>)}
      </div>
    </section>
  </div>;
}

function FinanceTab({data, editable, edit}: {data: MatrixV2Workspace; editable: boolean; edit: (value: EditTarget) => void}) {
  const currency = matrixV2Settings(data.matrixVersion).currency;
  return <div className="matrix-v2-tab-content">
    <div className="matrix-v2-finance-banner"><ShieldCheck/><span><strong>Dane finansowe są chronione</strong><small>Ta zakładka jest widoczna wyłącznie dla właściciela, administratora oraz uprawnionej sekcji HR/finanse. Stawki pracowników nie są tutaj wyświetlane.</small></span></div>
    <section className="matrix-v2-card">
      <SectionHead title="Dodatki płacowe" description="Sposób naliczania i zakres dodatku są konfigurowane w Matrixie, bez zmian kodu." editable={editable} add={() => edit({kind: "PAY_RULE"})}/>
      <div className="matrix-v2-pay-grid">
        {data.payRules.map(rule => <article key={rule.id} className={!rule.active ? "inactive" : ""}>
          <div><CircleDollarSign/><span><h4>{rule.name}</h4><small>{payMethodLabel[rule.calculation_method] || "Reguła płacowa"}</small></span>{editable && <button onClick={() => edit({kind: "PAY_RULE", item: rule})}><Edit3/></button>}</div>
          <strong>{payRuleValue(rule, currency)}</strong>
          <p>{rule.description || "Bez dodatkowego opisu"}</p>
          <small>{payScopeSummary(data, rule.id)}</small>
        </article>)}
        {!data.payRules.length && <p className="matrix-v2-empty">Nie skonfigurowano dodatków płacowych.</p>}
      </div>
    </section>
    <section className="matrix-v2-card">
      <SectionHead title="Modyfikacje dodatków w scenariuszach" description="Np. scenariusz sezonowy może podnieść lub wyłączyć wybrany dodatek." editable={editable} disabled={!data.scenarios.length || !data.payRules.length} add={() => edit({kind: "SCENARIO_PAY_RULE"})}/>
      <div className="matrix-v2-link-grid">
        {data.scenarioPayRuleOverrides.map(link => <button key={link.id} onClick={() => editable && edit({kind: "SCENARIO_PAY_RULE", item: link})}><CircleDollarSign/><span><strong>{itemName(data.scenarios, link.scenario_id)} → {itemName(data.payRules, link.pay_rule_id)}</strong><small>{link.enabled ? "Dodatek aktywny w scenariuszu" : "Dodatek wyłączony w scenariuszu"}</small></span>{editable && <ChevronRight/>}</button>)}
      </div>
    </section>
    <section className="matrix-v2-card">
      <SectionHead title="Budżety scenariuszy" description="Budżet może obejmować całą firmę albo konkretny lokal, rolę lub obowiązek." editable={editable} disabled={!data.scenarios.length} add={() => edit({kind: "SCENARIO_BUDGET"})}/>
      <div className="matrix-v2-table budgets">
        {data.scenarioBudgets.map(budget => <button key={budget.id} onClick={() => editable && edit({kind: "SCENARIO_BUDGET", item: budget})}>
          <span><b>{itemName(data.scenarios, budget.scenario_id)}</b><small>{budget.budget_month ? new Intl.DateTimeFormat("pl-PL", {month:"long",year:"numeric",timeZone:"UTC"}).format(new Date(`${budget.budget_month}T12:00:00Z`)) : "Bez ograniczenia miesiąca"}</small></span>
          <span>{budgetScope(data, budget)}</span>
          <strong>{budget.operation === "REMOVE" ? "Bez budżetu" : budget.operation === "MULTIPLY" ? `× ${Number(budget.multiplier_basis_points ?? 0) / 10000}` : money(budget.amount_minor, currency)}</strong>
          <em>{budget.hard_limit ? "Limit twardy" : "Limit ostrzegawczy"}</em>
          {editable && <Edit3/>}
        </button>)}
      </div>
    </section>
  </div>;
}

function payRuleValue(rule: MatrixV2PayRule, currency: string) {
  if (rule.calculation_method === "FIXED_PER_SHIFT") return `${money(rule.amount_minor, currency)} / zmiana`;
  if (["PER_HOUR","SHIFT_DURATION_THRESHOLD_PER_HOUR","MONTHLY_THRESHOLD_PER_HOUR"].includes(rule.calculation_method)) return `${money(rule.rate_minor_per_hour, currency)} / godz.`;
  if (rule.calculation_method === "PERCENT_BASE") return `${Number(rule.percent_basis_points ?? 0) / 100}% stawki`;
  if (rule.calculation_method === "MULTIPLIER") return `× ${Number(rule.multiplier_basis_points ?? 0) / 10000}`;
  return "Reguła konfigurowalna";
}

function payScopeSummary(data: MatrixV2Workspace, payRuleId: string) {
  const roles = data.payRuleRoles.filter(item => item.pay_rule_id === payRuleId).map(item => itemName(data.roles, item.role_id));
  const duties = data.payRuleDuties.filter(item => item.pay_rule_id === payRuleId).map(item => itemName(data.duties, item.duty_id));
  const locations = data.payRuleLocations.filter(item => item.pay_rule_id === payRuleId).map(item => itemName(data.locations, item.location_id));
  const shifts = data.payRuleShifts.filter(item => item.pay_rule_id === payRuleId).map(item => itemName(data.shiftTemplates, item.shift_template_id));
  const groups = [roles.length ? `role: ${roles.join(", ")}` : "", duties.length ? `obowiązki: ${duties.join(", ")}` : "", locations.length ? `lokale: ${locations.join(", ")}` : "", shifts.length ? `zmiany: ${shifts.join(", ")}` : ""].filter(Boolean);
  return groups.length ? groups.join(" • ") : "Obowiązuje w całej firmie";
}

function budgetScope(data: MatrixV2Workspace, budget: MatrixV2Budget) {
  return [budget.location_id ? itemName(data.locations, budget.location_id) : "", budget.role_id ? itemName(data.roles, budget.role_id) : "", budget.duty_id ? itemName(data.duties, budget.duty_id) : ""].filter(Boolean).join(" • ") || "Cała firma";
}

type MatrixImportIssue={sheet:string;row:number;code:string;message:string};
type MatrixImportPreview={valid:boolean;errors:MatrixImportIssue[];warnings:MatrixImportIssue[];summary:{employees:number;shifts:number;staffingRules:number;roleDuties:number;total:number}};

function importCell(row:Record<string,unknown>,...names:string[]){
  const key=Object.keys(row).find(candidate=>names.some(name=>candidate.trim().toLocaleLowerCase("pl-PL")===name.toLocaleLowerCase("pl-PL")));
  return key===undefined?"":String(row[key]??"").trim();
}
function importBoolean(value:string,defaultValue=false){
  if(!value)return defaultValue;
  return ["1","tak","true","yes","x"].includes(value.toLocaleLowerCase("pl-PL"));
}
function importList(value:string){return value.split(/[;,|]/).map(item=>item.trim()).filter(Boolean);}
function importDays(value:string){
  const labels:Record<string,number>={pon:1,wt:2,sr:3,śr:3,czw:4,pt:5,sob:6,niedz:7};
  return importList(value).map(item=>Number(item)||labels[item.toLocaleLowerCase("pl-PL")]).filter(day=>Number.isInteger(day)&&day>=1&&day<=7);
}

async function readMatrixWorkbook(file:File){
  const XLSX=await import("xlsx");
  const workbook=XLSX.read(await file.arrayBuffer(),{type:"array",cellDates:false});
  const rows=(names:string[])=>{
    const sheetName=workbook.SheetNames.find(name=>names.some(expected=>name.toLocaleLowerCase("pl-PL")===expected.toLocaleLowerCase("pl-PL")));
    return sheetName?XLSX.utils.sheet_to_json<Record<string,unknown>>(workbook.Sheets[sheetName],{defval:"",raw:false,dateNF:"yyyy-mm-dd"}):[];
  };
  return {
    employees:rows(["Pracownicy","Employees"]).map(row=>({
      employeeNo:importCell(row,"Numer pracownika","employeeNo"),firstName:importCell(row,"Imię","firstName"),lastName:importCell(row,"Nazwisko","lastName"),
      email:importCell(row,"E-mail","Email"),primaryRoleCode:importCell(row,"Kod roli","primaryRoleCode"),locationCodes:importList(importCell(row,"Kody lokali","locationCodes")),
      employmentStart:importCell(row,"Zatrudniony od","employmentStart"),employmentEnd:importCell(row,"Zatrudniony do","employmentEnd"),
      nominalHours:importCell(row,"Nominał godzin","nominalHours"),maximumMonthlyHours:importCell(row,"Limit miesięczny godzin","maximumMonthlyHours"),
      maximumWeeklyHours:importCell(row,"Limit tygodniowy godzin","maximumWeeklyHours"),maximumConsecutiveDays:importCell(row,"Maks. kolejnych dni","maximumConsecutiveDays"),
      minimumRestHours:importCell(row,"Minimalny odpoczynek godzin","minimumRestHours"),baseRate:importCell(row,"Stawka godzinowa","baseRate"),contractType:importCell(row,"Rodzaj umowy","contractType"),
      preferenceMonth:importCell(row,"Miesiąc preferencji","preferenceMonth"),shiftPeriodPreferences:{
        MORNING:importCell(row,"Preferencja rano","morningPreference")||"INHERIT",MIDDLE:importCell(row,"Preferencja środek","middlePreference")||"INHERIT",EVENING:importCell(row,"Preferencja wieczór","eveningPreference")||"INHERIT",
      },
    })),
    shifts:rows(["Zmiany","Shifts"]).map(row=>({
      code:importCell(row,"Kod","code"),name:importCell(row,"Nazwa","name"),locationCode:importCell(row,"Kod lokalu","locationCode"),
      shiftPeriod:importCell(row,"Pora","shiftPeriod").toUpperCase(),startsAt:importCell(row,"Od","startsAt"),endsAt:importCell(row,"Do","endsAt"),
      endsNextDay:importBoolean(importCell(row,"Następny dzień","endsNextDay")),days:importDays(importCell(row,"Dni","days")),
      sortOrder:importCell(row,"Kolejność","sortOrder"),active:importBoolean(importCell(row,"Aktywna","active"),true),
    })),
    staffingRules:rows(["Obsada","Staffing"]).map(row=>({
      scenarioCode:importCell(row,"Kod scenariusza","scenarioCode"),shiftCode:importCell(row,"Kod zmiany","shiftCode"),locationCode:importCell(row,"Kod lokalu","locationCode"),
      roleCode:importCell(row,"Kod roli","roleCode"),dutyCode:importCell(row,"Kod obowiązku","dutyCode"),operation:(importCell(row,"Operacja","operation")||"SET").toUpperCase(),
      countValue:importCell(row,"Liczba osób","countValue"),active:importBoolean(importCell(row,"Aktywna","active"),true),
    })),
    roleDuties:rows(["Role-Obowiązki","Role Duties","Obowiązki ról"]).map(row=>({
      roleCode:importCell(row,"Kod roli","roleCode"),dutyCode:importCell(row,"Kod obowiązku","dutyCode"),assignmentMode:(importCell(row,"Znaczenie","assignmentMode")||"OPTIONAL").toUpperCase(),
      minimumCount:importCell(row,"Minimum","minimumCount"),shiftObligation:importBoolean(importCell(row,"Obowiązek zmianowy","shiftObligation")),
      shiftPeriod:importCell(row,"Pora","shiftPeriod").toUpperCase(),active:importBoolean(importCell(row,"Aktywne","active"),true),
    })),
  };
}

async function downloadMatrixTemplate(data:MatrixV2Workspace){
  const XLSX=await import("xlsx");
  const workbook=XLSX.utils.book_new();
  const add=(name:string,headers:string[])=>{
    const sheet=XLSX.utils.aoa_to_sheet([headers]);
    sheet["!autofilter"]={ref:`A1:${XLSX.utils.encode_col(headers.length-1)}1`};
    sheet["!cols"]=headers.map(header=>({wch:Math.min(34,Math.max(14,header.length+2))}));
    XLSX.utils.book_append_sheet(workbook,sheet,name);
  };
  const instructions=XLSX.utils.aoa_to_sheet([
    ["MATRIX ALPHA 16 — import zbiorczy","Zasada"],
    ["Nowy pracownik","Pozostaw Numer pracownika pusty. System nada kolejny wolny numer GP-### automatycznie."],
    ["Aktualizacja pracownika","Podaj istniejący numer lub e-mail. Nieistniejący numer zostanie odrzucony w podglądzie."],
    ["Kody","Kody ról, lokali, obowiązków i scenariuszy skopiuj z arkusza Słowniki."],
    ["Listy","Kody lokali oraz dni rozdzielaj przecinkiem; dni: 1=poniedziałek, 7=niedziela."],
    ["Pory","MORNING, MIDDLE albo EVENING."],
    ["Preferencje","INHERIT, PREFERRED, NEUTRAL, AVOIDED albo BLOCKED. Matrix pracodawcy ma pierwszeństwo."],
    ["Bezpieczeństwo","Najpierw użyj Podglądu. Zapis wszystkich arkuszy odbywa się atomowo w jednej transakcji."],
  ]);
  instructions["!cols"]=[{wch:30},{wch:100}];
  XLSX.utils.book_append_sheet(workbook,instructions,"Instrukcja");
  add("Pracownicy",["Numer pracownika","Imię","Nazwisko","E-mail","Kod roli","Kody lokali","Zatrudniony od","Zatrudniony do","Nominał godzin","Limit miesięczny godzin","Limit tygodniowy godzin","Maks. kolejnych dni","Minimalny odpoczynek godzin","Stawka godzinowa","Rodzaj umowy","Miesiąc preferencji","Preferencja rano","Preferencja środek","Preferencja wieczór"]);
  add("Zmiany",["Kod","Nazwa","Kod lokalu","Pora","Od","Do","Następny dzień","Dni","Kolejność","Aktywna"]);
  add("Obsada",["Kod scenariusza","Kod zmiany","Kod lokalu","Kod roli","Kod obowiązku","Operacja","Liczba osób","Aktywna"]);
  add("Role-Obowiązki",["Kod roli","Kod obowiązku","Znaczenie","Minimum","Obowiązek zmianowy","Pora","Aktywne"]);
  const dictionaries=[
    ["TYP","KOD","NAZWA"],
    ...data.roles.filter(item=>item.active).map(item=>["ROLA",item.code,item.name]),
    ...data.locations.filter(item=>item.active).map(item=>["LOKAL",item.code,item.name]),
    ...data.duties.filter(item=>item.active).map(item=>["OBOWIĄZEK",item.code,item.name]),
    ...data.scenarios.filter(item=>item.active).map(item=>["SCENARIUSZ",item.code,item.name]),
    ["PORA","MORNING","Rano"],["PORA","MIDDLE","Środek"],["PORA","EVENING","Wieczór"],
    ["OPERACJA OBSADY","SET","Ustaw liczbę"],["OPERACJA OBSADY","ADD","Dodaj liczbę"],["OPERACJA OBSADY","REMOVE","Usuń regułę"],
  ];
  const dictionarySheet=XLSX.utils.aoa_to_sheet(dictionaries);
  dictionarySheet["!autofilter"]={ref:`A1:C${dictionaries.length}`};
  dictionarySheet["!cols"]=[{wch:24},{wch:30},{wch:48}];
  XLSX.utils.book_append_sheet(workbook,dictionarySheet,"Słowniki");
  XLSX.writeFile(workbook,"matrix-alpha16-szablon.xlsx");
}

function MatrixExcelImport({data,busy,setBusy,close,reload,notify,fail}:{data:MatrixV2Workspace;busy:boolean;setBusy:(value:boolean)=>void;close:()=>void;reload:()=>Promise<void>;notify:(message:string)=>void;fail:(message:string)=>void}){
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [file,setFile]=useState<File|null>(null),[payload,setPayload]=useState<Record<string,unknown>|null>(null),[preview,setPreview]=useState<MatrixImportPreview|null>(null),[localError,setLocalError]=useState("");
  async function inspect(){
    if(!file||!supabase)return;
    setBusy(true);setLocalError("");setPreview(null);
    try{
      const parsed=await readMatrixWorkbook(file);
      const result=await supabase.rpc("matrix_v2_import_preview_alpha16",{p_payload:parsed});
      if(result.error)throw new Error(matrixV2ErrorMessage(result.error.message));
      setPayload(parsed);setPreview(result.data as MatrixImportPreview);
    }catch(error){setLocalError(error instanceof Error?error.message:"Nie udało się odczytać pliku Excel.");}
    finally{setBusy(false);}
  }
  async function applyImport(){
    if(!payload||!preview?.valid||!supabase)return;
    if(!window.confirm(`Zapisać atomowo ${preview.summary.total} wierszy w wersji roboczej Matrixa?`))return;
    setBusy(true);
    const result=await supabase.rpc("matrix_v2_import_apply_alpha16",{p_payload:payload});
    setBusy(false);
    if(result.error){fail(matrixV2ErrorMessage(result.error.message));return;}
    notify(`Import zakończony: zapisano ${Number((result.data as {appliedRows?:number})?.appliedRows??preview.summary.total)} wierszy.`);
    close();await reload();
  }
  return <><button className="drawer-scrim top" onClick={close}/><aside className="drawer matrix-v2-drawer top">
    <div className="drawer-head"><div><p className="eyebrow">MATRIX • IMPORT ZBIORCZY</p><h2>Import z pliku Excel</h2></div><button className="icon-button" onClick={close}><X/></button></div>
    <div className="drawer-content">
      <p className="matrix-v2-form-hint">Import modyfikuje tylko wersję roboczą {data.matrixVersion.name}. Najpierw wykonujemy walidację; przy zapisie jeden błędny wiersz cofa całą operację.</p>
      <button className="secondary-button full" type="button" onClick={()=>void downloadMatrixTemplate(data)}><Download/> Pobierz szablon Excel</button>
      <label>Plik .xlsx lub .xls<input type="file" accept=".xlsx,.xls" onChange={event=>{setFile(event.target.files?.[0]??null);setPayload(null);setPreview(null);setLocalError("");}}/></label>
      <button className="primary-button full" disabled={!file||busy} onClick={()=>void inspect()}><Upload/> {busy?"Sprawdzam…":"Sprawdź plik i pokaż podgląd"}</button>
      {localError&&<div className="solver-v2-notice warning"><AlertTriangle/>{localError}</div>}
      {preview&&<section className="matrix-import-preview">
        <h3>{preview.valid?"Plik gotowy do zapisu":"Plik wymaga poprawy"}</h3>
        <p>{preview.summary.total} wierszy: {preview.summary.employees} pracowników, {preview.summary.shifts} zmian, {preview.summary.staffingRules} reguł obsady i {preview.summary.roleDuties} obowiązków ról.</p>
        {[...preview.errors,...preview.warnings].map((issue,index)=><div className={`solver-v2-notice ${preview.errors.includes(issue)?"warning":""}`} key={`${issue.sheet}:${issue.row}:${issue.code}:${index}`}><AlertTriangle/><span><b>{issue.sheet} • wiersz {issue.row}</b><small>{issue.message}</small></span></div>)}
        {preview.valid&&<button className="primary-button full" disabled={busy} onClick={()=>void applyImport()}><Save/> Zapisz cały import w Matrixie</button>}
      </section>}
    </div>
  </aside></>;
}

function EmployeeProfileDrawer({employee,data,month,busy,close,save}:{employee:MatrixV2Employee|null;data:MatrixV2Workspace;month:string;busy:boolean;close:()=>void;save:(employeeId:string|null,payload:Record<string,unknown>)=>Promise<boolean>}) {
  const roles=data.roles.filter(item=>item.active||item.id===employee?.primaryRoleId);
  const selectedLocations=new Set(employee?.locationIds??data.employeeLocations.filter(item=>item.employee_id===employee?.id&&item.active&&item.standard_allowed).map(item=>item.location_id));
  const locations=data.locations.filter(item=>item.active||selectedLocations.has(item.id));
  const minutesAsHours=(value:number|undefined,fallback:number)=>Number(value??fallback)/60;
  async function submit(form:HTMLFormElement){
    try{
      const employmentStart=formText(form,"employmentStart");
      const employmentEnd=formText(form,"employmentEnd");
      if(employmentStart&&employmentEnd&&employmentEnd<employmentStart)throw new Error("Data zakończenia zatrudnienia nie może być wcześniejsza od daty rozpoczęcia.");
      const nominal=requiredNumber(formText(form,"nominalHours"),60);
      const maximumMonthly=requiredNumber(formText(form,"maximumMonthlyHours"),60);
      const maximumWeekly=requiredNumber(formText(form,"maximumWeeklyHours"),60);
      const maximumConsecutiveDays=requiredNumber(formText(form,"maximumConsecutiveDays"));
      const minimumRest=optionalNumber(formText(form,"minimumRestHours"),60);
      if(maximumMonthly<nominal)throw new Error("Miesięczny limit nie może być niższy od nominału.");
      const locationIds=new FormData(form).getAll("locationIds").map(String);
      if(!formText(form,"primaryRoleId")||!locationIds.length)throw new Error("Wybierz rolę podstawową i co najmniej jeden zwykły lokal pracy.");
      await save(employee?.id??null,{
        firstName:formText(form,"firstName"),
        lastName:formText(form,"lastName"),email:formText(form,"email")||null,
        employmentStart:employmentStart||null,employmentEnd:employmentEnd||null,
        nominalMonthlyMinutes:nominal,maximumMonthlyMinutes:maximumMonthly,
        maximumWeeklyMinutes:maximumWeekly,maximumConsecutiveDays,
        minimumRestMinutes:minimumRest,onlyMorning:false,onlyEvening:false,
        noWeekends:checked(form,"noWeekends"),preferredShiftCode:null,
        primaryRoleId:formText(form,"primaryRoleId"),locationIds,
        preferenceMonth:`${month}-01`,shiftPeriodPreferences:{
          MORNING:formText(form,"preferenceMorning")||"INHERIT",
          MIDDLE:formText(form,"preferenceMiddle")||"INHERIT",
          EVENING:formText(form,"preferenceEvening")||"INHERIT",
        },
      });
    }catch(error){
      window.alert(error instanceof Error?error.message:"Sprawdź dane pracownika.");
    }
  }
  return <><button className="drawer-scrim top" onClick={close}/><aside className="drawer matrix-v2-drawer top">
    <div className="drawer-head"><div><p className="eyebrow">PRACOWNIK • WERSJA ROBOCZA MATRIXA</p><h2>{employee?`Edytuj: ${employee.firstName} ${employee.lastName}`:"Dodaj pracownika"}</h2></div><button className="icon-button" onClick={close}><X/></button></div>
    <form className="drawer-content" onSubmit={event=>{event.preventDefault();void submit(event.currentTarget);}}>
      <p className="matrix-v2-form-hint">Zmiana nie modyfikuje opublikowanych grafików. Nowe dane zaczną obowiązywać dopiero po publikacji tej wersji Matrixa.</p>
      <label>Numer pracownika<input readOnly value={employee?.employeeNo??"Zostanie nadany automatycznie"}/><small>System wybiera pierwszy wolny numer GP-### podczas zapisu.</small></label>
      <div className="form-row"><label>Imię<input name="firstName" required maxLength={120} defaultValue={employee?.firstName??""}/></label><label>Nazwisko<input name="lastName" required maxLength={160} defaultValue={employee?.lastName??""}/></label></div>
      <label>E-mail<input name="email" type="email" defaultValue={employee?.email??""}/></label>
      <label>Rola podstawowa<select name="primaryRoleId" required defaultValue={employee?.primaryRoleId??""}><option value="" disabled>Wybierz rolę</option>{roles.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
      <fieldset className="matrix-v2-scopes"><legend>Zwykłe lokale pracy</legend><p className="matrix-v2-form-hint">Wszystkie zaznaczone lokale są równorzędne i mieszczą się w normalnym limicie pracownika.</p>{locations.map(item=><label key={item.id}><input type="checkbox" name="locationIds" value={item.id} defaultChecked={selectedLocations.has(item.id)}/>{item.name}</label>)}</fieldset>
      <div className="form-row"><label>Zatrudniony od<input name="employmentStart" type="date" defaultValue={employee?.employmentStart??""}/></label><label>Zatrudniony do<input name="employmentEnd" type="date" defaultValue={employee?.employmentEnd??""}/></label></div>
      <h3>Czas pracy i limity</h3>
      <div className="form-row"><label>Nominał miesięczny (godz.)<input name="nominalHours" type="number" min="0" max="744" step="0.25" required defaultValue={minutesAsHours(employee?.nominalMonthlyMinutes,10080)}/></label><label>Limit miesięczny (godz.)<input name="maximumMonthlyHours" type="number" min="0" max="744" step="0.25" required defaultValue={minutesAsHours(employee?.maximumMonthlyMinutes,12600)}/></label></div>
      <div className="form-row"><label>Limit tygodniowy (godz.)<input name="maximumWeeklyHours" type="number" min="0" max="168" step="0.25" required defaultValue={minutesAsHours(employee?.maximumWeeklyMinutes,2400)}/></label><label>Maks. kolejnych dni<input name="maximumConsecutiveDays" type="number" min="1" max="31" required defaultValue={employee?.maximumConsecutiveDays??6}/></label></div>
      <label>Minimalny odpoczynek (godz.)<input name="minimumRestHours" type="number" min="0" max="48" step="0.25" defaultValue={employee?.minimumRestMinutes===null||employee?.minimumRestMinutes===undefined?"":minutesAsHours(employee.minimumRestMinutes,660)}/><small>Puste pole oznacza użycie wspólnej reguły Matrixa.</small></label>
      <fieldset><legend>Nadrzędne preferencje pracodawcy • {month}</legend><p className="matrix-v2-form-hint">Wartość inna niż „Dziedzicz” ma pierwszeństwo przed preferencją ustawioną przez pracownika w portalu.</p>{([['MORNING','Rano'],['MIDDLE','Środek'],['EVENING','Wieczór']] as const).map(([period,label])=><label key={period}>{label}<select name={`preference${period[0]}${period.slice(1).toLocaleLowerCase()}`} defaultValue={employee?.shiftPeriodPreferences?.[period]??"INHERIT"}><option value="INHERIT">Dziedzicz od pracownika</option><option value="PREFERRED">Preferowana</option><option value="NEUTRAL">Neutralna</option><option value="AVOIDED">Unikać</option><option value="BLOCKED">Zablokowana</option></select></label>)}</fieldset>
      <fieldset><legend>Ograniczenia pracodawcy</legend><label className="check-label"><input name="noWeekends" type="checkbox" defaultChecked={employee?.noWeekends??false}/> Zakaz pracy w weekendy</label></fieldset>
      <button className="primary-button full" disabled={busy||!roles.length||!locations.length}><Save/> {busy?"Zapisuję…":employee?"Zapisz dane pracownika":"Dodaj pracownika"}</button>
    </form>
  </aside></>;
}

function MatrixV2Drawer({target, data, month, busy, close, save}: {target: EditTarget; data: MatrixV2Workspace; month: string; busy: boolean; close: () => void; save: (kind: MatrixV2SaveKind, id: string | null, payload: Record<string, unknown>) => Promise<boolean>}) {
  const item = target.item as Record<string, unknown> | undefined;
  const currency = matrixV2Settings(data.matrixVersion).currency;
  const [operation, setOperation] = useState(String(item?.operation ?? "SET"));
  const [payMethod, setPayMethod] = useState(String(item?.calculation_method ?? "FIXED_PER_SHIFT"));
  const [scenarioStrategyId, setScenarioStrategyId] = useState(String(item?.strategy_id ?? data.strategies.find(strategy => strategy.active)?.id ?? ""));
  const [localError, setLocalError] = useState("");
  const title = drawerTitle(target.kind, Boolean((target.item as {id?:string} | undefined)?.id));

  async function submit(form: HTMLFormElement) {
    setLocalError("");
    try {
      const payload = payloadFromForm(target.kind, form, item, operation, payMethod, currency, data);
      await save(target.kind, String(item?.id ?? "") || null, payload);
    } catch (error) {
      setLocalError(error instanceof Error ? error.message : "Sprawdź wartości formularza.");
    }
  }

  return <><button className="drawer-scrim top" onClick={close}/><aside className="drawer matrix-v2-drawer top">
    <div className="drawer-head"><div><p className="eyebrow">WERSJA ROBOCZA MATRIXA</p><h2>{title}</h2></div><button className="icon-button" onClick={close}><X/></button></div>
    <form className="drawer-content" onSubmit={event => {event.preventDefault(); void submit(event.currentTarget);}}>
      <DrawerFields kind={target.kind} item={item} data={data} month={month} operation={operation} setOperation={setOperation} payMethod={payMethod} setPayMethod={setPayMethod} scenarioStrategyId={scenarioStrategyId} setScenarioStrategyId={setScenarioStrategyId}/>
      {localError && <div className="solver-v2-notice warning"><AlertTriangle/>{localError}</div>}
      <button className="primary-button full" disabled={busy}><Save/> {busy ? "Zapisuję…" : "Zapisz w wersji roboczej"}</button>
    </form>
  </aside></>;
}

function DrawerFields({kind,item,data,month,operation,setOperation,payMethod,setPayMethod,scenarioStrategyId,setScenarioStrategyId}:{kind: MatrixV2SaveKind; item?: Record<string, unknown>; data: MatrixV2Workspace; month: string; operation: string; setOperation: (value: string) => void; payMethod: string; setPayMethod: (value: string) => void; scenarioStrategyId: string; setScenarioStrategyId: (value: string) => void}) {
  const currency = matrixV2Settings(data.matrixVersion).currency;
  if (["ROLE","LOCATION","DUTY","STRATEGY"].includes(kind)) return <>
    <NameAndCode item={item}/>
    {kind === "LOCATION" && <label>Strefa czasowa<input name="timezone" required list="matrix-location-timezones" defaultValue={String(item?.timezone ?? "")}/><datalist id="matrix-location-timezones"><option value="Europe/Warsaw"/><option value="Europe/London"/><option value="Europe/Berlin"/><option value="UTC"/></datalist><small>Wybierz lub wpisz strefę IANA; wartość nie jest ustawiana automatycznie.</small></label>}
    {kind === "DUTY" && <label>Opis<textarea name="description" defaultValue={String(item?.description ?? "")}/></label>}
    {kind === "STRATEGY" && <><label>Opis wariantu<textarea name="description" defaultValue={String(item?.description ?? "")}/></label><input type="hidden" name="solverCode" value="CP_SAT"/></>}
    {(kind === "ROLE" || kind === "DUTY") && <label>Kolor<input name="color" type="color" defaultValue={String(item?.color ?? (kind === "ROLE" ? "#7257d8" : "#4a8d78"))}/></label>}
    <CommonState item={item}/>
  </>;
  if (kind === "SHIFT") return <>
    <label>Lokal<select name="locationId" required defaultValue={String(item?.location_id ?? "")}>{data.locations.filter(x=>x.active).map(location=><option value={location.id} key={location.id}>{location.name}</option>)}</select></label>
    <NameAndCode item={item}/>
    <label>Podstawowa pora zmiany<select name="shiftPeriod" required defaultValue={String(item?.shift_period??"MIDDLE")}><option value="MORNING">Poranna</option><option value="MIDDLE">Środek</option><option value="EVENING">Wieczorna</option></select><small>Ta krótka klasyfikacja zasila preferencje; dokładne godziny pozostają poniżej.</small></label>
    <div className="form-row"><label>Od<input name="startsAt" type="time" required defaultValue={time(String(item?.starts_at ?? "10:00"))}/></label><label>Do<input name="endsAt" type="time" required defaultValue={time(String(item?.ends_at ?? "18:00"))}/></label></div>
    <label className="check-label"><input name="endsNextDay" type="checkbox" defaultChecked={Boolean(item?.ends_next_day)}/> Kończy się następnego dnia</label>
    <DaySelector selected={(item?.day_mask as number[] | undefined) ?? WEEKDAYS.map(day=>day.value)}/>
    <CommonState item={item}/>
  </>;
  if (kind === "ROLE_DUTY") return <>
    {item?.id&&<><input type="hidden" name="roleId" value={String(item.role_id)}/><input type="hidden" name="dutyId" value={String(item.duty_id)}/></>}
    <label>Rola<select name="roleId" required disabled={Boolean(item?.id)} defaultValue={String(item?.role_id ?? "")}>{data.roles.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Obowiązek<select name="dutyId" required disabled={Boolean(item?.id)} defaultValue={String(item?.duty_id ?? "")}>{data.duties.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Znaczenie<select name="assignmentMode" defaultValue={String(item?.assignment_mode ?? "OPTIONAL")}><option value="REQUIRED">Wymagany</option><option value="OPTIONAL">Opcjonalny</option><option value="EXTRA">Dodatkowy</option></select></label>
    <label>Minimalna liczba na zmianie<input name="minimumCount" type="number" min="0" defaultValue={Number(item?.minimum_count ?? 0)}/></label>
    <label className="check-label"><input name="shiftObligation" type="checkbox" defaultChecked={Boolean(item?.shift_obligation)}/> Obowiązek dotyczy wskazanej pory zmiany</label>
    <label>Pora obowiązku<select name="shiftPeriod" defaultValue={String(item?.shift_period??"MIDDLE")}><option value="MORNING">Poranna</option><option value="MIDDLE">Środek</option><option value="EVENING">Wieczorna</option></select><small>Ignorowana, gdy obowiązek nie jest zmianowy.</small></label>
    <ActiveToggle item={item}/>
  </>;
  if (kind === "EMPLOYEE_ROLE") return <>
    <label>Pracownik<select name="employeeId" required disabled={Boolean(item?.id)} defaultValue={String(item?.employee_id ?? "")}>{data.employees.filter(x=>x.active||x.id===item?.employee_id).map(x=><option value={x.id} key={x.id}>{x.firstName} {x.lastName} • {x.employeeNo}</option>)}</select></label>
    {item?.id&&<input type="hidden" name="employeeId" value={String(item.employee_id)}/>}
    <label>Rola<select name="roleId" required disabled={Boolean(item?.id)} defaultValue={String(item?.role_id ?? "")}>{data.roles.filter(x=>x.active||x.id===item?.role_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    {item?.id&&<input type="hidden" name="roleId" value={String(item.role_id)}/>}
    <div className="form-row"><label>Ważna od<input name="validFrom" type="date" defaultValue={String(item?.valid_from??"")}/></label><label>Ważna do<input name="validTo" type="date" defaultValue={String(item?.valid_to??"")}/></label></div>
    <label className="check-label"><input name="isPrimary" type="checkbox" defaultChecked={Boolean(item?.is_primary)}/> Rola podstawowa</label>
    <label className="check-label"><input name="canLead" type="checkbox" defaultChecked={Boolean(item?.can_lead)}/> Może prowadzić zespół</label>
    <ActiveToggle item={item}/>
  </>;
  if (kind === "EMPLOYEE_LOCATION") return <>
    <label>Pracownik<select name="employeeId" required disabled={Boolean(item?.id)} defaultValue={String(item?.employee_id ?? "")}>{data.employees.filter(x=>x.active||x.id===item?.employee_id).map(x=><option value={x.id} key={x.id}>{x.firstName} {x.lastName} • {x.employeeNo}</option>)}</select></label>
    {item?.id&&<input type="hidden" name="employeeId" value={String(item.employee_id)}/>}
    <label>Lokal<select name="locationId" required disabled={Boolean(item?.id)} defaultValue={String(item?.location_id ?? "")}>{data.locations.filter(x=>x.active||x.id===item?.location_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    {item?.id&&<input type="hidden" name="locationId" value={String(item.location_id)}/>}
    <div className="form-row"><label>Ważny od<input name="validFrom" type="date" defaultValue={String(item?.valid_from??"")}/></label><label>Ważny do<input name="validTo" type="date" defaultValue={String(item?.valid_to??"")}/></label></div>
    <label className="check-label"><input name="standardAllowed" type="checkbox" defaultChecked={Boolean(item?.standard_allowed)}/> Może pracować standardowo</label>
    <label className="check-label"><input name="overtimeAllowed" type="checkbox" defaultChecked={Boolean(item?.overtime_allowed)}/> Może pracować w nadgodzinach</label>
    <ActiveToggle item={item}/>
  </>;
  if (kind === "EMPLOYEE_DUTY") return <>
    <label>Pracownik<select name="employeeId" required disabled={Boolean(item?.id)} defaultValue={String(item?.employee_id ?? "")}>{data.employees.filter(x=>x.active||x.id===item?.employee_id).map(x=><option value={x.id} key={x.id}>{x.firstName} {x.lastName} • {x.employeeNo}</option>)}</select></label>
    {item?.id&&<input type="hidden" name="employeeId" value={String(item.employee_id)}/>}
    <label>Obowiązek<select name="dutyId" required disabled={Boolean(item?.id)} defaultValue={String(item?.duty_id ?? "")}>{data.duties.filter(x=>x.active||x.id===item?.duty_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    {item?.id&&<input type="hidden" name="dutyId" value={String(item.duty_id)}/>}
    <div className="form-row"><label>Rola<select name="roleId" defaultValue={String(item?.role_id??"")}><option value="">Wszystkie role</option>{data.roles.filter(x=>x.active||x.id===item?.role_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label><label>Lokal<select name="locationId" defaultValue={String(item?.location_id??"")}><option value="">Wszystkie lokale</option>{data.locations.filter(x=>x.active||x.id===item?.location_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label></div>
    <div className="form-row"><label>Ważny od<input name="validFrom" type="date" defaultValue={String(item?.valid_from??"")}/></label><label>Ważny do<input name="validTo" type="date" defaultValue={String(item?.valid_to??"")}/></label></div>
    <ActiveToggle item={item}/>
  </>;
  if (kind === "SCENARIO") return <>
    <NameAndCode item={item}/><label>Opis<textarea name="description" defaultValue={String(item?.description ?? "")}/></label>
    <label>Dziedziczy po<select name="parentScenarioId" defaultValue={String(item?.parent_scenario_id ?? "")}><option value="">Nie dziedziczy</option>{data.scenarios.filter(x=>x.active&&x.id!==item?.id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Kolor<input name="color" type="color" defaultValue={String(item?.color ?? "#7457e8")}/></label>
    <div className="form-row"><label>Obowiązuje od<input name="validFrom" type="date" defaultValue={String(item?.valid_from ?? "")}/></label><label>Obowiązuje do<input name="validTo" type="date" defaultValue={String(item?.valid_to ?? "")}/></label></div>
    <ScenarioSettingsOverrideFields item={item}/>
    <label className="check-label"><input name="isDefault" type="checkbox" defaultChecked={Boolean(item?.is_default)}/> Scenariusz domyślny</label><CommonState item={item}/>
  </>;
  if (kind === "STAFFING_RULE") return <>
    {item?.id&&<><input type="hidden" name="scenarioId" value={String(item.scenario_id)}/><input type="hidden" name="shiftTemplateId" value={String(item.shift_template_id)}/><input type="hidden" name="roleId" value={String(item.role_id)}/><input type="hidden" name="dutyId" value={String(item.duty_id??"")}/></>}
    <label>Scenariusz<select name="scenarioId" required disabled={Boolean(item?.id)} defaultValue={String(item?.scenario_id ?? "")}>{data.scenarios.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Zmiana<select name="shiftTemplateId" required disabled={Boolean(item?.id)} defaultValue={String(item?.shift_template_id ?? "")}>{data.shiftTemplates.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name} • {itemName(data.locations,x.location_id)}</option>)}</select></label>
    <div className="form-row"><label>Rola<select name="roleId" required disabled={Boolean(item?.id)} defaultValue={String(item?.role_id ?? "")}>{data.roles.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label><label>Obowiązek<select name="dutyId" disabled={Boolean(item?.id)} defaultValue={String(item?.duty_id ?? "")}><option value="">Dowolny</option>{data.duties.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label></div>
    <OperationSelector operation={operation} setOperation={setOperation} currency={currency} staffing item={item}/><ActiveToggle item={item}/>
  </>;
  if (kind === "OBJECTIVE") return <>
    {item?.id&&<><input type="hidden" name="strategyId" value={String(item.strategy_id)}/><input type="hidden" name="metricCode" value={String(item.metric_code)}/><input type="hidden" name="tier" value={String(item.tier)}/></>}
    <label>Strategia<select name="strategyId" required disabled={Boolean(item?.id)} defaultValue={String(item?.strategy_id ?? "")}>{data.strategies.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Kryterium<select name="metricCode" required disabled={Boolean(item?.id)} defaultValue={String(item?.metric_code ?? "UNFILLED")}>{OBJECTIVE_METRICS.map(x=><option key={x.value} value={x.value}>{x.label}</option>)}</select></label>
    <div className="form-row"><label>Poziom ważności<input name="tier" type="number" min="1" max="100" required disabled={Boolean(item?.id)} defaultValue={Number(item?.tier ?? 1)}/><small>Poziom 1 jest rozstrzygany przed poziomem 2.</small></label><label>Kierunek<select name="direction" defaultValue={String(item?.direction ?? "MINIMIZE")}><option value="MINIMIZE">Minimalizuj</option><option value="MAXIMIZE">Maksymalizuj</option></select></label></div>
    <div className="form-row"><label>Waga<input name="weight" type="number" min="0" required defaultValue={Number(item?.weight ?? 1)}/></label><label>Tolerancja<input name="tolerance" type="number" min="0" required defaultValue={Number(item?.tolerance ?? 0)}/></label></div><CommonState item={item}/>
  </>;
  if (kind === "SCENARIO_STRATEGY") return <>
    {item?.id&&<><input type="hidden" name="scenarioId" value={String(item.scenario_id)}/><input type="hidden" name="strategyId" value={String(item.strategy_id)}/></>}
    <label>Scenariusz<select name="scenarioId" required disabled={Boolean(item?.id)} defaultValue={String(item?.scenario_id ?? "")}>{data.scenarios.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Strategia wariantu<select name="strategyId" required disabled={Boolean(item?.id)} value={scenarioStrategyId} onChange={event=>setScenarioStrategyId(event.target.value)}><option value="" disabled>Wybierz strategię</option>{data.strategies.filter(x=>x.active||x.id===item?.strategy_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <ScenarioStrategyOverrideFields item={item} data={data} strategyId={scenarioStrategyId}/><CommonState item={item}/>
  </>;
  if (kind === "PAY_RULE") return <>
    <NameAndCode item={item}/><label>Opis<textarea name="description" defaultValue={String(item?.description ?? "")}/></label>
    <label>Sposób naliczania<select name="calculationMethod" value={payMethod} onChange={event=>setPayMethod(event.target.value)}>{Object.entries(payMethodLabel).map(([value,label])=><option value={value} key={value}>{label}</option>)}</select></label>
    <PayValueFields method={payMethod} item={item} currency={currency}/>
    <div className="form-row"><label>Priorytet<input name="priority" type="number" min="0" defaultValue={Number(item?.priority ?? 100)}/></label><label>Łączenie dodatków<select name="stackingMode" defaultValue={String(item?.stacking_mode ?? "STACK")}><option value="STACK">Sumuj</option><option value="MAX">Wybierz najwyższy</option><option value="FIRST">Pierwszy wg priorytetu</option></select></label></div>
    <label>Grupa wzajemnego wykluczania<input name="stackingGroup" defaultValue={String(item?.stacking_group ?? "")} placeholder="Puste = bez grupy"/></label>
    <DaySelector selected={(item?.day_mask as number[] | undefined) ?? WEEKDAYS.map(day=>day.value)}/><div className="form-row"><label>Godziny płatnego okna od<input name="localStart" type="time" disabled={payMethod.includes("THRESHOLD")} defaultValue={time(String(item?.local_start ?? "")) === "—" ? "" : time(String(item?.local_start))}/></label><label>Godziny płatnego okna do<input name="localEnd" type="time" disabled={payMethod.includes("THRESHOLD")} defaultValue={time(String(item?.local_end ?? "")) === "—" ? "" : time(String(item?.local_end))}/></label></div><p className="matrix-v2-form-hint">Dla dodatku godzinowego, procentowego lub mnożnika naliczane są wyłącznie minuty rzeczywiście przecinające to okno. Reguły progowe nie łączą się z oknem godzinowym.</p>
    <div className="form-row"><label>Ważny od<input name="validFrom" type="date" defaultValue={String(item?.valid_from ?? "")}/></label><label>Ważny do<input name="validTo" type="date" defaultValue={String(item?.valid_to ?? "")}/></label></div>
    <ScopeSelector title="Role" name="roleIds" items={data.roles} selected={data.payRuleRoles.filter(x=>x.pay_rule_id===item?.id).map(x=>x.role_id)}/>
    <ScopeSelector title="Obowiązki" name="dutyIds" items={data.duties} selected={data.payRuleDuties.filter(x=>x.pay_rule_id===item?.id).map(x=>x.duty_id)}/>
    <ScopeSelector title="Lokale" name="locationIds" items={data.locations} selected={data.payRuleLocations.filter(x=>x.pay_rule_id===item?.id).map(x=>x.location_id)}/>
    <ScopeSelector title="Zmiany" name="shiftIds" items={data.shiftTemplates} selected={data.payRuleShifts.filter(x=>x.pay_rule_id===item?.id).map(x=>x.shift_template_id)}/>
    <p className="matrix-v2-form-hint">Pusty zakres oznacza, że dodatek obowiązuje wszystkie pozycje danego rodzaju.</p><CommonState item={item}/>
  </>;
  if (kind === "SCENARIO_PAY_RULE") return <>
    {item?.id&&<><input type="hidden" name="scenarioId" value={String(item.scenario_id)}/><input type="hidden" name="payRuleId" value={String(item.pay_rule_id)}/></>}
    <label>Scenariusz<select name="scenarioId" required disabled={Boolean(item?.id)} defaultValue={String(item?.scenario_id ?? "")}>{data.scenarios.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Dodatek<select name="payRuleId" required disabled={Boolean(item?.id)} defaultValue={String(item?.pay_rule_id ?? "")}>{data.payRules.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label className="check-label"><input name="enabled" type="checkbox" defaultChecked={item?.enabled === undefined ? true : Boolean(item.enabled)}/> Aktywny w tym scenariuszu</label>
    <p className="matrix-v2-form-hint">Opcjonalnie wpisz nowe wartości. Puste pole zachowuje wartość dodatku bazowego.</p>
    <div className="form-row"><label>Kwota za zmianę ({currency})<input name="amount" type="number" step="0.01" min="0" defaultValue={minorToInput(item?.amount_minor)}/></label><label>Kwota za godzinę ({currency})<input name="hourly" type="number" step="0.01" min="0" defaultValue={minorToInput(item?.rate_minor_per_hour)}/></label></div>
    <div className="form-row"><label>Procent stawki<input name="percent" type="number" step="0.01" min="0" defaultValue={basisPercentToInput(item?.percent_basis_points)}/></label><label>Mnożnik<input name="multiplier" type="number" step="0.01" min="0" defaultValue={basisMultiplierToInput(item?.multiplier_basis_points)}/></label></div>
  </>;
  return <>
    {item?.id&&<><input type="hidden" name="scenarioId" value={String(item.scenario_id)}/><input type="hidden" name="budgetMonth" value={String(item.budget_month??"").slice(0,7)}/><input type="hidden" name="locationId" value={String(item.location_id??"")}/><input type="hidden" name="roleId" value={String(item.role_id??"")}/><input type="hidden" name="dutyId" value={String(item.duty_id??"")}/></>}
    <label>Scenariusz<select name="scenarioId" required disabled={Boolean(item?.id)} defaultValue={String(item?.scenario_id ?? "")}>{data.scenarios.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Miesiąc<input name="budgetMonth" type="month" disabled={Boolean(item?.id)} defaultValue={String(item?.budget_month ?? `${month}-01`).slice(0,7)}/><small>Puste pole tworzy regułę bez ograniczenia miesiąca.</small></label>
    <div className="form-row"><label>Lokal<select name="locationId" disabled={Boolean(item?.id)} defaultValue={String(item?.location_id ?? "")}><option value="">Cała firma</option>{data.locations.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label><label>Rola<select name="roleId" disabled={Boolean(item?.id)} defaultValue={String(item?.role_id ?? "")}><option value="">Wszystkie role</option>{data.roles.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label></div>
    <label>Obowiązek<select name="dutyId" disabled={Boolean(item?.id)} defaultValue={String(item?.duty_id ?? "")}><option value="">Wszystkie obowiązki</option>{data.duties.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <OperationSelector operation={operation} setOperation={setOperation} currency={currency} item={item}/>
    <div className="form-row"><label>Ostrzeżenie przy (%)<input name="warningPercent" type="number" min="1" max="100" defaultValue={Number(item?.warning_percent ?? 90)}/></label><label className="check-label"><input name="hardLimit" type="checkbox" defaultChecked={Boolean(item?.hard_limit)}/> Twardy limit</label></div>
  </>;
}

function ScenarioSettingsOverrideFields({item}:{item?:Record<string,unknown>}) {
  const overrides=asRecord(item?.settings_overrides);
  return <fieldset className="matrix-v2-override-group">
    <legend>Nadpisania reguł dla tego scenariusza</legend>
    <p className="matrix-v2-form-hint">Puste pole lub „Dziedzicz” zachowuje wartość Matrixa bazowego albo scenariusza nadrzędnego.</p>
    <div className="form-row">
      <label>Maks. zmian dziennie<input name="scenarioMaximumShiftsPerDay" type="number" min="1" max="24" step="1" defaultValue={optionalInput(overrides.maximumShiftsPerDay)}/></label>
      <label>Minimalny odpoczynek (min)<input name="scenarioMinimumRestMinutes" type="number" min="0" step="1" defaultValue={optionalInput(overrides.minimumRestMinutes)}/></label>
    </div>
    <div className="form-row">
      <label>Brak dostępności<select name="scenarioMissingAvailability" defaultValue={booleanOverrideInput(overrides.missingAvailabilityMeansAvailable)}><option value="">Dziedzicz</option><option value="true">Traktuj jako dostępność</option><option value="false">Traktuj jako niedostępność</option></select></label>
      <label>Wymagaj optimum<select name="scenarioRequireOptimal" defaultValue={booleanOverrideInput(overrides.requireOptimal)}><option value="">Dziedzicz</option><option value="true">Tak</option><option value="false">Nie</option></select></label>
    </div>
    <label>Ziarno losowe — opcja techniczna<input name="scenarioRandomSeed" type="number" min="0" max="2147483647" step="1" defaultValue={optionalInput(overrides.randomSeed)}/><small>Puste pole dziedziczy automatyczne ziarno przebiegu.</small></label>
  </fieldset>;
}

function ScenarioStrategyOverrideFields({item,data,strategyId}:{item?:Record<string,unknown>;data:MatrixV2Workspace;strategyId:string}) {
  const solverOverrides=asRecord(item?.solver_overrides);
  const objectiveOverrides=asRecord(item?.objective_overrides);
  const objectives=Array.from(new Map(data.strategyObjectives
    .filter(objective=>objective.strategy_id===strategyId&&objective.active)
    .sort((left,right)=>left.tier-right.tier||left.sort_order-right.sort_order)
    .map(objective=>[objective.metric_code.toUpperCase(),objective])).values());
  return <>
    <fieldset className="matrix-v2-override-group">
      <legend>Parametry obliczeń tego wariantu</legend>
      <p className="matrix-v2-form-hint">Puste pola dziedziczą ustawienia strategii. Zakres jest walidowany przed publikacją Matrixa.</p>
      <div className="form-row">
        <label>Limit czasu (sek.)<input name="strategyMaxTimeSeconds" type="number" min="1" max="86400" step="1" defaultValue={optionalInput(solverOverrides.maxTimeSeconds)}/></label>
        <label>Ziarno losowe<input name="strategyRandomSeed" type="number" min="0" max="2147483647" step="1" defaultValue={optionalInput(solverOverrides.randomSeed)}/></label>
      </div>
    </fieldset>
    {objectives.map(objective=>{
      const metric=objective.metric_code.toUpperCase();
      const override=asRecord(objectiveOverrides[metric]);
      const parameters=asRecord(override.parameters);
      return <fieldset className="matrix-v2-override-group" key={`${strategyId}:${metric}`}>
        <legend>{objectiveName(metric)} • poziom bazowy {objective.tier}</legend>
        <div className="form-row">
          <label>Użycie kryterium<select name={`objective:${metric}:active`} defaultValue={booleanOverrideInput(override.active)}><option value="">Dziedzicz</option><option value="true">Aktywne</option><option value="false">Wyłączone</option></select></label>
          <label>Poziom ważności<input name={`objective:${metric}:tier`} type="number" min="1" max="100" step="1" defaultValue={optionalInput(override.tier)}/></label>
        </div>
        <div className="form-row">
          <label>Kierunek<select name={`objective:${metric}:direction`} defaultValue={directionOverrideInput(override.direction)}><option value="">Dziedzicz</option><option value="MINIMIZE">Minimalizuj</option><option value="MAXIMIZE">Maksymalizuj</option></select></label>
          <label>Waga<input name={`objective:${metric}:weight`} type="number" min="0" step="1" defaultValue={optionalInput(override.weight)}/></label>
        </div>
        <div className="form-row">
          <label>Tolerancja<input name={`objective:${metric}:tolerance`} type="number" min="0" step="1" defaultValue={optionalInput(override.tolerance)}/></label>
          <label>Cel maksymalny<input name={`objective:${metric}:target`} type="number" min="0" step="1" defaultValue={optionalInput(parameters.targetValue??parameters.target)}/><small>Tylko dla kryterium minimalizowanego; puste = bez celu.</small></label>
        </div>
      </fieldset>;
    })}
    {!objectives.length&&<p className="matrix-v2-form-hint">Wybrana strategia nie ma aktywnych kryteriów. Dodaj je przed włączeniem wariantu.</p>}
  </>;
}

function NameAndCode({item}:{item?:Record<string,unknown>}) { return <><label>Nazwa<input name="name" required maxLength={160} defaultValue={String(item?.name ?? "")}/></label><label>Identyfikator konfiguracji<input name="code" maxLength={80} defaultValue={String(item?.code ?? "")} placeholder="Utworzy się automatycznie z nazwy"/><small>Stabilny identyfikator używany przy imporcie i integracjach.</small></label></>; }
function CommonState({item}:{item?:Record<string,unknown>}) { return <><label>Kolejność<input name="sortOrder" type="number" defaultValue={Number(item?.sort_order ?? 0)}/></label><label className="check-label"><input name="active" type="checkbox" defaultChecked={item?.active === undefined ? true : Boolean(item.active)}/> Element aktywny</label></>; }
function ActiveToggle({item}:{item?:Record<string,unknown>}) { return <label className="check-label"><input name="active" type="checkbox" defaultChecked={item?.active === undefined ? true : Boolean(item.active)}/> Reguła aktywna</label>; }
function DaySelector({selected}:{selected:number[]}) { return <fieldset className="matrix-v2-days"><legend>Dni tygodnia</legend>{WEEKDAYS.map(day=><label key={day.value}><input type="checkbox" name="days" value={day.value} defaultChecked={selected.includes(day.value)}/>{day.label}</label>)}</fieldset>; }
function ScopeSelector({title,name,items,selected}:{title:string;name:string;items:{id:string;name:string;active:boolean}[];selected:string[]}) { return <fieldset className="matrix-v2-scopes"><legend>{title}</legend>{items.filter(x=>x.active||selected.includes(x.id)).map(x=><label key={x.id}><input type="checkbox" name={name} value={x.id} defaultChecked={selected.includes(x.id)}/>{x.name}{!x.active?" (wyłączony)":""}</label>)}</fieldset>; }
function OperationSelector({operation,setOperation,currency,item,staffing=false}:{operation:string;setOperation:(value:string)=>void;currency:string;item?:Record<string,unknown>;staffing?:boolean}) { return <><label>Operacja<select name="operation" value={operation} onChange={event=>setOperation(event.target.value)}><option value="SET">Ustaw wartość</option><option value="ADD">Dodaj do wartości bazowej</option><option value="MULTIPLY">Pomnóż wartość bazową</option><option value="REMOVE">Usuń wymaganie</option></select></label>{["SET","ADD"].includes(operation)&&<label>{staffing?"Liczba osób":`Kwota (${currency})`}<input name={staffing?"countValue":"amount"} type="number" min={operation==="SET"?"0":undefined} step={staffing?"1":"0.01"} required defaultValue={staffing?Number(item?.count_value ?? 0):minorToInput(item?.amount_minor)}/></label>}{operation==="MULTIPLY"&&<label>Nowa wartość procentowa<input name="multiplierPercent" type="number" min="0" step="0.01" required defaultValue={Number(item?.multiplier_basis_points ?? 10000)/100}/><small>100% = bez zmiany, 150% = półtora raza więcej.</small></label>}</>; }
function PayValueFields({method,item,currency}:{method:string;item?:Record<string,unknown>;currency:string}) { if(method==="FIXED_PER_SHIFT")return <label>Kwota za zmianę ({currency})<input name="amount" type="number" min="0" step="0.01" required defaultValue={minorToInput(item?.amount_minor)}/></label>;if(method==="PER_HOUR")return <label>Kwota za godzinę ({currency})<input name="hourly" type="number" min="0" step="0.01" required defaultValue={minorToInput(item?.rate_minor_per_hour)}/></label>;if(method==="PERCENT_BASE")return <label>Procent stawki podstawowej<input name="percent" type="number" min="0" step="0.01" required defaultValue={basisPercentToInput(item?.percent_basis_points)}/></label>;if(method==="MULTIPLIER")return <label>Mnożnik stawki<input name="multiplier" type="number" min="0" step="0.01" required defaultValue={basisMultiplierToInput(item?.multiplier_basis_points)}/></label>;return <div className="form-row"><label>Próg (minuty)<input name="thresholdMinutes" type="number" min="0" required defaultValue={Number(item?.threshold_minutes ?? 0)}/></label><label>Dodatek za godzinę po progu ({currency})<input name="hourly" type="number" min="0" step="0.01" required defaultValue={minorToInput(item?.rate_minor_per_hour)}/></label></div>; }

function drawerTitle(kind:MatrixV2SaveKind,editing:boolean){const labels:Record<MatrixV2SaveKind,string>={MATRIX_SETTINGS:"ustawienia Matrixa",ROLE:"rolę",LOCATION:"lokal",DUTY:"obowiązek",SHIFT:"szablon zmiany",ROLE_DUTY:"powiązanie roli i obowiązku",EMPLOYEE_ROLE:"rolę pracownika",EMPLOYEE_LOCATION:"lokal pracownika",EMPLOYEE_DUTY:"kompetencję pracownika",SCENARIO:"scenariusz",STAFFING_RULE:"regułę obsady",STRATEGY:"strategię wariantu",OBJECTIVE:"kryterium strategii",SCENARIO_STRATEGY:"wariant scenariusza",PAY_RULE:"dodatek płacowy",SCENARIO_PAY_RULE:"modyfikację dodatku",SCENARIO_BUDGET:"budżet scenariusza"};return `${editing?"Edytuj":"Dodaj"} ${labels[kind]}`;}
function formText(form:HTMLFormElement,name:string){return String(new FormData(form).get(name)??"").trim();}
function checked(form:HTMLFormElement,name:string){return new FormData(form).has(name);}
function optionalNumber(value:string,multiplier=1){if(value==="")return null;const number=Number(value);if(!Number.isFinite(number))throw new Error("Wpisz prawidłową wartość liczbową.");return Math.round(number*multiplier);}
function requiredNumber(value:string,multiplier=1){const result=optionalNumber(value,multiplier);if(result===null)throw new Error("Uzupełnij wszystkie wymagane wartości liczbowe.");return result;}
function codeFrom(value:string){return value.replace(/[Łł]/g,"L").normalize("NFD").replace(/[\u0300-\u036f]/g,"").toUpperCase().replace(/[^A-Z0-9]+/g,"_").replace(/^_+|_+$/g,"").slice(0,80);}
function minorToInput(value:unknown){return value===undefined||value===null?"":Number(value)/100;}
function basisPercentToInput(value:unknown){return value===undefined||value===null?"":Number(value)/100;}
function basisMultiplierToInput(value:unknown){return value===undefined||value===null?"":Number(value)/10000;}
function asRecord(value:unknown):Record<string,unknown>{return value!==null&&typeof value==="object"&&!Array.isArray(value)?value as Record<string,unknown>:{};}
function optionalInput(value:unknown){if(typeof value==="number"&&Number.isFinite(value))return String(value);if(typeof value==="string"&&/^\d+$/.test(value))return value;return "";}
function booleanOverrideInput(value:unknown){return typeof value==="boolean"?String(value):"";}
function directionOverrideInput(value:unknown){const direction=String(value??"").toUpperCase();if(direction==="MIN"||direction==="MINIMIZE")return "MINIMIZE";if(direction==="MAX"||direction==="MAXIMIZE")return "MAXIMIZE";return "";}
function optionalIntegerValue(value:string,label:string,min=0,max=Number.MAX_SAFE_INTEGER){if(value==="")return null;const number=Number(value);if(!Number.isSafeInteger(number)||number<min||number>max)throw new Error(`${label}: wpisz liczbę całkowitą od ${min} do ${max}.`);return number;}
function optionalBooleanValue(value:string,label:string){if(value==="")return null;if(value==="true")return true;if(value==="false")return false;throw new Error(`${label}: wybierz jedną z dostępnych opcji.`);}

function scenarioSettingsOverridesFromForm(form:HTMLFormElement){
  const overrides:Record<string,unknown>={};
  const maximumShifts=optionalIntegerValue(formText(form,"scenarioMaximumShiftsPerDay"),"Maksymalna liczba zmian dziennie",1,24);
  const minimumRest=optionalIntegerValue(formText(form,"scenarioMinimumRestMinutes"),"Minimalny odpoczynek",0);
  const missingAvailability=optionalBooleanValue(formText(form,"scenarioMissingAvailability"),"Brak wpisu dostępności");
  const requireOptimal=optionalBooleanValue(formText(form,"scenarioRequireOptimal"),"Wymaganie optimum");
  const randomSeed=optionalIntegerValue(formText(form,"scenarioRandomSeed"),"Ziarno losowe",0,2147483647);
  if(maximumShifts!==null)overrides.maximumShiftsPerDay=maximumShifts;
  if(minimumRest!==null)overrides.minimumRestMinutes=minimumRest;
  if(missingAvailability!==null)overrides.missingAvailabilityMeansAvailable=missingAvailability;
  if(requireOptimal!==null)overrides.requireOptimal=requireOptimal;
  if(randomSeed!==null)overrides.randomSeed=randomSeed;
  return overrides;
}

function solverOverridesFromForm(form:HTMLFormElement){
  const overrides:Record<string,unknown>={};
  const maxTimeSeconds=optionalIntegerValue(formText(form,"strategyMaxTimeSeconds"),"Limit czasu",1,86400);
  const randomSeed=optionalIntegerValue(formText(form,"strategyRandomSeed"),"Ziarno losowe",0,2147483647);
  if(maxTimeSeconds!==null)overrides.maxTimeSeconds=maxTimeSeconds;
  if(randomSeed!==null)overrides.randomSeed=randomSeed;
  return overrides;
}

function objectiveOverridesFromForm(form:HTMLFormElement,workspace:MatrixV2Workspace,strategyId:string){
  const overrides:Record<string,Record<string,unknown>>={};
  const objectives=Array.from(new Map(workspace.strategyObjectives
    .filter(objective=>objective.strategy_id===strategyId&&objective.active)
    .map(objective=>[objective.metric_code.toUpperCase(),objective])).values());
  for(const objective of objectives){
    const metric=objective.metric_code.toUpperCase();
    const override:Record<string,unknown>={};
    const active=optionalBooleanValue(formText(form,`objective:${metric}:active`),`Aktywność kryterium ${objectiveName(metric)}`);
    const tier=optionalIntegerValue(formText(form,`objective:${metric}:tier`),`Poziom kryterium ${objectiveName(metric)}`,1,100);
    const weight=optionalIntegerValue(formText(form,`objective:${metric}:weight`),`Waga kryterium ${objectiveName(metric)}`,0);
    const tolerance=optionalIntegerValue(formText(form,`objective:${metric}:tolerance`),`Tolerancja kryterium ${objectiveName(metric)}`,0);
    const direction=formText(form,`objective:${metric}:direction`).toUpperCase();
    if(direction&&!(["MINIMIZE","MAXIMIZE"] as string[]).includes(direction))throw new Error(`Kierunek kryterium ${objectiveName(metric)} jest nieprawidłowy.`);
    const target=optionalIntegerValue(formText(form,`objective:${metric}:target`),`Cel kryterium ${objectiveName(metric)}`,0);
    if(target!==null&&(direction||objective.direction)!=="MINIMIZE")throw new Error(`Cel maksymalny można ustawić wyłącznie dla minimalizowanego kryterium ${objectiveName(metric)}.`);
    if(active!==null)override.active=active;
    if(tier!==null)override.tier=tier;
    if(weight!==null)override.weight=weight;
    if(tolerance!==null)override.tolerance=tolerance;
    if(direction)override.direction=direction;
    if(target!==null)override.parameters={target};
    if(Object.keys(override).length)overrides[metric]=override;
  }
  return overrides;
}

function scenarioStrategySummary(link:MatrixV2ScenarioStrategy){
  const solver=asRecord(link.solver_overrides);
  const parts:string[]=[];
  if(optionalInput(solver.maxTimeSeconds))parts.push(`limit ${optionalInput(solver.maxTimeSeconds)} s`);
  if(optionalInput(solver.randomSeed))parts.push(`seed ${optionalInput(solver.randomSeed)}`);
  const objectiveCount=Object.keys(asRecord(link.objective_overrides)).length;
  if(objectiveCount)parts.push(`${objectiveCount} nadpis. kryteriów`);
  return parts.length?` • ${parts.join(" • ")}`:"";
}

function payloadFromForm(kind:MatrixV2SaveKind,form:HTMLFormElement,item:Record<string,unknown>|undefined,operation:string,payMethod:string,currency:string,workspace:MatrixV2Workspace):Record<string,unknown>{
  const data=new FormData(form);const name=formText(form,"name");const code=formText(form,"code")||codeFrom(name);const common=()=>({code,name,sortOrder:requiredNumber(formText(form,"sortOrder")||"0"),active:checked(form,"active")});
  if(["ROLE","LOCATION","DUTY","STRATEGY"].includes(kind)){if(!name||!code)throw new Error("Podaj nazwę elementu.");if(kind==="ROLE")return{...common(),color:formText(form,"color")};if(kind==="LOCATION"){const timezone=formText(form,"timezone");if(!timezone)throw new Error("Wybierz strefę czasową lokalu.");try{new Intl.DateTimeFormat("en",{timeZone:timezone}).format(new Date(0));}catch{throw new Error("Podaj prawidłową strefę czasową IANA, np. Europe/Warsaw.");}return{...common(),timezone};}if(kind==="DUTY")return{...common(),description:formText(form,"description"),color:formText(form,"color")};return{...common(),description:formText(form,"description"),solverCode:"CP_SAT"};}
  if(kind==="SHIFT"){const days=data.getAll("days").map(Number);if(!days.length)throw new Error("Wybierz co najmniej jeden dzień tygodnia.");return{...common(),locationId:formText(form,"locationId"),shiftPeriod:formText(form,"shiftPeriod"),startsAt:formText(form,"startsAt"),endsAt:formText(form,"endsAt"),endsNextDay:checked(form,"endsNextDay"),days};}
  if(kind==="ROLE_DUTY")return{roleId:formText(form,"roleId"),dutyId:formText(form,"dutyId"),assignmentMode:formText(form,"assignmentMode"),minimumCount:requiredNumber(formText(form,"minimumCount")||"0"),shiftObligation:checked(form,"shiftObligation"),shiftPeriod:checked(form,"shiftObligation")?formText(form,"shiftPeriod"):null,active:checked(form,"active")};
  if(kind==="EMPLOYEE_ROLE"){const validFrom=formText(form,"validFrom"),validTo=formText(form,"validTo");if(validFrom&&validTo&&validTo<validFrom)throw new Error("Data końcowa nie może być wcześniejsza od początkowej.");return{employeeId:formText(form,"employeeId"),roleId:formText(form,"roleId"),isPrimary:checked(form,"isPrimary"),canLead:checked(form,"canLead"),active:checked(form,"active"),validFrom:validFrom||null,validTo:validTo||null};}
  if(kind==="EMPLOYEE_LOCATION"){const validFrom=formText(form,"validFrom"),validTo=formText(form,"validTo");if(validFrom&&validTo&&validTo<validFrom)throw new Error("Data końcowa nie może być wcześniejsza od początkowej.");if(!checked(form,"standardAllowed")&&!checked(form,"overtimeAllowed"))throw new Error("Wybierz zwykły limit lub dopuszczenie nadgodzin.");return{employeeId:formText(form,"employeeId"),locationId:formText(form,"locationId"),standardAllowed:checked(form,"standardAllowed"),overtimeAllowed:checked(form,"overtimeAllowed"),homeLocation:false,active:checked(form,"active"),validFrom:validFrom||null,validTo:validTo||null};}
  if(kind==="EMPLOYEE_DUTY"){const validFrom=formText(form,"validFrom"),validTo=formText(form,"validTo");if(validFrom&&validTo&&validTo<validFrom)throw new Error("Data końcowa nie może być wcześniejsza od początkowej.");return{employeeId:formText(form,"employeeId"),dutyId:formText(form,"dutyId"),roleId:formText(form,"roleId")||null,locationId:formText(form,"locationId")||null,active:checked(form,"active"),validFrom:validFrom||null,validTo:validTo||null};}
  if(kind==="SCENARIO"){const validFrom=formText(form,"validFrom"),validTo=formText(form,"validTo");if(validFrom&&validTo&&validTo<validFrom)throw new Error("Data zakończenia scenariusza nie może być wcześniejsza od daty rozpoczęcia.");return{...common(),description:formText(form,"description"),parentScenarioId:formText(form,"parentScenarioId")||null,color:formText(form,"color"),isDefault:checked(form,"isDefault"),validFrom:validFrom||null,validTo:validTo||null,settingsOverrides:scenarioSettingsOverridesFromForm(form)};}
  if(kind==="STAFFING_RULE")return{scenarioId:formText(form,"scenarioId"),shiftTemplateId:formText(form,"shiftTemplateId"),roleId:formText(form,"roleId"),dutyId:formText(form,"dutyId")||null,operation,countValue:["SET","ADD"].includes(operation)?requiredNumber(formText(form,"countValue")):null,multiplierBasisPoints:operation==="MULTIPLY"?requiredNumber(formText(form,"multiplierPercent"),100):null,active:checked(form,"active"),sourceMetadata:item?.source_metadata??{}};
  if(kind==="OBJECTIVE")return{strategyId:formText(form,"strategyId"),tier:requiredNumber(formText(form,"tier")),metricCode:formText(form,"metricCode"),direction:formText(form,"direction"),weight:requiredNumber(formText(form,"weight")),tolerance:requiredNumber(formText(form,"tolerance")),sortOrder:requiredNumber(formText(form,"sortOrder")||String(item?.sort_order??0)),parameters:item?.parameters??{},active:checked(form,"active")};
  if(kind==="SCENARIO_STRATEGY"){const strategyId=formText(form,"strategyId");if(!strategyId)throw new Error("Wybierz strategię wariantu.");return{scenarioId:formText(form,"scenarioId"),strategyId,sortOrder:requiredNumber(formText(form,"sortOrder")||String(item?.sort_order??0)),active:checked(form,"active"),objectiveOverrides:objectiveOverridesFromForm(form,workspace,strategyId),solverOverrides:solverOverridesFromForm(form)};}
  if(kind==="PAY_RULE"){const days=data.getAll("days").map(Number);if(!days.length)throw new Error("Wybierz co najmniej jeden dzień tygodnia.");const payload:Record<string,unknown>={...common(),description:formText(form,"description"),calculationMethod:payMethod,currency,priority:requiredNumber(formText(form,"priority")),stackingGroup:formText(form,"stackingGroup")||null,stackingMode:formText(form,"stackingMode"),days,localStart:formText(form,"localStart")||null,localEnd:formText(form,"localEnd")||null,validFrom:formText(form,"validFrom")||null,validTo:formText(form,"validTo")||null,roleIds:data.getAll("roleIds"),dutyIds:data.getAll("dutyIds"),locationIds:data.getAll("locationIds"),shiftIds:data.getAll("shiftIds")};if(payMethod==="FIXED_PER_SHIFT")payload.amountMinor=requiredNumber(formText(form,"amount"),100);if(["PER_HOUR","SHIFT_DURATION_THRESHOLD_PER_HOUR","MONTHLY_THRESHOLD_PER_HOUR"].includes(payMethod))payload.rateMinorPerHour=requiredNumber(formText(form,"hourly"),100);if(payMethod==="PERCENT_BASE")payload.percentBasisPoints=requiredNumber(formText(form,"percent"),100);if(payMethod==="MULTIPLIER")payload.multiplierBasisPoints=requiredNumber(formText(form,"multiplier"),10000);if(payMethod.includes("THRESHOLD"))payload.thresholdMinutes=requiredNumber(formText(form,"thresholdMinutes"));return payload;}
  if(kind==="SCENARIO_PAY_RULE")return{scenarioId:formText(form,"scenarioId"),payRuleId:formText(form,"payRuleId"),enabled:checked(form,"enabled"),amountMinor:optionalNumber(formText(form,"amount"),100),rateMinorPerHour:optionalNumber(formText(form,"hourly"),100),percentBasisPoints:optionalNumber(formText(form,"percent"),100),multiplierBasisPoints:optionalNumber(formText(form,"multiplier"),10000),formulaExpression:item?.formula_expression??null};
  const budgetMonth=formText(form,"budgetMonth");return{scenarioId:formText(form,"scenarioId"),budgetMonth:budgetMonth?`${budgetMonth}-01`:null,locationId:formText(form,"locationId")||null,roleId:formText(form,"roleId")||null,dutyId:formText(form,"dutyId")||null,operation,amountMinor:["SET","ADD"].includes(operation)?requiredNumber(formText(form,"amount"),100):null,multiplierBasisPoints:operation==="MULTIPLY"?requiredNumber(formText(form,"multiplierPercent"),100):null,currency,hardLimit:checked(form,"hardLimit"),warningPercent:requiredNumber(formText(form,"warningPercent")),sourceMetadata:item?.source_metadata??{}};
}
