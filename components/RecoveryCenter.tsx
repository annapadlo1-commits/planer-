"use client";

import {
  AlertTriangle, ArrowRight, BadgeCheck, BriefcaseBusiness, CalendarDays, Check,
  CircleDollarSign, Clock3, FileWarning, LifeBuoy, LoaderCircle, Mail, Plus,
  RefreshCw, Send, ShieldAlert, Sparkles, UserPlus, Users, X,
} from "lucide-react";
import { useEffect, useMemo, useState, type CSSProperties } from "react";

import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {
  applyRecoveryDraft, getEmployeeRecoveryOffers, getRecoveryIncidentDetail, getRecoveryWorkspace,
  prepareRecoveryIncident, recoveryErrorMessage, respondRecoveryOffer,
  saveRecoveryAdHoc, saveRecoveryBudget, saveRecoveryIncident, saveRecoveryOverride,
  selectRecoveryCandidate,
  type RecoveryIncidentDetail, type RecoveryMode, type RecoveryOffer, type RecoveryShortage,
  type RecoveryWorkspace,
} from "@/lib/recovery-center";

type EmployeeOption = { id: string; employeeNo: string; firstName: string; lastName: string; active: boolean };
type Props = {
  month: string;
  employees?: EmployeeOption[];
  currency?: string;
  employeeMode?: boolean;
  notify: (message: string) => void;
  fail: (message: string) => void;
  reload?: () => Promise<void> | void;
};

const modeCopy: Record<RecoveryMode, { label: string; description: string; icon: typeof Sparkles }> = {
  PROPOSE: { label: "Zaproponuj", description: "System diagnozuje i przygotowuje najlepszą naprawę. Niczego nie zapisuje do grafiku.", icon: Sparkles },
  SEND_OFFERS: { label: "Wyślij oferty", description: "Kandydaci otrzymują propozycję. Akceptacja nadal wymaga końcowej kontroli lidera.", icon: Send },
  AUTO_DRAFT: { label: "Przygotuj wersję roboczą", description: "System przygotowuje przypisania, ale nie zmienia opublikowanego grafiku bez publikacji.", icon: BadgeCheck },
};

const incidentLabels: Record<string, string> = {
  SICKNESS: "L4 / choroba", LEAVE: "Urlop", DEPARTURE: "Nagłe odejście",
  CONTRACT_WITHDRAWAL: "Wycofanie zleceniobiorcy", STRUCTURAL_SHORTAGE: "Brak strukturalny", OTHER: "Inny incydent",
};

const contractLabels: Record<string, string> = {
  UMOWA_O_PRACE: "Umowa o pracę", CZESC_ETATU: "Część etatu",
  ZLECENIE: "Umowa zlecenie", B2B: "B2B", INNE: "Inna forma współpracy",
};

function money(minor: number | null | undefined, currency = "PLN") {
  if (minor === null || minor === undefined) return "do uzgodnienia";
  return new Intl.NumberFormat("pl-PL", { style: "currency", currency }).format(minor / 100);
}

function time(value?: string | null) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("pl-PL", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Warsaw" }).format(new Date(value));
}

function roleStyle(color?: string | null): CSSProperties {
  const accent = color || "#6D4BEF";
  return { "--recovery-role": accent } as CSSProperties;
}

export function RecoveryCenter({ month, employees = [], currency = "PLN", employeeMode = false, notify, fail, reload }: Props) {
  const supabase = useMemo(() => createSupabaseBrowserClient()!, []);
  const [workspace, setWorkspace] = useState<RecoveryWorkspace | null>(null);
  const [offers, setOffers] = useState<RecoveryOffer[]>([]);
  const [detail, setDetail] = useState<RecoveryIncidentDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [activeTab, setActiveTab] = useState<"SHORTAGES" | "INCIDENTS" | "AD_HOC" | "BUDGET">("SHORTAGES");
  const [showIncidentForm, setShowIncidentForm] = useState(false);
  const [incidentForm, setIncidentForm] = useState({
    employeeId: "", roleId: "", locationId: "", type: "SICKNESS", startsOn: `${month}-01`, endsOn: `${month}-01`,
    title: "", notes: "", mode: "PROPOSE" as RecoveryMode,
  });
  const [adHocForm, setAdHocForm] = useState({ name: "", email: "", phone: "", roleId: "", contractType: "ZLECENIE", rate: "", availableFrom: `${month}-01`, availableTo: `${month}-01`, notes: "" });
  const [budgetForm, setBudgetForm] = useState({ amount: "0", warningPercent: "90", hardLimit: false });
  const [overrideForm, setOverrideForm] = useState({ type: "BUDGET_DELTA", value: "", justification: "", acknowledged: false, complianceConfirmed: false });

  const load = async () => {
    setLoading(true);
    try {
      if (employeeMode) setOffers(await getEmployeeRecoveryOffers(supabase, month));
      else {
        const next = await getRecoveryWorkspace(supabase, month);
        setWorkspace(next);
        setBudgetForm({
          amount: String(next.budget?.amount ?? 0),
          warningPercent: String(next.budget?.warningPercent ?? 90),
          hardLimit: Boolean(next.budget?.hardLimit),
        });
      }
    } catch (error) { fail(recoveryErrorMessage(error)); }
    finally { setLoading(false); }
  };

  useEffect(() => { void load(); }, [month, employeeMode]); // eslint-disable-line react-hooks/exhaustive-deps

  const saveIncident = async () => {
    if (!workspace) return;
    setBusy(true);
    try {
      const result = await saveRecoveryIncident(supabase, {
        month, expectedRevision: workspace.revision, employeeId: incidentForm.employeeId || null,
        roleId: incidentForm.roleId || null, locationId: incidentForm.locationId || null,
        type: incidentForm.type, startsOn: incidentForm.startsOn,
        endsOn: incidentForm.endsOn, title: incidentForm.title, notes: incidentForm.notes, mode: incidentForm.mode,
      });
      setShowIncidentForm(false);
      notify("Incydent zapisany. Teraz wybierz sposób naprawy — opublikowany grafik nie został zmieniony.");
      await load();
      const incidentId = String(result.id ?? "");
      if (incidentId) setDetail(await getRecoveryIncidentDetail(supabase, incidentId));
    } catch (error) { fail(recoveryErrorMessage(error)); await load(); }
    finally { setBusy(false); }
  };

  const openShortage = (shortage: RecoveryShortage) => {
    setIncidentForm({ employeeId: "", roleId: shortage.roleId, locationId: shortage.locationId, type: "STRUCTURAL_SHORTAGE", startsOn: shortage.firstDate,
      endsOn: shortage.lastDate, title: `Brak strukturalny: ${shortage.roleName} • ${shortage.locationName}`,
      notes: `${shortage.missingHours} roboczogodzin do pokrycia; dni: ${shortage.dates.join(", ")}.`, mode: "PROPOSE" });
    setShowIncidentForm(true);
  };

  const prepare = async (mode: RecoveryMode) => {
    if (!workspace || !detail) return;
    setBusy(true);
    try {
      await prepareRecoveryIncident(supabase, detail.id, workspace.revision, mode);
      notify(mode === "SEND_OFFERS" ? "Oferty wysłane. Odpowiedzi pracowników pojawią się w tym incydencie." : "Plan naprawy przygotowany. Opublikowany grafik pozostaje bez zmian.");
      await load();
      setDetail(await getRecoveryIncidentDetail(supabase, detail.id));
    } catch (error) { fail(recoveryErrorMessage(error)); await load(); }
    finally { setBusy(false); }
  };

  const selectCandidate = async (actionId: string, employeeId: string, actionVersion: number) => {
    if (!workspace || !detail) return;
    setBusy(true);
    try {
      await selectRecoveryCandidate(supabase, { actionId, employeeId, expectedActionVersion: actionVersion, expectedRevision: workspace.revision });
      notify("Kandydat wybrany do wersji roboczej. Opublikowany grafik nadal nie został zmieniony.");
      await load();
      setDetail(await getRecoveryIncidentDetail(supabase, detail.id));
    } catch (error) { fail(recoveryErrorMessage(error)); await load(); setDetail(await getRecoveryIncidentDetail(supabase, detail.id)); }
    finally { setBusy(false); }
  };

  const createLeaderDraft = async () => {
    if (!workspace || !detail) return;
    setBusy(true);
    try {
      const result = await applyRecoveryDraft(supabase, detail.id, workspace.revision);
      const drafts = Array.isArray(result.drafts) ? result.drafts.length : 0;
      notify(`Utworzono ${drafts} ${drafts === 1 ? "wersję roboczą roli" : "wersje robocze ról"}. Teraz lider sprawdza je i publikuje zwykłą ścieżką.`);
      await load();
      setDetail(await getRecoveryIncidentDetail(supabase, detail.id));
      await reload?.();
    } catch (error) { fail(recoveryErrorMessage(error)); await load(); setDetail(await getRecoveryIncidentDetail(supabase, detail.id)); }
    finally { setBusy(false); }
  };

  const saveAdHoc = async () => {
    if (!adHocForm.roleId) { fail("Wybierz rolę pracownika ad-hoc."); return; }
    setBusy(true);
    try {
      await saveRecoveryAdHoc(supabase, { name: adHocForm.name, email: adHocForm.email, phone: adHocForm.phone,
        roleId: adHocForm.roleId, contractType: adHocForm.contractType,
        rateMinor: adHocForm.rate ? Math.round(Number(adHocForm.rate) * 100) : null, currency,
        availableFrom: adHocForm.availableFrom, availableTo: adHocForm.availableTo, notes: adHocForm.notes });
      notify("Osoba została dodana do puli ad-hoc. Nie będzie używana w standardowym generatorze.");
      setAdHocForm(current => ({ ...current, name: "", email: "", phone: "", rate: "", notes: "" }));
      await load();
    } catch (error) { fail(recoveryErrorMessage(error)); }
    finally { setBusy(false); }
  };

  const saveBudget = async () => {
    setBusy(true);
    try {
      await saveRecoveryBudget(supabase, month, Number(budgetForm.amount), Number(budgetForm.warningPercent), budgetForm.hardLimit);
      notify("Budżet bazowy miesiąca zapisany i objęty audytem."); await load(); await reload?.();
    } catch (error) { fail(recoveryErrorMessage(error)); }
    finally { setBusy(false); }
  };

  const saveOverride = async () => {
    if (!detail) return;
    setBusy(true);
    try {
      await saveRecoveryOverride(supabase, { incidentId: detail.id, type: overrideForm.type,
        roleId: detail.roleId, employeeId: detail.employeeId, startsOn: detail.startsOn, endsOn: detail.endsOn,
        numericValue: Math.round(Number(overrideForm.value) * (overrideForm.type === "BUDGET_DELTA" ? 100 : 60)),
        currency: overrideForm.type === "BUDGET_DELTA" ? currency : null,
        justification: overrideForm.justification, employeeAcknowledged: overrideForm.acknowledged,
        complianceConfirmed: overrideForm.complianceConfirmed });
      notify("Wyjątek zapisany z zakresem dat, uzasadnieniem i osobą zatwierdzającą.");
      setDetail(await getRecoveryIncidentDetail(supabase, detail.id));
    } catch (error) { fail(recoveryErrorMessage(error)); }
    finally { setBusy(false); }
  };

  if (loading) return <section className="recovery-center loading"><LoaderCircle className="spin"/><strong>Pobieram pełny kontekst naprawy grafiku…</strong></section>;

  if (employeeMode) return <EmployeeRecoveryOffers offers={offers} busy={busy} decide={async (offer, accept) => {
    setBusy(true); try { await respondRecoveryOffer(supabase, offer.id, accept); notify(accept ? "Oferta przyjęta. Lider otrzymał odpowiedź." : "Oferta odrzucona."); await load(); }
    catch (error) { fail(recoveryErrorMessage(error)); } finally { setBusy(false); }
  }}/>

  if (!workspace) return <section className="recovery-center empty"><AlertTriangle/><h2>Centrum napraw jest niedostępne</h2><button className="secondary-button" onClick={() => void load()}><RefreshCw/> Odśwież</button></section>;

  return <section className="recovery-center">
    <header className="recovery-hero">
      <span><small>OPERACJE • B4 PLUS B5</small><h2>Centrum napraw grafiku</h2><p>Diagnoza, kandydaci, koszt i ryzyko w jednym miejscu. Każda ingerencja w opublikowany grafik wymaga decyzji człowieka.</p></span>
      <div><span><b>Rewizja {workspace.revision}</b><small>chroni przed nadpisaniem zmian innego lidera</small></span><button className="secondary-button" onClick={() => void load()}><RefreshCw/> Odśwież</button><button className="primary-button" onClick={() => setShowIncidentForm(true)}><Plus/> Nowy incydent</button></div>
    </header>
    {!workspace.schedule && <div className="recovery-notice warning"><FileWarning/><span><strong>Brak scalonego grafiku firmy</strong><small>Centrum analizuje opublikowane grafiki ról. Przed zmianą całej firmy opublikuj wersję scaloną.</small></span></div>}
    <nav className="recovery-tabs">
      <button className={activeTab === "SHORTAGES" ? "active" : ""} onClick={() => setActiveTab("SHORTAGES")}><ShieldAlert/> Braki <b>{workspace.shortages.length}</b></button>
      <button className={activeTab === "INCIDENTS" ? "active" : ""} onClick={() => setActiveTab("INCIDENTS")}><LifeBuoy/> Incydenty <b>{workspace.incidents.length}</b></button>
      <button className={activeTab === "AD_HOC" ? "active" : ""} onClick={() => setActiveTab("AD_HOC")}><UserPlus/> Pula ad-hoc <b>{workspace.adHocPool.length}</b></button>
      <button className={activeTab === "BUDGET" ? "active" : ""} onClick={() => setActiveTab("BUDGET")}><CircleDollarSign/> Budżet i limity</button>
    </nav>

    {activeTab === "SHORTAGES" && <div className="recovery-shortage-grid">
      {workspace.shortages.map(shortage => <article key={`${shortage.roleId}:${shortage.locationId}:${shortage.startsAt}`} style={roleStyle(shortage.roleColor)} className={shortage.structural ? "structural" : ""}>
        <i/><header><span><small>{shortage.structural ? "POWTARZALNY BRAK ZASOBÓW" : "POJEDYNCZY WAKAT"}</small><h3>{shortage.roleName} • {shortage.locationName}</h3><p>{shortage.startsAt}–{shortage.endsAt}</p></span><strong>{shortage.missingHours} h</strong></header>
        <div className="recovery-kpis"><span><b>{shortage.missingSlots}</b><small>miejsc</small></span><span><b>{shortage.affectedDays}</b><small>dni</small></span><span><b>{shortage.firstDate}</b><small>pierwszy brak</small></span></div>
        <p>{shortage.structural ? "To nie jest problem pojedynczego grafiku. Potrzebna jest decyzja kadrowa lub operacyjna." : "System wykrył konkretną zmianę wymagającą naprawy."}</p>
        <details><summary>Możliwe działania</summary><ul>{shortage.actions.map(action => <li key={action}>{action}</li>)}</ul></details>
        <button className="primary-button" onClick={() => openShortage(shortage)}>Przygotuj naprawę <ArrowRight/></button>
      </article>)}
      {!workspace.shortages.length && <div className="recovery-empty"><Check/><h3>Brak nieobsadzonych miejsc</h3><p>Opublikowany zestaw grafików nie ma wakatów do naprawy.</p></div>}
    </div>}

    {activeTab === "INCIDENTS" && <div className="recovery-incident-list">
      {workspace.incidents.map(incident => <button key={incident.id} style={roleStyle(incident.roleColor)} onClick={async () => setDetail(await getRecoveryIncidentDetail(supabase, incident.id))}>
        <i/><span><small>{incidentLabels[incident.type] ?? incident.type} • {incident.status}</small><strong>{incident.title}</strong><em>{incident.startsOn} – {incident.endsOn}{incident.employeeName ? ` • ${incident.employeeName}` : ""}</em></span>
        <span><b>{incident.actionCount}</b><small>propozycji</small><b>{incident.offerCount}</b><small>ofert</small></span><ArrowRight/>
      </button>)}
      {!workspace.incidents.length && <div className="recovery-empty"><LifeBuoy/><h3>Brak aktywnych incydentów</h3><p>Dodaj L4, urlop, odejście lub brak strukturalny.</p></div>}
    </div>}

    {activeTab === "AD_HOC" && <div className="recovery-ad-hoc-layout">
      <section><h3>Pula pracowników awaryjnych</h3><p>Te osoby nie trafiają do standardowego generatora. System pokazuje je dopiero przy brakach i incydentach.</p><div className="recovery-ad-hoc-list">{workspace.adHocPool.map(worker => <article key={worker.id} style={roleStyle(worker.roleColor)}><i/><span><b>{worker.name}</b><small>{worker.roleName} • {contractLabels[worker.contractType] ?? worker.contractType}</small><em>{money(worker.rateMinor, worker.currency)} • {worker.availableFrom || "bez daty"}–{worker.availableTo || "bez końca"}</em></span></article>)}</div></section>
      <form onSubmit={event => { event.preventDefault(); void saveAdHoc(); }}><h3>Dodaj skrócony profil ad-hoc</h3><label>Imię i nazwisko<input required value={adHocForm.name} onChange={event => setAdHocForm({...adHocForm,name:event.target.value})}/></label><div className="recovery-form-grid"><label>E-mail<input type="email" value={adHocForm.email} onChange={event => setAdHocForm({...adHocForm,email:event.target.value})}/></label><label>Telefon<input value={adHocForm.phone} onChange={event => setAdHocForm({...adHocForm,phone:event.target.value})}/></label></div><label>Rola<select required value={adHocForm.roleId} onChange={event => setAdHocForm({...adHocForm,roleId:event.target.value})}><option value="">Wybierz rolę</option>{workspace.roleScopes.filter(role => role.canManage).map(role => <option key={role.roleId} value={role.roleId}>{role.roleName}</option>)}</select></label><div className="recovery-form-grid"><label>Rodzaj współpracy<select value={adHocForm.contractType} onChange={event => setAdHocForm({...adHocForm,contractType:event.target.value})}><option value="ZLECENIE">Umowa zlecenie</option><option value="B2B">B2B</option><option value="UMOWA_O_PRACE">Umowa o pracę</option><option value="CZESC_ETATU">Część etatu</option><option value="INNE">Inna forma — wymaga weryfikacji</option></select></label><label>Stawka godzinowa<input type="number" min="0" step="0.01" value={adHocForm.rate} onChange={event => setAdHocForm({...adHocForm,rate:event.target.value})}/></label></div><div className="recovery-form-grid"><label>Dostępny od<input type="date" value={adHocForm.availableFrom} onChange={event => setAdHocForm({...adHocForm,availableFrom:event.target.value})}/></label><label>Dostępny do<input type="date" value={adHocForm.availableTo} onChange={event => setAdHocForm({...adHocForm,availableTo:event.target.value})}/></label></div><label>Ustalenia<textarea value={adHocForm.notes} onChange={event => setAdHocForm({...adHocForm,notes:event.target.value})}/></label><div className="recovery-legal-note"><ShieldAlert/><span><b>Profil skrócony nie zastępuje formalności</b><small>Przed przypisaniem wymagane są potwierdzone warunki współpracy, stawka i końcowa kontrola obowiązków. Zwykłej pracy zmianowej nie opisujemy jako umowy o dzieło.</small></span></div><button className="primary-button" disabled={busy}><UserPlus/> Dodaj do puli ad-hoc</button></form>
    </div>}

    {activeTab === "BUDGET" && <div className="recovery-budget-layout">
      <form onSubmit={event => { event.preventDefault(); void saveBudget(); }}><CircleDollarSign/><h3>Budżet bazowy • {month}</h3><p>To jest nadrzędny budżet właściciela dla miesiąca. Incydenty mogą mieć osobne, datowane zwiększenia.</p><label>Kwota<input type="number" min="0" step="0.01" value={budgetForm.amount} onChange={event => setBudgetForm({...budgetForm,amount:event.target.value})}/></label><label>Próg ostrzeżenia (%)<input type="number" min="1" max="100" value={budgetForm.warningPercent} onChange={event => setBudgetForm({...budgetForm,warningPercent:event.target.value})}/></label><label className="check-label"><input type="checkbox" checked={budgetForm.hardLimit} onChange={event => setBudgetForm({...budgetForm,hardLimit:event.target.checked})}/> Blokuj publikację po przekroczeniu budżetu</label><button className="primary-button" disabled={busy}><CircleDollarSign/> Zapisz budżet</button></form>
      <section><h3>Zasady wyjątków</h3><div className="recovery-rule-list"><span><b>Twarde reguły</b><small>Rola, kwalifikacje, nakładanie zmian i brak aktywnej współpracy pozostają blokujące.</small></span><span><b>Świadome wyjątki</b><small>Budżet, tygodniowy lub miesięczny limit mogą zostać czasowo rozszerzone z datą, powodem i audytem.</small></span><span><b>Umowa i zgoda</b><small>Dostępność nie oznacza automatycznej zgody. Oferty oraz wyjątki wymagają potwierdzenia, gdy wynika to z zasad współpracy.</small></span></div></section>
    </div>}

    {showIncidentForm && <div className="recovery-overlay"><form className="recovery-dialog" onSubmit={event => { event.preventDefault(); void saveIncident(); }}><header><span><small>NOWY INCYDENT</small><h2>Zaplanuj naprawę bez cichej zmiany grafiku</h2></span><button type="button" className="icon-button" onClick={() => setShowIncidentForm(false)}><X/></button></header><div className="recovery-form-grid"><label>Rodzaj<select value={incidentForm.type} onChange={event => setIncidentForm({...incidentForm,type:event.target.value})}>{Object.entries(incidentLabels).map(([value,label]) => <option key={value} value={value}>{label}</option>)}</select></label><label>Tryb<select value={incidentForm.mode} onChange={event => setIncidentForm({...incidentForm,mode:event.target.value as RecoveryMode})}>{Object.entries(modeCopy).map(([value,item]) => <option key={value} value={value}>{item.label}</option>)}</select></label></div><label>Tytuł<input required value={incidentForm.title} onChange={event => setIncidentForm({...incidentForm,title:event.target.value})} placeholder="np. L4 Anny — potrzebne zastępstwa"/></label><div className="recovery-form-grid"><label>Od<input type="date" required value={incidentForm.startsOn} onChange={event => setIncidentForm({...incidentForm,startsOn:event.target.value})}/></label><label>Do<input type="date" required value={incidentForm.endsOn} onChange={event => setIncidentForm({...incidentForm,endsOn:event.target.value})}/></label></div><label>Pracownik (opcjonalnie)<select value={incidentForm.employeeId} onChange={event => setIncidentForm({...incidentForm,employeeId:event.target.value})}><option value="">Brak — problem obsady</option>{employees.filter(employee => employee.active).map(employee => <option key={employee.id} value={employee.id}>{employee.firstName} {employee.lastName} • {employee.employeeNo}</option>)}</select></label><div className="recovery-form-grid"><label>Rola<select value={incidentForm.roleId} onChange={event => setIncidentForm({...incidentForm,roleId:event.target.value})}><option value="">Wszystkie role</option>{workspace.roleScopes.filter(role => role.canManage).map(role => <option key={role.roleId} value={role.roleId}>{role.roleName}</option>)}</select></label><label>Lokal<select value={incidentForm.locationId} onChange={event => setIncidentForm({...incidentForm,locationId:event.target.value})}><option value="">Wszystkie lokale</option>{workspace.locationScopes.filter(location => location.canManage).map(location => <option key={location.locationId} value={location.locationId}>{location.locationName}</option>)}</select></label></div><label>Notatka<textarea value={incidentForm.notes} onChange={event => setIncidentForm({...incidentForm,notes:event.target.value})}/></label><div className="recovery-mode-preview">{Object.entries(modeCopy).map(([value,item]) => { const Icon=item.icon; return <button type="button" className={incidentForm.mode===value?"active":""} key={value} onClick={() => setIncidentForm({...incidentForm,mode:value as RecoveryMode})}><Icon/><b>{item.label}</b><small>{item.description}</small></button>; })}</div><button className="primary-button" disabled={busy}>{busy?<LoaderCircle className="spin"/>:<LifeBuoy/>} Zapisz incydent</button></form></div>}

    {detail && <div className="recovery-overlay"><section className="recovery-detail"><header><span><small>{incidentLabels[detail.type] ?? detail.type} • {detail.status}</small><h2>{detail.title}</h2><p>{detail.startsOn} – {detail.endsOn}{detail.contractType ? ` • ${contractLabels[detail.contractType] ?? detail.contractType}` : ""}</p></span><button className="icon-button" onClick={() => setDetail(null)}><X/></button></header><div className="recovery-mode-preview">{(Object.keys(modeCopy) as RecoveryMode[]).map(mode => { const item=modeCopy[mode],Icon=item.icon; return <button disabled={busy || detail.status === "APPLIED"} key={mode} onClick={() => void prepare(mode)}><Icon/><b>{item.label}</b><small>{item.description}</small></button>; })}</div><div className="recovery-action-list">{detail.actions.map(action => <article key={action.id} style={roleStyle(action.roleColor)}><i/><header><span><small>{action.shiftDate} • {action.locationName}</small><h3>{action.roleName} • {time(action.startsAt)}–{time(action.endsAt)}</h3></span><b className={`risk ${action.risk.toLowerCase()}`}>{action.risk}</b></header><div className="recovery-candidate-grid">{action.candidates.map(candidate => <button type="button" disabled={!candidate.eligible || busy || detail.status === "APPLIED"} onClick={() => void selectCandidate(action.id,candidate.employeeId,action.version)} className={`${candidate.eligible ? "eligible" : "blocked"}${action.selectedEmployeeId===candidate.employeeId ? " selected" : ""}`} key={candidate.employeeId}><Users/><b>{candidate.name}</b><small>{candidate.source === "STANDBY" ? `Rezerwa ${candidate.tier}` : "Aktywny zespół"} • {contractLabels[candidate.contractType || ""] ?? candidate.contractType ?? "brak typu umowy"}</small><em>{Math.round((candidate.monthMinutes ?? 0)/60)} h w miesiącu • cel {Math.round((candidate.nominalMonthlyMinutes ?? 0)/60)} h</em>{candidate.reasons?.length ? <i>{candidate.reasons.join(" • ")}</i> : <i>{action.selectedEmployeeId===candidate.employeeId ? "Wybrano do wersji roboczej" : "Kliknij, aby wybrać"}</i>}</button>)}{!action.candidates.length && <p>Brak bezpiecznego kandydata. Użyj puli ad-hoc lub decyzji biznesowej.</p>}</div>{action.warnings.map(warning => <div className="recovery-notice warning" key={warning.code}><AlertTriangle/><small>{warning.message}</small></div>)}</article>)}{!detail.actions.length && <div className="recovery-empty"><Sparkles/><h3>Wybierz tryb naprawy</h3><p>System przygotuje kandydatów, ryzyka i koszt dla każdej zmiany.</p></div>}</div>{detail.status === "APPLIED" ? <div className="recovery-draft-result"><BadgeCheck/><span><b>Wersje robocze ról zostały utworzone</b><small>Opublikowany grafik nie zmienił się. Lider otwiera grafik danej roli, sprawdza całość i publikuje poprawioną wersję standardową ścieżką.</small></span></div> : <div className="recovery-finalize"><span><b>Gotowe decyzje: {detail.actions.filter(action => action.selectedEmployeeId).length}/{detail.actions.length}</b><small>Możesz utworzyć częściową wersję roboczą. Niewybrane braki pozostaną jawnie nieobsadzone.</small></span><button className="primary-button" disabled={busy || !detail.actions.some(action => action.selectedEmployeeId)} onClick={() => void createLeaderDraft()}>{busy?<LoaderCircle className="spin"/>:<BadgeCheck/>} Utwórz wersję roboczą ról</button></div>}<form className="recovery-override" onSubmit={event => { event.preventDefault(); void saveOverride(); }}><h3>Datowany wyjątek na czas incydentu</h3><div className="recovery-form-grid"><label>Rodzaj<select value={overrideForm.type} onChange={event => setOverrideForm({...overrideForm,type:event.target.value})}><option value="BUDGET_DELTA">Dodatkowy budżet</option><option value="WEEKLY_LIMIT">Limit tygodniowy (h)</option><option value="MONTHLY_LIMIT">Limit miesięczny (h)</option><option value="STAFFING_MINIMUM">Minimum obsady</option><option value="OPERATING_HOURS">Godziny działalności</option></select></label><label>Wartość<input required type="number" step="0.01" value={overrideForm.value} onChange={event => setOverrideForm({...overrideForm,value:event.target.value})}/></label></div><label>Uzasadnienie<input required minLength={10} value={overrideForm.justification} onChange={event => setOverrideForm({...overrideForm,justification:event.target.value})} placeholder="Minimum 10 znaków — trafia do audytu"/></label><label className="check-label"><input type="checkbox" checked={overrideForm.acknowledged} onChange={event => setOverrideForm({...overrideForm,acknowledged:event.target.checked})}/> Pracownik został poinformowany / wyraził wymaganą zgodę</label><label className="check-label"><input type="checkbox" checked={overrideForm.complianceConfirmed} onChange={event => setOverrideForm({...overrideForm,complianceConfirmed:event.target.checked})}/> Właściciel potwierdza kontrolę zgodności czasu pracy i podstawy umownej</label><small className="recovery-compliance-copy">To potwierdzenie nie zastępuje oceny HR/prawnej. Dla umowy o pracę system nie zapisze wyjątku limitu bez obu potwierdzeń.</small><button className="secondary-button" disabled={busy}><Clock3/> Zapisz wyjątek</button></form></section></div>}
  </section>;
}

function EmployeeRecoveryOffers({ offers, busy, decide }: { offers: RecoveryOffer[]; busy: boolean; decide: (offer: RecoveryOffer, accept: boolean) => Promise<void> }) {
  return <section className="employee-recovery-offers"><header><span><small>NAGŁE ZASTĘPSTWA</small><h2>Oferty dodatkowych zmian</h2><p>Dostępność nie jest zgodą. To Ty decydujesz, czy chcesz przyjąć propozycję.</p></span><Mail/></header><div>{offers.map(offer => <article key={offer.id}><span><small>{offer.shiftDate} • {offer.locationName}</small><h3>{offer.roleName} • {time(offer.startsAt)}–{time(offer.endsAt)}</h3><p>{offer.title}</p>{offer.rateMinor != null && <b>{money(offer.rateMinor, offer.currency || "PLN")}</b>}</span>{offer.status === "PENDING" ? <div><button disabled={busy} className="secondary-button" onClick={() => void decide(offer,false)}>Odrzuć</button><button disabled={busy} className="primary-button" onClick={() => void decide(offer,true)}>Przyjmij</button></div> : <strong className={offer.status === "ACCEPTED" ? "accepted" : "rejected"}>{offer.status === "ACCEPTED" ? "Przyjęta" : "Odrzucona"}</strong>}</article>)}</div>{!offers.length && <div className="recovery-empty"><Check/><h3>Brak oczekujących ofert</h3><p>Nowe propozycje pojawią się tutaj oraz w powiadomieniach.</p></div>}</section>;
}
