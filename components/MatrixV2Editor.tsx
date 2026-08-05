"use client";

import {
  AlertTriangle, Archive, Boxes, Check, ChevronRight, CircleDollarSign, Clock3,
  Download, Edit3, FileSpreadsheet, GitBranch, Layers3, Link2, MapPin, Plus,
  Save, ShieldCheck, Upload, RefreshCw, Settings, Sparkles, Target, Trash2, Users, X,
  History as HistoryIcon,
} from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { configurationBlockerAction } from "@/lib/product-journey";
import { readMatrixWorkbook } from "@/lib/matrix-workbook-import";
import { employeeMatchesWorkforceQuery, workforceProfileReadiness, type WorkforceProfileCheckKey } from "@/lib/workforce-profile";
import { automaticShiftPeriod, equivalentShiftKey, parseTime24 } from "@/lib/uat006-workflows";
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
  type MatrixV2PublicationBlocker,
  type MatrixV2PublicationReadiness,
} from "@/lib/matrix-v2";

type MatrixTab = "structure" | "workforce" | "strategies" | "finance";
type EditableItem = MatrixV2NamedItem | MatrixV2Shift | MatrixV2RoleDuty |
  MatrixV2Scenario | MatrixV2StaffingRule | MatrixV2Strategy | MatrixV2Objective |
  MatrixV2ScenarioStrategy | MatrixV2PayRule | MatrixV2ScenarioPayRule | MatrixV2Budget |
  MatrixV2EmployeeRole | MatrixV2EmployeeLocation | MatrixV2EmployeeDuty;
type EditTarget = { kind: MatrixV2SaveKind; item?: EditableItem | Record<string, unknown> };
type MatrixRevisionVersion={
  id:string;version:number;name:string;status:"DRAFT"|"ACTIVE"|"ARCHIVED";
  effectiveFrom:string;effectiveTo?:string|null;createdAt:string;activatedAt?:string|null;
  publishedAt?:string|null;baseVersionId?:string|null;contentHash?:string|null;
  workforceHash?:string|null;createdBy:string;publishedBy?:string|null;
  counts:Record<string,number>;
};
type MatrixAuditEntry={
  id:number;createdAt:string;actorId?:string|null;actor:string;matrixVersionId?:string|null;
  section:string;entityType:string;entityId:string;action:string;
  oldData?:Record<string,unknown>|null;newData?:Record<string,unknown>|null;
};
type MatrixHistoryPayload={versions:MatrixRevisionVersion[];audit:MatrixAuditEntry[]};
type MatrixVersionComparison={settingsChanged:boolean;sections:{key:string;label:string;leftCount:number;rightCount:number;changed:boolean}[]};
type UatResetPreview={enabled:boolean;draftMatrixVersionId?:string|null;draftVersion?:number|null;confirmation:string;employees:number;roleAssignments:number;locationAssignments:number;dutyAssignments:number;preserves:string[]};

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
const EXPECTED_ACTIVE_EMPLOYEES = 76;

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
function contractTypeLabel(value?:string|null){return ({UMOWA_O_PRACE:"Umowa o pracę",CZESC_ETATU:"Część etatu",ZLECENIE:"Umowa zlecenie",B2B:"B2B",INNE:"Inna"} as Record<string,string>)[value??"INNE"]??"Inna";}
function localToday(timezone:string){
  const parts=Object.fromEntries(new Intl.DateTimeFormat("en",{timeZone:timezone,year:"numeric",month:"2-digit",day:"2-digit"}).formatToParts(new Date()).filter(part=>part.type!=="literal").map(part=>[part.type,part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
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
  month, data, reload, notify, fail, focusEmployeeId, initialTab, createEmployeeRequest, onCreateEmployeeOpened,
}: {
  month: string;
  data: MatrixV2Workspace;
  reload: () => Promise<void>;
  notify: (message: string) => void;
  fail: (message: string) => void;
  focusEmployeeId?: string | null;
  initialTab?: MatrixTab;
  createEmployeeRequest?: number;
  onCreateEmployeeOpened?: () => void;
}) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const tabStorageKey = `grafik-pro:matrix-v2:${data.matrixVersion.id}:tab`;
  const [tab, setTab] = useState<MatrixTab>(() => {
    if (initialTab) return initialTab;
    if (typeof window === "undefined") return "structure";
    const saved = window.sessionStorage.getItem(tabStorageKey);
    if(saved==="staffing")return "structure";
    return (["workforce", "structure", "strategies", "finance"] as MatrixTab[]).includes(saved as MatrixTab)
      ? saved as MatrixTab
      : "structure";
  });
  const [busy, setBusy] = useState(false);
  const [edit, setEdit] = useState<EditTarget | null>(null);
  const [employeeEdit, setEmployeeEdit] = useState<MatrixV2Employee | "new" | null>(() =>
    createEmployeeRequest ? "new" : null
  );
  const [workforceFocusEmployeeId,setWorkforceFocusEmployeeId]=useState<string|null>(focusEmployeeId??null);
  const [financeOnboardingEmployeeId,setFinanceOnboardingEmployeeId]=useState<string|null>(null);
  const [publicationReadiness,setPublicationReadiness]=useState<MatrixV2PublicationReadiness|null>(null);
  const [importOpen,setImportOpen]=useState(false);
  const [historyOpen,setHistoryOpen]=useState(false);
  const [uatReset,setUatReset]=useState<UatResetPreview|null>(null);
  const settings = matrixV2Settings(data.matrixVersion);
  const mixedCurrencyItems = data.financeVisible ? [
    ...(data.payRules ?? []),
    ...(data.scenarioBudgets ?? []),
    ...(data.employeePayRates ?? []),
  ].filter(item => String(item.currency ?? "").toUpperCase() !== settings.currency) : [];

  function selectTab(next: MatrixTab) {
    setTab(next);
    window.sessionStorage.setItem(tabStorageKey, next);
  }

  useEffect(()=>{
    if(!createEmployeeRequest||!data.editable)return;
    selectTab("workforce");
    setEmployeeEdit("new");
    onCreateEmployeeOpened?.();
  },[createEmployeeRequest,data.editable,onCreateEmployeeOpened]);

  async function reloadInPlace() {
    const scrollTop = window.scrollY;
    await reload();
    window.requestAnimationFrame(() => window.requestAnimationFrame(() => window.scrollTo(0, scrollTop)));
  }

  async function refreshPublicationReadiness() {
    if(!supabase||!publicationReadiness)return;
    const result=await supabase.rpc("matrix_v2_publication_readiness_uat_v2",{
      p_effective_from:publicationReadiness.effectiveFrom,
      p_schedule_month:publicationReadiness.scheduleMonth??`${month}-01`,
    });
    if(!result.error&&result.data)setPublicationReadiness(result.data as MatrixV2PublicationReadiness);
  }

  function openPublicationBlocker(blocker:MatrixV2PublicationBlocker){
    const action=configurationBlockerAction(blocker,data,month);
    selectTab(action.section==="workforce"?"workforce":"structure");
    if(action.focus?.employeeId)setWorkforceFocusEmployeeId(action.focus.employeeId);
    const align=()=>{
      const target=document.getElementById(action.focus?.targetId??`configuration-step-${action.step}`);
      target?.scrollIntoView({behavior:"smooth",block:"center"});
      if(blocker.code==="MISSING_PAY_RATE")target?.querySelector<HTMLInputElement>('input[name="amount"]')?.focus({preventScroll:true});
    };
    window.setTimeout(align,80);window.setTimeout(align,450);window.setTimeout(align,900);
  }

  useEffect(() => {
    if (!data.financeVisible && tab === "finance") selectTab("structure");
  }, [data.financeVisible, tab]);
  useEffect(()=>{if(focusEmployeeId)selectTab("workforce");},[focusEmployeeId]);
  useEffect(()=>{if(initialTab)selectTab(initialTab);},[initialTab]);
  useEffect(()=>{
    let alive=true;
    if(!supabase||!data.editable){setUatReset(null);return()=>{alive=false;};}
    void supabase.rpc("uat_matrix_workforce_reset_preview_v2").then(result=>{
      if(alive&&!result.error&&result.data)setUatReset(result.data as UatResetPreview);
    });
    return()=>{alive=false;};
  },[data.editable,data.matrixVersion.id,supabase]);

  async function resetUatDraftWorkforce(){
    if(!supabase||!uatReset?.enabled)return;
    const confirmation=window.prompt(`Ta operacja usunie ${uatReset.employees} profili wyłącznie z roboczego Matrixa v${uatReset.draftVersion}. Aktywny Matrix, grafiki, stawki i historia pozostaną zachowane.\n\nAby kontynuować, wpisz dokładnie: ${uatReset.confirmation}`);
    if(confirmation!==uatReset.confirmation){if(confirmation!==null)fail("Reset anulowany: tekst potwierdzenia nie jest zgodny.");return;}
    if(!window.confirm("Ostatnie potwierdzenie: wyczyścić pracowników, role, lokale i kompetencje z wersji roboczej UAT?"))return;
    setBusy(true);
    const result=await supabase.rpc("uat_matrix_workforce_reset_v2",{p_confirmation:confirmation});
    setBusy(false);
    if(result.error){fail(matrixV2ErrorMessage(result.error.message));return;}
    setWorkforceFocusEmployeeId(null);
    selectTab("workforce");
    notify("Robocza baza pracowników UAT została wyczyszczona. Aktywne dane i historia pozostały bez zmian.");
    await reloadInPlace();
  }

  async function createDraft() {
    if (!supabase) return;
    const name = window.prompt("Nazwa nowej wersji roboczej:", `Matrix v${data.matrixVersion.version + 1}`);
    if (!name?.trim()) return;
    setBusy(true);
    const result = await supabase.rpc("matrix_v2_create_draft", { p_name: name.trim() });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return; }
    notify("Utworzono bezpieczną wersję roboczą Matrixa.");
    await reloadInPlace();
  }

  async function normalizeShiftPeriods() {
    if (!supabase) return;
    const mismatches=data.shiftTemplates.filter(shift=>{
      const expected=expectedShiftPeriodFromStart(shift.starts_at);
      return shift.active&&expected!==null&&shift.shift_period!==expected;
    });
    if(!mismatches.length){notify("Klasyfikacja pór zmian jest już spójna.");return;}
    if(!window.confirm(`Poprawić automatyczną klasyfikację ${mismatches.length} zmian według godziny rozpoczęcia? Zmiany trafią do wersji roboczej; opublikowany Matrix i istniejące grafiki pozostaną bez zmian.`))return;
    setBusy(true);
    const result=await supabase.rpc("matrix_v2_normalize_shift_periods_uat_v2");
    setBusy(false);
    if(result.error){fail(matrixV2ErrorMessage(result.error.message));return;}
    const updated=Number((result.data as {updated?:number}|null)?.updated??0);
    notify(`Poprawiono klasyfikację ${updated} zmian w wersji roboczej.`);
    selectTab("structure");
    await reloadInPlace();
  }

  async function mergeEquivalentShifts(){
    if(!supabase)return;
    setBusy(true);
    const preview=await supabase.rpc("matrix_v2_merge_equivalent_shifts_uat_v2",{p_apply:false});
    setBusy(false);
    if(preview.error){fail(matrixV2ErrorMessage(preview.error.message));return;}
    const payload=preview.data as {groups?:number;duplicates?:number;blockers?:{message:string}[]};
    if(!payload.groups){notify("Nie znaleziono równoważnych wpisów zmian do scalenia.");return;}
    if(payload.blockers?.length){fail(`Scalanie jest zablokowane: ${payload.blockers.map(item=>item.message).join(" • ")}`);return;}
    if(!window.confirm(`Połączyć ${payload.duplicates??0} powielonych wpisów w ${payload.groups} czytelnych kart zmian?\n\nSystem nie zmieni godzin ani wymaganej obsady. Połączy listy dni tygodnia, przepnie reguły obsady i wyłączy duplikaty wyłącznie w wersji roboczej. Historia pozostanie zachowana.`))return;
    setBusy(true);
    const result=await supabase.rpc("matrix_v2_merge_equivalent_shifts_uat_v2",{p_apply:true});
    setBusy(false);
    if(result.error){fail(matrixV2ErrorMessage(result.error.message));return;}
    notify(`Scalono ${Number((result.data as {groups?:number}|null)?.groups??0)} logicznych zmian. Dni są teraz zapisane wspólnie.`);
    await reloadInPlace();
  }

  async function publishDraft() {
    if (!supabase) return;
    const todayInMatrixTimezone=new Intl.DateTimeFormat("en-CA",{
      timeZone:"Europe/Warsaw",year:"numeric",month:"2-digit",day:"2-digit",
    }).format(new Date());
    const effective = window.prompt(
      `Od kiedy ta wersja ma obowiązywać?\n\nGrafik nadal zostanie policzony dla ${month}; ta data określa tylko moment aktywacji konfiguracji Matrixa.`,
      todayInMatrixTimezone,
    );
    if (!effective) return;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(effective)) { fail("Podaj datę w formacie RRRR-MM-DD."); return; }
    setBusy(true);
    const readiness=await supabase.rpc("matrix_v2_publication_readiness_uat_v2",{
      p_effective_from:effective,
      p_schedule_month:`${month}-01`,
    });
    if(readiness.error){setBusy(false);fail(matrixV2ErrorMessage(readiness.error.message));return;}
    const preflight=readiness.data as MatrixV2PublicationReadiness;
    setPublicationReadiness(preflight);
    if(!preflight.ready){setBusy(false);fail(`Nie można opublikować Matrixa: ${preflight.blockers.length} blokad. Szczegóły są widoczne nad zakładkami.`);return;}
    if (!window.confirm("Kontrola gotowości nie wykryła blokad. Opublikować tę wersję Matrixa? Poprzednia wersja pozostanie w historii, a nowe grafiki użyją nowej konfiguracji.")){setBusy(false);return;}
    const result = await supabase.rpc("matrix_v2_publish_draft", { p_effective_from: effective });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return; }
    notify("Nowa wersja Matrixa została opublikowana.");
    await reloadInPlace();
  }

  async function save(kind: MatrixV2SaveKind, id: string | null, payload: Record<string, unknown>) {
    if (!supabase) return false;
    if(kind==="DUTY"&&id&&payload.active===false){
      const preview=await supabase.rpc("matrix_v2_duty_archive_preview_uat_v2",{p_duty_id:id});
      if(preview.error){fail(matrixV2ErrorMessage(preview.error.message));return false;}
      const impact=preview.data as {roleDuties?:number;employeeDuties?:number;staffingRules?:number;payRules?:number};
      const total=Number(impact.roleDuties??0)+Number(impact.employeeDuties??0)+Number(impact.staffingRules??0)+Number(impact.payRules??0);
      const reason=window.prompt(`Archiwizacja obejmie obowiązek i wszystkie jego aktywne zależności:\n• role: ${impact.roleDuties??0}\n• pracownicy: ${impact.employeeDuties??0}\n• reguły obsady: ${impact.staffingRules??0}\n• dodatki płacowe: ${impact.payRules??0}\n\nHistoria pozostanie w audycie. Podaj powód archiwizacji${total?` (${total} zależności)`:""}:`);
      if(reason===null)return false;
      if(reason.trim().length<5){fail("Powód archiwizacji musi mieć co najmniej 5 znaków.");return false;}
      setBusy(true);
      const archived=await supabase.rpc("matrix_v2_duty_archive_uat_v2",{p_duty_id:id,p_reason:reason.trim()});
      setBusy(false);
      if(archived.error){fail(matrixV2ErrorMessage(archived.error.message));return false;}
      notify("Obowiązek i jego zależności zostały bezpiecznie zarchiwizowane.");
      await reloadInPlace();
      return true;
    }
    setBusy(true);
    const shiftTemplateIds=Array.isArray(payload.shiftTemplateIds)
      ?payload.shiftTemplateIds.filter((value):value is string=>typeof value==="string"&&Boolean(value))
      :[];
    const unifiedStaffing=kind==="STAFFING_RULE";
    const staffingShiftIds=id
      ?[String(payload.shiftTemplateId)]
      :shiftTemplateIds;
    const result = unifiedStaffing
      ?await supabase.rpc("matrix_v2_shift_staffing_save_uat_v3",{
        p_scenario_id:String(payload.scenarioId),
        p_shift_template_ids:staffingShiftIds,
        p_role_id:String(payload.roleId),
        p_duty_id:payload.dutyId?String(payload.dutyId):null,
        p_operation:String(payload.operation),
        p_count_value:payload.countValue as number|null,
        p_multiplier_basis_points:payload.multiplierBasisPoints as number|null,
        p_active:Boolean(payload.active),
      })
      :await supabase.rpc("matrix_v2_admin_save_alpha16", {
        p_kind: kind, p_id: id, p_data: payload,
      });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    notify(unifiedStaffing
      ?`Zapisano wymaganą obsadę dla ${staffingShiftIds.length} ${staffingShiftIds.length===1?"zmiany":"zmian"}.`
      :"Zmiana została zapisana w wersji roboczej.");
    await reloadInPlace();
    return true;
  }

  async function saveSettings(form: HTMLFormElement) {
    try {
      const currency = formText(form, "currency").toUpperCase();
      const timezone = formText(form, "timezone");
      if (!/^[A-Z]{3}$/.test(currency)) throw new Error("Waluta musi mieć trzyliterowy kod, np. PLN, EUR lub USD.");
      if (!timezone) throw new Error("Podaj strefę czasową Matrixa.");
      const minimumRestMinutes = requiredNumber(formText(form, "minimumRestMinutes"));
      // Compatibility field for the published Matrix v2 schema.  Employee
      // assignment capacity is an invariant of one and is not configurable;
      // the editor itself does not cap the number of shift templates.
      const maximumShiftsPerDay = 1;
      if (minimumRestMinutes < 0) throw new Error("Minimalny odpoczynek nie może być ujemny.");
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
    await reloadInPlace();
    return true;
  }

  async function revokeTimeConstraint(id: string) {
    if (!supabase || !window.confirm("Usunąć ten przedział? Poprzednia wersja pozostanie w historii.")) return false;
    setBusy(true);
    const result = await supabase.rpc("employee_time_constraint_revoke_v2", { p_id: id });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    notify("Przedział został wycofany.");
    await reloadInPlace();
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
    const employee=data.employees.find(item=>item.id===input.employeeId);
    if(employee?.employmentStart&&input.validFrom<employee.employmentStart){
      fail(`Stawka nie może obowiązywać przed rozpoczęciem zatrudnienia (${employee.employmentStart}).`);return false;
    }
    if(employee?.employmentEnd&&(
      input.validFrom>employee.employmentEnd||!input.validTo||input.validTo>employee.employmentEnd
    )){
      fail(`Cały okres stawki musi mieścić się przed zakończeniem zatrudnienia (${employee.employmentEnd}).`);return false;
    }
    const requestedEnd=input.validTo||"9999-12-31";
    const overlap=(data.employeePayRates??[]).find(rate=>rate.employee_id===input.employeeId
      &&rate.active&&input.active&&rate.id!==input.id
      &&rate.valid_from<=requestedEnd&&input.validFrom<=(rate.valid_to||"9999-12-31"));
    if(overlap){
      fail(`Nowy okres nakłada się na stawkę obowiązującą od ${overlap.valid_from}${overlap.valid_to?` do ${overlap.valid_to}`:" bez daty końcowej"}. Edytuj ten wpis albo najpierw zakończ jego okres.`);return false;
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
    if(financeOnboardingEmployeeId===input.employeeId)setFinanceOnboardingEmployeeId(null);
    notify("Stawka została zapisana w chronionej historii finansowej.");
    await reloadInPlace();
    await refreshPublicationReadiness();
    return true;
  }

  async function skipFinanceOnboarding(employeeId:string){
    if(!supabase)return;
    setBusy(true);
    const result=await supabase.rpc("matrix_v2_finance_step_skip_uat_v2",{p_employee_id:employeeId});
    setBusy(false);
    if(result.error){fail(matrixV2ErrorMessage(result.error.message));return;}
    setFinanceOnboardingEmployeeId(null);
    notify("Pominięto stawkę świadomie. Pracownik jest zapisany, a brak stawki pozostaje widoczny jako blokada publikacji.");
  }

  async function saveEmployeeProfile(employeeId: string | null, payload: Record<string, unknown>) {
    if (!supabase) return false;
    setBusy(true);
    const result = await supabase.rpc("matrix_v2_employee_save_uat_v3", {
      p_employee_id: employeeId, p_data: payload,
    });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    const saved=result.data as {id?:string;employeeNo?:string}|null;
    setEmployeeEdit(null);
    if(!employeeId&&saved?.id){
      selectTab("workforce");
      setWorkforceFocusEmployeeId(saved.id);
      setFinanceOnboardingEmployeeId(saved.id);
    }
    notify(employeeId ? "Dane pracownika zapisano w wersji roboczej." : `Pracownik został dodany z numerem ${String(saved?.employeeNo??"")}. Uzupełnij teraz jego stawkę albo świadomie pomiń ten krok.`);
    await reloadInPlace();
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
    await reloadInPlace();
    return true;
  }

  async function bulkAdjustStaffing(input: {
    scenarioId: string;
    locationId: string | null;
    shiftPeriod: string | null;
    roleId: string | null;
    delta: number;
    visibleCount: number;
  }) {
    if (!supabase || !input.scenarioId || input.visibleCount < 1) return false;
    const direction = input.delta > 0 ? "zwiększyć" : "zmniejszyć";
    if (!window.confirm(
      `Czy ${direction} wymaganą obsadę o ${Math.abs(input.delta)} dla ${input.visibleCount} widocznych aktywnych reguł?\n\nZmiana zostanie zapisana zbiorczo i atomowo w wersji roboczej Matrixa.`,
    )) return false;
    setBusy(true);
    const result = await supabase.rpc("matrix_v2_staffing_bulk_adjust_uat_v2", {
      p_scenario_id: input.scenarioId,
      p_location_id: input.locationId,
      p_shift_period: input.shiftPeriod,
      p_role_id: input.roleId,
      p_delta: input.delta,
    });
    setBusy(false);
    if (result.error) { fail(matrixV2ErrorMessage(result.error.message)); return false; }
    const updated = Number((result.data as {updated?: number} | null)?.updated ?? 0);
    const skipped = Number((result.data as {skipped?: number} | null)?.skipped ?? 0);
    notify(`Zbiorczo zmieniono ${updated} reguł obsady${skipped ? `; pominięto ${skipped} reguł mnożnikowych lub usuwających` : ""}.`);
    await reloadInPlace();
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
        <button className="secondary-button" disabled={busy} onClick={()=>setHistoryOpen(true)}><HistoryIcon/> Historia wersji</button>
        {data.editable
          ? <>{uatReset?.enabled&&<button className="secondary-button danger" disabled={busy} onClick={()=>void resetUatDraftWorkforce()}><Trash2/> Reset danych UAT</button>}<button className="secondary-button" disabled={busy} onClick={()=>setImportOpen(true)}><FileSpreadsheet/> Import Excel</button><button className="primary-button" disabled={busy} onClick={() => void publishDraft()}><Check/> Opublikuj Matrix</button></>
          : <button className="primary-button" disabled={busy} onClick={() => void createDraft()}><Plus/> Nowa wersja robocza</button>}
      </div>
    </header>

    {mixedCurrencyItems.length > 0 && <div className="matrix-v2-validation warning"><AlertTriangle/><span><strong>Dane finansowe mają różne waluty</strong><small>Stawki, dodatki i budżety muszą używać waluty {settings.currency}. Popraw je przed publikacją Matrixa.</small></span></div>}

    {publicationReadiness&&!publicationReadiness.ready&&<section className="matrix-v2-readiness"><div><AlertTriangle/><span><strong>Publikacja Matrixa jest zablokowana</strong><small>{publicationReadiness.blockers.length} problemów wymaga poprawy. Każdy przycisk prowadzi bezpośrednio do konkretnego pola.</small></span></div>{publicationReadiness.blockers.map(blocker=>{const action=configurationBlockerAction(blocker,data,month);return <button key={`${blocker.code}:${blocker.employeeId??blocker.shiftTemplateId??blocker.employeeNo??blocker.shiftCode}`} onClick={()=>openPublicationBlocker(blocker)}><span><b>{action.title}</b><small>{[blocker.employeeNo,blocker.shiftCode,action.message].filter(Boolean).join(" • ")}</small><em>{action.actionLabel}</em></span><ChevronRight/></button>;})}</section>}

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
      <button className={tab === "structure" ? "active" : ""} onClick={() => selectTab("structure")}><Layers3/> 1. Zmiany i obsada</button>
      <button className={tab === "workforce" ? "active" : ""} onClick={() => selectTab("workforce")}><Users/> 2. Pracownicy, umowy i stawki</button>
      <button className={tab === "strategies" ? "active" : ""} onClick={() => selectTab("strategies")}><Target/> 3. Warianty biznesowe</button>
      {data.financeVisible && <button className={tab === "finance" ? "active" : ""} onClick={() => selectTab("finance")}><CircleDollarSign/> 4. Finanse</button>}
    </nav>

    {!data.editable && <div className="matrix-v2-readonly"><ShieldCheck/><span><strong>Oglądasz opublikowaną konfigurację</strong><small>Utwórz wersję roboczą, aby bezpiecznie wprowadzić zmiany bez wpływu na istniejące grafiki.</small></span></div>}

    {tab === "structure" && <StructureTab data={data} editable={data.editable} busy={busy} settings={settings} edit={setEdit} saveSettings={saveSettings} normalizeShiftPeriods={normalizeShiftPeriods} mergeEquivalentShifts={mergeEquivalentShifts} bulkAdjust={bulkAdjustStaffing} defaultScenarioCount={defaultScenarioCount}/>}
    {tab === "workforce" && <WorkforceTab data={data} month={month} editable={data.editable} busy={busy} edit={setEdit} editProfile={setEmployeeEdit} setArchived={setEmployeeArchived} saveTime={saveTimeConstraint} revokeTime={revokeTimeConstraint} saveRate={savePayRate} focusEmployeeId={workforceFocusEmployeeId} financeOnboardingEmployeeId={financeOnboardingEmployeeId} dismissFinanceOnboarding={skipFinanceOnboarding}/>}
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
    {historyOpen&&<MatrixHistoryDrawer currentVersionId={data.matrixVersion.id} close={()=>setHistoryOpen(false)} fail={fail}/>}
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
      <span><strong>Podstawowe ustawienia firmy</strong><small>Waluta i strefa czasowa. Limity czasu pracy ustawiasz przy pracowniku zgodnie z jego umową.</small></span>
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
      <details className="matrix-v2-advanced-settings"><summary>Zaawansowane ustawienia silnika</summary>
        <p className="matrix-v2-form-hint">Te wartości są technicznym zabezpieczeniem. Umowa i indywidualne ustalenia pracownika mają pierwszeństwo.</p>
        <label>Domyślny odpoczynek dla umów pracowniczych (minuty)<input name="minimumRestMinutes" type="number" min="0" step="15" required disabled={!editable} defaultValue={settings.minimumRestMinutes}/></label>
        <p className="matrix-v2-form-hint">Możesz utworzyć dowolną liczbę szablonów zmian. Niezależnie od ich liczby jedna osoba może otrzymać najwyżej jedną zasadniczą zmianę dziennie.</p>
        <label className="check-label"><input name="missingAvailabilityMeansAvailable" type="checkbox" disabled={!editable} defaultChecked={settings.missingAvailabilityMeansAvailable}/> Dla umów pracowniczych brak deklaracji oznacza dostępność</label>
        <label className="check-label"><input name="requireOptimal" type="checkbox" disabled={!editable} defaultChecked={settings.requireOptimal}/> Czekaj na matematycznie najlepszy wynik</label>
      </details>
      {editable && <button className="primary-button" disabled={busy}><Save/> {busy ? "Zapisuję…" : "Zapisz ustawienia"}</button>}
    </form>
  </section>;
}

function StructureTab({data, editable, busy, settings, edit, saveSettings, normalizeShiftPeriods,mergeEquivalentShifts,bulkAdjust,defaultScenarioCount}: {data: MatrixV2Workspace; editable: boolean; busy:boolean; settings:MatrixV2Settings; edit: (value: EditTarget) => void; saveSettings:(form:HTMLFormElement)=>Promise<void>; normalizeShiftPeriods:()=>Promise<void>;mergeEquivalentShifts:()=>Promise<void>;bulkAdjust:(input:{scenarioId:string;locationId:string|null;shiftPeriod:string|null;roleId:string|null;delta:number;visibleCount:number})=>Promise<boolean>;defaultScenarioCount:number}) {
  const [locationId,setLocationId]=useState("");
  const [query,setQuery]=useState("");
  const normalizedQuery=query.trim().toLocaleLowerCase("pl-PL");
  const periodMismatches=data.shiftTemplates.filter(shift=>{
    const expected=expectedShiftPeriodFromStart(shift.starts_at);
    return shift.active&&expected!==null&&shift.shift_period!==expected;
  });
  const shifts=data.shiftTemplates.filter(shift=>(!locationId||shift.location_id===locationId)
    &&(!normalizedQuery||`${shift.name} ${time(shift.starts_at)} ${time(shift.ends_at)}`.toLocaleLowerCase("pl-PL").includes(normalizedQuery)));
  const visibleLocations=data.locations.filter(location=>!locationId||location.id===locationId);
  const baseScenario=data.scenarios.find(scenario=>scenario.active&&scenario.is_default)
    ??data.scenarios.find(scenario=>scenario.active);
  const equivalentGroups=[...data.shiftTemplates.filter(shift=>shift.active).reduce((groups,shift)=>{const key=equivalentShiftKey({locationId:shift.location_id,name:shift.name,startsAt:shift.starts_at,endsAt:shift.ends_at,endsNextDay:shift.ends_next_day});groups.set(key,[...(groups.get(key)??[]),shift]);return groups;},new Map<string,MatrixV2Shift[]>()).values()].filter(group=>group.length>1);
  return <div className="matrix-v2-tab-content">
    {periodMismatches.length>0&&<details className="matrix-v2-technical-repair"><summary><AlertTriangle/> System wykrył {periodMismatches.length} niespójnych danych zmian</summary><p>To pole techniczne jest wyliczane automatycznie z godziny rozpoczęcia i nie wymaga decyzji biznesowej.</p><button className="secondary-button" disabled={busy} onClick={()=>void normalizeShiftPeriods()}>{editable?"Napraw dane zmian":"Utwórz wersję roboczą i napraw"}</button></details>}
    {equivalentGroups.length>0&&<div className="matrix-v2-validation warning"><AlertTriangle/><span><strong>Wykryto {equivalentGroups.length} grup powtarzających się zmian</strong><small>To nie jest błąd i nie blokuje grafiku. Jeśli wpisy oznaczają tę samą zmianę, system może połączyć ich dni w jedną kartę bez zmiany godzin ani obsady.</small></span>{editable&&<button className="secondary-button" disabled={busy} onClick={()=>void mergeEquivalentShifts()}>Połącz powtarzające się zmiany</button>}</div>}
    <div className="matrix-v2-structure-overview">
      <RoleDutyOverview data={data} editable={editable} edit={edit}/>
      <EntityPanel title="Lokale" description="Miejsca, w których powstaje grafik" items={data.locations} editable={editable} add={() => edit({kind: "LOCATION"})} edit={item => edit({kind: "LOCATION", item})}/>
    </div>
    <section id="configuration-step-shifts" className="matrix-v2-card guided-shift-workflow">
      <SectionHead title="Zmiany i obsada" description="Zacznij od konkretnej zmiany. Następnie przypisz rolę, opcjonalny obowiązek lub kompetencję i wymaganą liczbę osób." editable={editable} disabled={!data.locations.length} add={() => edit({kind: "SHIFT"})}/>
      <div className="matrix-v2-filterbar">
        <label>Lokal<select value={locationId} onChange={event=>setLocationId(event.target.value)}><option value="">Wszystkie lokale</option>{data.locations.map(location=><option key={location.id} value={location.id}>{location.name}</option>)}</select></label>
        <label>Szukaj<input value={query} onChange={event=>setQuery(event.target.value)} placeholder="Nazwa lub godziny zmiany"/></label>
        <strong>{shifts.length} z {data.shiftTemplates.length} zmian</strong>
      </div>
      <div className="guided-shift-grid">
        {visibleLocations.map(location=>{
          const localShifts=shifts.filter(shift=>shift.location_id===location.id);
          return <section key={location.id} className="guided-location-group">
            <header className="guided-location-head"><span><MapPin/><div><h4>{location.name}</h4><small>{localShifts.length} widocznych • {data.shiftTemplates.filter(shift=>shift.location_id===location.id).length} wszystkich zmian</small></div></span>{editable&&<button className="secondary-button" onClick={()=>edit({kind:"SHIFT",item:{location_id:location.id} as Record<string,unknown>})}><Plus/> Dodaj zmianę</button>}</header>
            {localShifts.map(shift=>{
              const shiftRules=data.staffingRules.filter(rule=>rule.active&&rule.shift_template_id===shift.id&&rule.scenario_id===baseScenario?.id);
              return <article className="guided-shift-card" key={shift.id}>
                <header>
                  <button type="button" onClick={()=>editable&&edit({kind:"SHIFT",item:shift})}><i style={{background:shift.color??"#7257d8"}}/><span><b>{shift.name}</b><small>{time(shift.starts_at)}–{time(shift.ends_at)}{shift.ends_next_day?" • następny dzień":""}</small></span>{editable&&<Edit3/>}</button>
                  <span className="guided-shift-card-days"><b>{WEEKDAYS.filter(day=>shift.day_mask.includes(day.value)).map(day=>day.label).join(", ")}</b><small>{shiftRules.length?plural(shiftRules.length,"wymagana rola","wymagane role","wymaganych ról"):"Brak ustawionej obsady"}</small></span>
                  <div className="guided-shift-card-actions">{editable&&<button className="primary-button" onClick={()=>edit({kind:"STAFFING_RULE",item:{scenario_id:baseScenario?.id,shift_template_id:shift.id,location_id:location.id} as Record<string,unknown>})}><Plus/> Dodaj rolę i liczbę osób</button>}</div>
                </header>
                <div className="guided-staffing-list">
                  {shiftRules.map(rule=><button type="button" className={`guided-staffing-row ${editable?"editable":""}`} key={rule.id} onClick={()=>editable&&edit({kind:"STAFFING_RULE",item:rule})}>
                    <span><b>{itemName(data.roles,rule.role_id)}</b><small>{rule.duty_id?`Kompetencja: ${itemName(data.duties,rule.duty_id)}`:"Bez dodatkowego wymogu kompetencji"}</small></span>
                    <strong>{staffingValue(rule)}</strong><em>{baseScenario?.name??"Scenariusz bazowy"}</em>{editable&&<Edit3/>}
                  </button>)}
                  {!shiftRules.length&&<div className="guided-empty-staffing"><span><strong>Ta zmiana nie ma jeszcze wymaganej obsady</strong><small>Dodaj rolę, opcjonalną kompetencję i liczbę osób bez opuszczania karty.</small></span>{editable&&<button className="secondary-button" onClick={()=>edit({kind:"STAFFING_RULE",item:{scenario_id:baseScenario?.id,shift_template_id:shift.id,location_id:location.id} as Record<string,unknown>})}>Uzupełnij obsadę <ChevronRight/></button>}</div>}
                </div>
              </article>;
            })}
            {!localShifts.length&&<p className="matrix-v2-empty">Brak zmian pasujących do filtrów w tym lokalu.</p>}
          </section>;
        })}
        {!shifts.length&&!visibleLocations.length&&<p className="matrix-v2-empty">Brak zmian pasujących do filtrów.</p>}
      </div>
    </section>
    {data.scenarios.filter(scenario=>scenario.active).length>1&&<details className="matrix-v2-company-settings"><summary><Target/> Zaawansowane scenariusze obsady</summary><p>Scenariusz bazowy edytujesz bezpośrednio na kartach zmian. Tutaj ustawiasz wyłącznie różnice wariantów alternatywnych.</p><StaffingTab embedded data={data} editable={editable} busy={busy} edit={edit} bulkAdjust={bulkAdjust} defaultScenarioCount={defaultScenarioCount}/></details>}
    <details id="configuration-step-company" className="matrix-v2-company-settings"><summary><Settings/> Ustawienia firmy i zaawansowane zabezpieczenia silnika</summary><MatrixSettingsCard settings={settings} editable={editable} busy={busy} save={saveSettings}/></details>
  </div>;
}

function expectedShiftPeriodFromStart(value:string):"MORNING"|"MIDDLE"|"EVENING"|null{const match=/^(\d{2}):/.exec(value);if(!match)return null;const hour=Number(match[1]);return hour<12?"MORNING":hour<17?"MIDDLE":"EVENING";}

function RoleDutyOverview({data,editable,edit}:{data:MatrixV2Workspace;editable:boolean;edit:(value:EditTarget)=>void}){
  return <section id="configuration-step-roles" className="matrix-v2-card matrix-v2-role-duty-overview"><SectionHead title="Role i opcjonalne obowiązki" description="Najpierw zdefiniuj role. Obowiązek przypisz tylko wtedy, gdy dana rola ma dodatkową kompetencję potrzebną w obsadzie." editable={editable} add={()=>edit({kind:"ROLE"})}/><div className="matrix-v2-role-duty-grid">{data.roles.map(role=>{
    const links=data.roleDuties.filter(link=>link.role_id===role.id);
    const activeLinks=links.filter(link=>link.active);
    return <article key={role.id}><header><span><i style={{background:role.color??"#7257d8"}}/><div><h4>{role.name}</h4><small>{activeLinks.length?`${activeLinks.length} ${activeLinks.length===1?"opcjonalny obowiązek":"opcjonalne obowiązki"}`:"Bez dodatkowych obowiązków — poprawna konfiguracja"}</small></div></span>{editable&&<button className="icon-button" title="Edytuj rolę" onClick={()=>edit({kind:"ROLE",item:role})}><Edit3/></button>}</header><div className="matrix-v2-role-duty-chips">{links.map(link=><button key={link.id} disabled={!editable} onClick={()=>editable&&edit({kind:"ROLE_DUTY",item:link})}><b>{itemName(data.duties,link.duty_id)}</b><small>{assignmentModeLabel[link.assignment_mode]}</small></button>)}{!links.length&&<small>Ta rola nie wymaga dodatkowego obowiązku.</small>}</div>{editable&&<button className="matrix-v2-add-inline" onClick={()=>edit({kind:"ROLE_DUTY",item:{role_id:role.id} as Record<string,unknown>})}><Plus/> Dodaj opcjonalny obowiązek</button>}</article>;
  })}</div><div className="matrix-v2-duty-dictionary"><span><strong>Słownik obowiązków</strong><small>Edytuj nazwę lub dodaj kompetencję, a potem przypisz ją do właściwych ról.</small></span><div>{data.duties.map(duty=><button key={duty.id} disabled={!editable} onClick={()=>editable&&edit({kind:"DUTY",item:duty})}>{duty.name}</button>)}{editable&&<button onClick={()=>edit({kind:"DUTY"})}><Plus/> Nowy obowiązek</button>}</div></div></section>;
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
  data,month,editable,busy,edit,editProfile,setArchived,saveTime,revokeTime,saveRate,focusEmployeeId,financeOnboardingEmployeeId,dismissFinanceOnboarding,
}: {
  data: MatrixV2Workspace; month: string; editable: boolean; busy: boolean;
  edit: (value: EditTarget) => void;
  editProfile: (value: MatrixV2Employee | "new") => void;
  setArchived: (employee: MatrixV2Employee, archive: boolean) => Promise<boolean>;
  saveTime: (input: {id:string|null;employeeId:string;kind:string;startsAt:string;endsAt:string;note:string}) => Promise<boolean>;
  revokeTime: (id:string) => Promise<boolean>;
  saveRate: (input: {id:string|null;employeeId:string;validFrom:string;validTo:string;amount:string;contractType:string;active:boolean}) => Promise<boolean>;
  focusEmployeeId?:string|null;
  financeOnboardingEmployeeId?:string|null;
  dismissFinanceOnboarding:(employeeId:string)=>Promise<void>;
}) {
  const employees = data.employees ?? [];
  const settings = matrixV2Settings(data.matrixVersion),currency=settings.currency,timezone=settings.timezone;
  const [employeeId,setEmployeeId] = useState(focusEmployeeId&&employees.some(employee=>employee.id===focusEmployeeId)?focusEmployeeId:employees.find(employee=>employee.active)?.id ?? employees[0]?.id ?? "");
  const [employeeQuery,setEmployeeQuery]=useState("");
  const [timeEdit,setTimeEdit] = useState<MatrixV2TimeConstraint | null>(null);
  const [rateEdit,setRateEdit] = useState<MatrixV2PayRate | null>(null);
  const employee = employees.find(item=>item.id===employeeId) ?? employees[0];
  const flexibleContractor=Boolean(employee&&["ZLECENIE","B2B"].includes(employee.contractType??"")&&employee.workTimePolicy!=="CUSTOM");
  const employeeRoles = (data.employeeRoles ?? []).filter(item=>item.employee_id===employee?.id);
  const employeeLocations = (data.employeeLocations ?? []).filter(item=>item.employee_id===employee?.id);
  const employeeDuties = (data.employeeDuties ?? []).filter(item=>item.employee_id===employee?.id);
  const constraints = (data.timeConstraints ?? []).filter(item=>item.employeeId===employee?.id)
    .sort((a,b)=>a.startsAt.localeCompare(b.startsAt));
  const rates = (data.employeePayRates ?? []).filter(item=>item.employee_id===employee?.id)
    .sort((a,b)=>b.valid_from.localeCompare(a.valid_from));
  const employeeMatches=employeeQuery.trim()?employees.filter(item=>employeeMatchesWorkforceQuery(data,item,employeeQuery)).slice(0,12):[];
  const profileReadiness=employee?workforceProfileReadiness(data,employee,month):null;

  useEffect(()=>{
    if (!employeeId && employees[0]) setEmployeeId(employees[0].id);
  },[employeeId,employees]);
  useEffect(()=>{
    if(!focusEmployeeId||!employees.some(item=>item.id===focusEmployeeId))return;
    setEmployeeId(focusEmployeeId);
    window.requestAnimationFrame(()=>window.requestAnimationFrame(()=>{
      document.getElementById(`matrix-v2-rate-${focusEmployeeId}`)?.scrollIntoView({behavior:"smooth",block:"center"});
    }));
  },[focusEmployeeId,employees]);

  function beginRateEdit(item:MatrixV2PayRate){
    setRateEdit(item);
    window.requestAnimationFrame(()=>window.requestAnimationFrame(()=>{
      document.getElementById(`matrix-v2-rate-form-${item.employee_id}`)?.scrollIntoView({behavior:"smooth",block:"center"});
      document.querySelector<HTMLInputElement>(`#matrix-v2-rate-form-${item.employee_id} input[name="amount"]`)?.focus();
    }));
  }

  function openRateForm(){
    if(!employee)return;
    window.requestAnimationFrame(()=>window.requestAnimationFrame(()=>{
      document.getElementById(`matrix-v2-rate-form-${employee.id}`)?.scrollIntoView({behavior:"smooth",block:"center"});
      document.querySelector<HTMLInputElement>(`#matrix-v2-rate-form-${employee.id} input[name="amount"]`)?.focus();
    }));
  }

  function repairProfileCheck(key:WorkforceProfileCheckKey){
    if(!employee)return;
    if(key==="profile")editProfile(employee);
    if(key==="role")edit({kind:"EMPLOYEE_ROLE",item:{employee_id:employee.id}});
    if(key==="location")edit({kind:"EMPLOYEE_LOCATION",item:{employee_id:employee.id}});
    if(key==="rate")openRateForm();
  }

  if (!employee) return <div className="matrix-v2-tab-content"><section className="matrix-v2-card"><SectionHead title="Pracownicy" description="Dodaj rzeczywistych pracowników, a następnie przypisz im dynamiczne role i lokale." editable={editable} add={()=>editProfile("new")}/><p className="matrix-v2-empty">Brak pracowników do skonfigurowania.</p></section></div>;

  return <div id="configuration-step-employees" className="matrix-v2-tab-content matrix-v2-workforce">
    <section className="matrix-v2-card workforce-picker">
      <div><h3>Konfiguracja pracownika</h3><p>{data.workforceCounts?.active ?? employees.filter(item=>item.active).length} aktywnych • {data.workforceCounts?.archived ?? employees.filter(item=>!item.active).length} w archiwum. Zmiany profilu trafiają wyłącznie do wersji roboczej.</p></div>
      <div className="workforce-employee-search"><label htmlFor="matrix-employee-search">Znajdź pracownika<input id="matrix-employee-search" type="search" value={employeeQuery} onChange={event=>setEmployeeQuery(event.target.value)} placeholder="Imię, nazwisko, numer, e-mail, rola, lokal lub obowiązek" autoComplete="off"/></label>{employeeMatches.length>0&&<div role="listbox" aria-label="Wyniki wyszukiwania pracowników">{employeeMatches.map(item=><button type="button" role="option" aria-selected={item.id===employee.id} key={item.id} onClick={()=>{setEmployeeId(item.id);setEmployeeQuery("");setTimeEdit(null);setRateEdit(null);}}><span><b>{item.firstName} {item.lastName}</b><small>{item.employeeNo}{item.email?` • ${item.email}`:""}</small></span>{!item.active&&<em>Archiwalny</em>}</button>)}</div>}{employeeQuery.trim()&&!employeeMatches.length&&<small>Brak pracownika pasującego do wyszukiwania.</small>}</div>
      {editable&&<button className="secondary-button" onClick={()=>editProfile("new")}><Plus/> Dodaj pracownika</button>}
    </section>

    <section className={`matrix-v2-card workforce-profile ${employee.active?"":"archived"}`}>
      <div><Users/><span><small>{employee.employeeNo}</small><h3>{employee.firstName} {employee.lastName}</h3><p>{employee.primaryRoleId?itemName(data.roles,employee.primaryRoleId):"Brak roli podstawowej"} • {employeeLocations.filter(item=>item.active&&item.standard_allowed).map(item=>itemName(data.locations,item.location_id)).join(", ")||"Brak zwykłego lokalu pracy"}</p></span></div>
      <dl><div><dt>Status</dt><dd>{employee.active?"Aktywny":"Archiwalny"}</dd></div><div><dt>Forma współpracy</dt><dd>{contractTypeLabel(employee.contractType)}</dd></div><div><dt>{flexibleContractor?"Plan ewidencyjny":"Nominał"}</dt><dd>{Math.round(Number(employee.nominalMonthlyMinutes??0)/60)} godz./mies.{flexibleContractor?" • nie blokuje silnika":""}</dd></div><div><dt>{flexibleContractor?"Uzgodniony pułap":"Twardy limit miesięczny"}</dt><dd>{Math.round(Number(employee.maximumMonthlyMinutes??0)/60)} godz.{flexibleContractor?" • informacyjnie":""}</dd></div><div><dt>Zatrudnienie</dt><dd>{employee.employmentStart??"bez daty"}{employee.employmentEnd?` – ${employee.employmentEnd}`:""}</dd></div></dl>
      {flexibleContractor&&<p className="matrix-v2-form-hint"><strong>Silnik nie używa wartości ewidencyjnych jako twardych limitów.</strong> Przydziela według dostępności, roli, lokalu, kompetencji, braku nakładania zmian i twardych niedostępności.</p>}
      {employee.archiveReason&&<p className="matrix-v2-form-hint">Powód archiwizacji: {employee.archiveReason}</p>}
      {editable&&<div className="workforce-profile-actions"><button className="secondary-button" onClick={()=>editProfile(employee)}><Edit3/> Edytuj dane</button>{employee.active?<button className="danger-button" disabled={busy} onClick={()=>void setArchived(employee,true)}><Archive/> Archiwizuj</button>:<button className="secondary-button" disabled={busy} onClick={()=>void setArchived(employee,false)}><RefreshCw/> Przywróć</button>}</div>}
      {profileReadiness&&<div className={`workforce-profile-readiness ${profileReadiness.complete?"complete":"incomplete"}`}>
        <header><span><ShieldCheck/><div><strong>{profileReadiness.complete?"Profil gotowy do planowania":"Dokończ profil pracownika"}</strong><small>{profileReadiness.completed} z {profileReadiness.total} wymaganych obszarów gotowych</small></div></span><em>{Math.round(profileReadiness.completed/profileReadiness.total*100)}%</em></header>
        <div>{profileReadiness.checks.map(check=><button type="button" key={check.key} className={check.complete?"complete":""} disabled={!editable||check.complete} onClick={()=>repairProfileCheck(check.key)}><span>{check.complete?<Check/>:<AlertTriangle/>}<span><b>{check.label}</b><small>{check.detail}</small></span></span><em>{check.complete?"Gotowe":check.key==="rate"?"Uzupełnij stawkę":"Uzupełnij"}</em></button>)}</div>
        <p><Check/> Dodatkowe obowiązki i kompetencje są opcjonalne — przypisz je tylko wtedy, gdy dana rola lub pracownik rzeczywiście ich potrzebuje.</p>
      </div>}
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

    {data.financeVisible&&<section className="matrix-v2-card" id={`matrix-v2-rate-${employee.id}`}>
      <div className="matrix-v2-section-head"><div><h3>Chroniona historia stawki</h3><p>Solver używa stawki obowiązującej w miesiącu grafiku; starsze okresy pozostają odtwarzalne.</p></div><ShieldCheck/></div>
      {financeOnboardingEmployeeId===employee.id&&<div className="matrix-v2-finance-onboarding"><span><strong>Krok 2 z 2 • uzupełnij stawkę nowego pracownika</strong><small>Bez aktywnej stawki nie opublikujesz Matrixa dla miesiąca, w którym ta osoba pracuje.</small></span><button type="button" className="secondary-button" disabled={busy} onClick={()=>{if(window.confirm("Pominąć stawkę na razie? Publikacja Matrixa pozostanie zablokowana do czasu jej uzupełnienia."))void dismissFinanceOnboarding(employee.id);}}>Pomiń świadomie</button></div>}
      <div className="matrix-v2-time-list">
        {rates.map(item=><article key={item.id}><CircleDollarSign/><span><strong>{money(item.base_rate_minor, currency)}</strong><small>{item.valid_from>localToday(timezone)?"Zaplanowana od":"Od"} {item.valid_from}{item.valid_to?` do ${item.valid_to}`:" • bez daty końcowej"}{item.contract_type?` • ${contractTypeLabel(item.contract_type)}`:""}{item.active?"":" • nieaktywna"}</small></span><button className="secondary-button" onClick={()=>beginRateEdit(item)}><Edit3/> Edytuj</button></article>)}
        {!rates.length&&<p className="matrix-v2-empty">Nie zapisano jeszcze stawki v2.</p>}
      </div>
      {rateEdit&&<div className="matrix-v2-edit-mode"><span><strong>Edytujesz istniejącą stawkę</strong><small>od {rateEdit.valid_from}{rateEdit.valid_to?` do ${rateEdit.valid_to}`:" • bez daty końcowej"}</small></span><button type="button" className="secondary-button" onClick={()=>setRateEdit(null)}><X/> Anuluj edycję</button></div>}
      <form id={`matrix-v2-rate-form-${employee.id}`} className="matrix-v2-inline-form rates" key={`${employee.id}:${rateEdit?.id??"new"}`} onSubmit={event=>{event.preventDefault();const form=new FormData(event.currentTarget);void saveRate({id:rateEdit?.id??null,employeeId:employee.id,validFrom:String(form.get("validFrom")),validTo:String(form.get("validTo")??""),amount:String(form.get("amount")),contractType:String(form.get("contractType")??""),active:form.has("active")}).then(ok=>{if(ok)setRateEdit(null);});}}>
        <label>Od<input name="validFrom" type="date" min={maxDate(dateHorizon(-50),employee.employmentStart)} max={minDate(dateHorizon(2),employee.employmentEnd)} required defaultValue={rateEdit?.valid_from??maxDate(`${month}-01`,employee.employmentStart)}/><small>{employee.employmentStart?`Najwcześniej: ${employee.employmentStart}`:"Musi odpowiadać okresowi współpracy."}</small></label>
        <label>Do<input name="validTo" type="date" min={rateEdit?.valid_from??employee.employmentStart??undefined} max={minDate(dateHorizon(10),employee.employmentEnd)} defaultValue={rateEdit?.valid_to??""}/><small>{employee.employmentEnd?`Najpóźniej: ${employee.employmentEnd}`:"Puste pole oznacza stawkę bez daty końcowej."}</small></label>
        <label>Stawka godzinowa ({currency})<input name="amount" type="number" min="0" step="0.01" required defaultValue={minorToInput(rateEdit?.base_rate_minor)}/></label>
        <label>Forma współpracy w tym okresie<input type="hidden" name="contractType" value={rateEdit?.contract_type??employee.contractType??"INNE"}/><span className="matrix-v2-readonly-value">{contractTypeLabel(rateEdit?.contract_type??employee.contractType)}</span><small>Nie wpisujesz jej ponownie. Nowa stawka dziedziczy formę współpracy z profilu pracownika.</small></label>
        <label className="check-label"><input name="active" type="checkbox" defaultChecked={rateEdit?.active??true}/> Aktywna</label>
        <button className="primary-button" disabled={busy}><Save/> {rateEdit?"Zapisz zmiany":"Dodaj stawkę"}</button>
      </form>
    </section>}
  </div>;
}

function WorkforceLinks({title,items,editable,add,edit}:{title:string;items:{id:string;label:string;detail:string;item:Record<string,unknown>}[];editable:boolean;add:()=>void;edit:(item:Record<string,unknown>)=>void}) {
  return <section className="matrix-v2-card"><SectionHead title={title} description="" editable={editable} add={add}/><div className="matrix-v2-entities">{items.map(row=><button key={row.id} onClick={()=>editable&&edit(row.item)}><span><strong>{row.label}</strong><small>{row.detail}</small></span>{editable&&<Edit3/>}</button>)}{!items.length&&<p className="matrix-v2-empty">Brak przypisań.</p>}</div></section>;
}

function StaffingTab({data, editable, busy, edit, bulkAdjust, defaultScenarioCount,embedded=false}: {
  data: MatrixV2Workspace;
  editable: boolean;
  busy: boolean;
  edit: (value: EditTarget) => void;
  bulkAdjust: (input: {scenarioId:string;locationId:string|null;shiftPeriod:string|null;roleId:string|null;delta:number;visibleCount:number}) => Promise<boolean>;
  defaultScenarioCount: number;
  embedded?:boolean;
}) {
  const defaultScenarioId=data.scenarios.find(scenario=>scenario.active&&scenario.is_default)?.id
    ??data.scenarios.find(scenario=>scenario.active)?.id??"";
  const [scenarioId,setScenarioId]=useState(defaultScenarioId);
  const [locationId,setLocationId]=useState("");
  const [roleId,setRoleId]=useState("");
  useEffect(()=>{
    if(!data.scenarios.some(scenario=>scenario.id===scenarioId))setScenarioId(defaultScenarioId);
  },[data.scenarios,defaultScenarioId,scenarioId]);
  const visibleRules=data.staffingRules.filter(rule=>{
    const shift=data.shiftTemplates.find(item=>item.id===rule.shift_template_id);
    return (!scenarioId||rule.scenario_id===scenarioId)
      &&(!locationId||shift?.location_id===locationId)
      &&(!roleId||rule.role_id===roleId);
  });
  const bulkEligible=visibleRules.filter(rule=>rule.active&&["SET","ADD"].includes(rule.operation));
  const runBulk=(delta:number)=>bulkAdjust({
    scenarioId,locationId:locationId||null,shiftPeriod:null,
    roleId:roleId||null,delta,visibleCount:bulkEligible.length,
  });
  return <div className={`matrix-v2-tab-content${embedded?" matrix-v2-unified-staffing":""}`}>
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
      <SectionHead title="Wymagana liczba osób" description="Wybierz konkretną zmianę, następnie rolę, opcjonalny obowiązek lub kompetencję i liczbę potrzebnych osób." editable={editable} disabled={!data.scenarios.length || !data.shiftTemplates.length || !data.roles.length} add={() => edit({kind: "STAFFING_RULE"})}/>
      <div className="matrix-v2-filterbar staffing-filters">
        <label>Scenariusz<select value={scenarioId} onChange={event=>setScenarioId(event.target.value)}>{data.scenarios.map(scenario=><option key={scenario.id} value={scenario.id}>{scenario.name}{scenario.is_default?" • bazowy":""}</option>)}</select></label>
        <label>Lokal<select value={locationId} onChange={event=>setLocationId(event.target.value)}><option value="">Wszystkie lokale</option>{data.locations.map(location=><option key={location.id} value={location.id}>{location.name}</option>)}</select></label>
        <label>Rola<select value={roleId} onChange={event=>setRoleId(event.target.value)}><option value="">Wszystkie role</option>{data.roles.map(role=><option key={role.id} value={role.id}>{role.name}</option>)}</select></label>
        <strong>{visibleRules.length} z {data.staffingRules.length} reguł</strong>
      </div>
      {editable&&<div className="matrix-v2-bulkbar">
        <span><strong>Zmień wszystkie widoczne reguły naraz</strong><small>Dotyczy {bulkEligible.length} aktywnych reguł z liczbą osób. Reguły mnożnikowe i usuwające pozostaną bez zmian.</small></span>
        <button className="secondary-button" disabled={busy||!bulkEligible.length} onClick={()=>void runBulk(-1)}>− 1 osoba</button>
        <button className="primary-button" disabled={busy||!bulkEligible.length} onClick={()=>void runBulk(1)}>+ 1 osoba</button>
      </div>}
      <div className="matrix-v2-staffing-groups">
        {data.locations.map(location=>{
          const localRules=visibleRules.filter(rule=>data.shiftTemplates.find(shift=>shift.id===rule.shift_template_id)?.location_id===location.id);
          if(!localRules.length)return null;
          const localShifts=data.shiftTemplates.filter(shift=>shift.location_id===location.id&&localRules.some(rule=>rule.shift_template_id===shift.id));
          return <section key={location.id} className="matrix-v2-staffing-location">
            <header><span><MapPin/><div><h4>{location.name}</h4><small>{plural(localShifts.length,"zmiana","zmiany","zmian")} • {plural(localRules.length,"reguła","reguły","reguł")}</small></div></span>{editable&&<button className="secondary-button" onClick={()=>edit({kind:"STAFFING_RULE",item:{scenario_id:scenarioId,location_id:location.id} as Record<string,unknown>})}><Plus/> Dodaj wymaganie</button>}</header>
            <div className="matrix-v2-staffing-shifts">{localShifts.map(shift=>{
              const shiftRules=localRules.filter(rule=>rule.shift_template_id===shift.id);
              return <details key={shift.id}>
                <summary><span><Clock3/><b>{shift.name}</b><small>{time(shift.starts_at)}–{time(shift.ends_at)}{shift.ends_next_day?" • następny dzień":""}</small></span><strong>{plural(shiftRules.length,"wymaganie","wymagania","wymagań")}</strong></summary>
                <div className="matrix-v2-staffing-rule-rows">{shiftRules.map(rule=><button key={rule.id} onClick={()=>editable&&edit({kind:"STAFFING_RULE",item:rule})}>
                  <span><b>{itemName(data.roles,rule.role_id)}</b><small>{rule.duty_id?`Wymagany obowiązek: ${itemName(data.duties,rule.duty_id)}`:"Bez dodatkowego wymogu obowiązku — liczy się rola"}</small></span>
                  <strong>{staffingValue(rule)}</strong>
                  <em className={rule.active?"on":"off"}>{rule.active?"Aktywna":"Wyłączona"}</em>
                  {editable&&<Edit3/>}
                </button>)}</div>
              </details>;
            })}</div>
          </section>;
        })}
        {!visibleRules.length&&<p className="matrix-v2-empty">Brak reguł pasujących do wybranych filtrów.</p>}
      </div>
    </section>
  </div>;
}

function staffingValue(rule: MatrixV2StaffingRule) {
  if (rule.operation === "REMOVE") return "Bez wymagania";
  if (rule.operation === "MULTIPLY") return `× ${Number(rule.multiplier_basis_points ?? 0) / 10000}`;
  if (rule.operation === "ADD") return `+ ${rule.count_value ?? 0} os.`;
  return `${rule.count_value ?? 0} os.`;
}

function businessObjectiveLabel(code:string) {
  return ({
    UNFILLED:"Obsadź wszystkie wymagane miejsca",
    TOTAL_COST:"Spośród poprawnych grafików wybierz tańszy",
    PREFERENCE_VIOLATIONS:"Uwzględnij preferencje pracowników",
    NOMINAL_DEVIATION_MINUTES:"Zbliż liczbę godzin do indywidualnych ustaleń",
    OVERTIME_MINUTES:"Ogranicz nadgodziny tam, gdzie mają zastosowanie",
    LOAD_SPREAD_MINUTES:"Rozdziel godziny możliwie równo",
    WEEKEND_SPREAD:"Rozdziel pracę weekendową możliwie równo",
    BASELINE_CHANGES:"Ogranicz zmiany wobec grafiku bazowego",
  } as Record<string,string>)[code]??objectiveName(code);
}

function activeBusinessObjectives(data:MatrixV2Workspace,strategyId:string){
  return data.strategyObjectives.filter(objective=>objective.strategy_id===strategyId&&objective.active&&objective.metric_code!=="HOME_LOCATION_VIOLATIONS");
}

function strategySignature(data:MatrixV2Workspace,strategyId:string){
  return activeBusinessObjectives(data,strategyId).map(objective=>({
    metric:objective.metric_code,tier:objective.tier,direction:objective.direction,
    weight:objective.weight,tolerance:objective.tolerance,parameters:objective.parameters??{},
  })).sort((left,right)=>left.tier-right.tier||left.metric.localeCompare(right.metric)).map(value=>JSON.stringify(value)).join("|");
}

function strategyRelativeLevel(data:MatrixV2Workspace,strategyId:string,metric:string){
  const strategies=data.strategies.filter(strategy=>strategy.active);
  const values=strategies.map(strategy=>{
    const objective=activeBusinessObjectives(data,strategy.id).find(item=>item.metric_code===metric);
    return {strategyId:strategy.id,tier:objective?.tier??101,weight:objective?.weight??0};
  });
  const current=values.find(value=>value.strategyId===strategyId)??{tier:101,weight:0};
  const ordered=[...values].sort((left,right)=>left.tier-right.tier||right.weight-left.weight);
  const best=ordered[0],worst=ordered.at(-1)!;
  if(values.every(value=>value.tier===best.tier&&value.weight===best.weight))return {className:"same",label:"Taki sam nacisk"};
  if(current.tier===best.tier&&current.weight===best.weight)return {className:"high",label:"Najwyższy priorytet"};
  if(current.tier===worst.tier&&current.weight===worst.weight)return {className:"low",label:"Najniższy priorytet"};
  return {className:"medium",label:"Pośredni nacisk"};
}

function strategyDistinguishers(data:MatrixV2Workspace,strategyId:string){
  return activeBusinessObjectives(data,strategyId).filter(objective=>objective.metric_code!=="UNFILLED")
    .map(objective=>({objective,level:strategyRelativeLevel(data,strategyId,objective.metric_code)}))
    .filter(item=>item.level.className==="high")
    .sort((left,right)=>right.objective.weight-left.objective.weight)
    .slice(0,3);
}

function StrategiesTab({data, editable, edit, unlinkedScenarios, incompleteStrategies}: {data: MatrixV2Workspace; editable: boolean; edit: (value: EditTarget) => void; unlinkedScenarios: MatrixV2Scenario[]; incompleteStrategies: MatrixV2Strategy[]}) {
  const activeStrategies=data.strategies.filter(strategy=>strategy.active);
  const signatures=new Map(activeStrategies.map(strategy=>[strategy.id,strategySignature(data,strategy.id)]));
  const duplicateStrategies=activeStrategies.filter((strategy,index)=>activeStrategies.some((candidate,candidateIndex)=>candidateIndex<index&&signatures.get(candidate.id)===signatures.get(strategy.id)));
  const comparedMetrics=[...new Set(activeStrategies.flatMap(strategy=>activeBusinessObjectives(data,strategy.id).map(objective=>objective.metric_code)))]
    .filter(metric=>!['UNFILLED','HOME_LOCATION_VIOLATIONS'].includes(metric));
  return <div id="configuration-step-variants" className="matrix-v2-tab-content">
    <div className="matrix-v2-business-flow"><section><b>1</b><span><strong>Scenariusz mówi, jakiej obsady potrzebujesz</strong><small>Przykład: miesiąc bazowy, większy ruch albo więcej urlopów. Lider wybiera scenariusz przed generowaniem.</small></span></section><ChevronRight/><section><b>2</b><span><strong>Wariant mówi, który poprawny grafik jest korzystniejszy</strong><small>Każdy wariant respektuje te same twarde blokady. Różni się sposobem oceny kilku poprawnych rozwiązań.</small></span></section><ChevronRight/><section><b>3</b><span><strong>Lider porównuje wyniki i wybiera jeden</strong><small>Jedna aktywna strategia przypisana do scenariusza oznacza jeden osobno policzony wariant.</small></span></section></div>
    <div className="matrix-v2-business-help"><Sparkles/><span><strong>Dlaczego trzy warianty mogą dać ten sam grafik?</strong><small>Różne priorytety nie gwarantują różnych przydziałów. Jeżeli twarde reguły, dostępność i kompetencje pozostawiają tylko jeden poprawny skład, wszystkie warianty uczciwie pokażą ten sam wynik. Interfejs oznaczy wtedy identyczny skład zamiast udawać różnicę.</small></span></div>
    {(unlinkedScenarios.length > 0 || incompleteStrategies.length > 0) && <div className="matrix-v2-validation warning"><AlertTriangle/><span><strong>Konfiguracja strategii wymaga uzupełnienia</strong><small>{unlinkedScenarios.length ? `${plural(unlinkedScenarios.length, "scenariusz nie ma", "scenariusze nie mają", "scenariuszy nie ma")} aktywnej strategii. ` : ""}{incompleteStrategies.length ? `${plural(incompleteStrategies.length, "strategia nie zaczyna", "strategie nie zaczynają", "strategii nie zaczyna")} się od minimalizacji braków.` : ""}</small></span></div>}
    {duplicateStrategies.length>0&&<div className="matrix-v2-validation warning"><AlertTriangle/><span><strong>Co najmniej dwa warianty są skonfigurowane identycznie</strong><small>{duplicateStrategies.map(strategy=>strategy.name).join(", ")} nie wnosi innego sposobu oceny. Taki wariant nie powinien być liczony osobno, dopóki jego konfiguracja nie zostanie świadomie zmieniona.</small></span></div>}
    <section className="matrix-v2-card">
      <div className="matrix-v2-section-head"><div><h3>Co faktycznie różni warianty</h3><p>Porównanie tego samego kryterium pomiędzy aktywnymi wariantami. Nie porównujemy surowych wag różnych kryteriów, bo mają różne jednostki.</p></div></div>
      <div className="matrix-v2-strategy-comparison"><div className="head"><strong>Kryterium biznesowe</strong>{activeStrategies.map(strategy=><b key={strategy.id}>{strategy.name}</b>)}</div>{comparedMetrics.map(metric=><div key={metric}><strong>{businessObjectiveLabel(metric)}</strong>{activeStrategies.map(strategy=>{const level=strategyRelativeLevel(data,strategy.id,metric);return <span key={strategy.id} className={level.className}>{level.label}</span>;})}</div>)}</div>
    </section>
    <section className="matrix-v2-card">
      <SectionHead title="Warianty biznesowe" description="Najpierw każdy wariant minimalizuje braki obsady. Poniższe akcenty rozstrzygają dopiero pomiędzy poprawnymi rozwiązaniami." editable={editable} add={() => edit({kind: "STRATEGY"})}/>
      <div className="matrix-v2-strategy-grid">
        {data.strategies.map(strategy => {
          const objectives = activeBusinessObjectives(data,strategy.id).sort((a,b) => a.tier-b.tier || a.sort_order-b.sort_order);
          const scenarios = data.scenarioStrategies.filter(item => item.strategy_id === strategy.id && item.active).map(item => itemName(data.scenarios, item.scenario_id));
          const distinguishers=strategyDistinguishers(data,strategy.id);
          const sameAs=data.strategies.find(candidate=>candidate.id!==strategy.id&&candidate.active&&signatures.get(candidate.id)===signatures.get(strategy.id));
          return <article key={strategy.id} className={!strategy.active ? "inactive" : ""}>
            <div><span><small>WARIANT BIZNESOWY</small><h4>{strategy.name}</h4></span>{editable && <button title="Edytuj nazwę i opis" onClick={() => edit({kind: "STRATEGY", item: strategy})}><Edit3/></button>}</div>
            <p>{strategy.description || "Strategia bez dodatkowego opisu."}</p>
            <div className="matrix-v2-strategy-first-rule"><ShieldCheck/><span><b>Zawsze najpierw: pełna wymagana obsada</b><small>oraz wszystkie twarde reguły pracowników i zmian</small></span></div>
            <div className="matrix-v2-strategy-emphasis"><strong>Co wyróżnia ten wariant</strong>{distinguishers.length?distinguishers.map(({objective})=><span key={objective.id}>{businessObjectiveLabel(objective.metric_code)}</span>):<p>Kompromis — żadne miękkie kryterium nie ma tu skrajnie najwyższego nacisku względem pozostałych wariantów.</p>}</div>
            {sameAs&&<div className="matrix-v2-strategy-duplicate"><AlertTriangle/> Identyczna konfiguracja jak „{sameAs.name}”.</div>}
            <details className="matrix-v2-technical-objectives"><summary>Zaawansowane ustawienia administratora silnika</summary><p className="matrix-v2-form-hint">Kryteria na tym samym poziomie są liczone łącznie z różnymi wagami — nie kolejno od góry. Zmiana wymaga testu algorytmu.</p><div className="matrix-v2-objectives">{objectives.map(objective => <button disabled={!editable} key={objective.id} onClick={() => editable && edit({kind: "OBJECTIVE", item: objective})}><b>Etap {objective.tier}</b><span>{objectiveName(objective.metric_code)}</span><em>{objective.direction === "MINIMIZE" ? "zmniejszaj" : "zwiększaj"}</em></button>)}</div>{editable && <button className="matrix-v2-add-inline" onClick={() => edit({kind: "OBJECTIVE", item: {strategy_id: strategy.id} as MatrixV2Objective})}><Plus/> Dodaj kryterium zaawansowane</button>}</details>
            <small className="matrix-v2-used-by">Scenariusze: {scenarios.length ? scenarios.join(", ") : "brak"}</small>
          </article>;
        })}
      </div>
    </section>
    <section className="matrix-v2-card">
      <SectionHead title="Które warianty policzyć dla każdego scenariusza" description="Lider najpierw wybiera scenariusz miesiąca. System policzy po jednym wyniku dla każdego aktywnego wariantu widocznego w jego karcie." editable={editable} disabled={!data.scenarios.length || !data.strategies.length} add={() => edit({kind: "SCENARIO_STRATEGY"})}/>
      <div className="matrix-v2-scenario-variant-groups">{data.scenarios.map(scenario=>{const links=data.scenarioStrategies.filter(link=>link.scenario_id===scenario.id);return <article key={scenario.id}><header><span><GitBranch/><div><h4>{scenario.name}</h4><small>{scenario.is_default?"Scenariusz bazowy":"Scenariusz alternatywny"} • {links.filter(link=>link.active).length} generowane warianty</small></div></span>{editable&&<button className="secondary-button" onClick={()=>edit({kind:"SCENARIO_STRATEGY",item:{scenario_id:scenario.id} as Record<string,unknown>})}><Plus/> Dodaj wariant</button>}</header><div>{links.map(link=><button key={link.id} onClick={()=>editable&&edit({kind:"SCENARIO_STRATEGY",item:link})}><span><strong>{itemName(data.strategies,link.strategy_id)}</strong><small>{link.active?"Będzie policzony":"Wyłączony — nie będzie liczony"}{scenarioStrategySummary(link)}</small></span><em className={link.active?"on":"off"}>{link.active?"Aktywny":"Wyłączony"}</em>{editable&&<ChevronRight/>}</button>)}{!links.length&&<p className="matrix-v2-empty">Brak wariantów — dla tego scenariusza nie powstanie wynik.</p>}</div></article>;})}</div>
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

function MatrixHistoryDrawer({currentVersionId,close,fail}:{currentVersionId:string;close:()=>void;fail:(message:string)=>void}){
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [payload,setPayload]=useState<MatrixHistoryPayload|null>(null);
  const [loading,setLoading]=useState(true);
  const [view,setView]=useState<"versions"|"audit">("versions");
  const [compareIds,setCompareIds]=useState<string[]>([]);
  const [comparison,setComparison]=useState<MatrixVersionComparison|null>(null);
  const [comparisonLoading,setComparisonLoading]=useState(false);
  const comparisonRef=useRef<HTMLElement|null>(null);
  const [section,setSection]=useState("");
  const [actor,setActor]=useState("");
  const [fromDate,setFromDate]=useState("");
  const [toDate,setToDate]=useState("");
  const [query,setQuery]=useState("");

  useEffect(()=>{
    let alive=true;
    void (async()=>{
      if(!supabase){setLoading(false);return;}
      const result=await supabase.rpc("matrix_v2_revision_history_uat_v2",{p_limit:500});
      if(!alive)return;
      setLoading(false);
      if(result.error){fail(matrixV2ErrorMessage(result.error.message));return;}
      setPayload(result.data as MatrixHistoryPayload);
    })();
    return()=>{alive=false;};
  },[fail,supabase]);

  useEffect(()=>{
    let alive=true;
    setComparison(null);
    setComparisonLoading(false);
    if(compareIds.length!==2||!supabase)return()=>{alive=false;};
    setComparisonLoading(true);
    void (async()=>{
      const result=await supabase.rpc("matrix_v2_compare_versions_uat_v2",{
        p_left_version_id:compareIds[0],p_right_version_id:compareIds[1],
      });
      if(!alive)return;
      setComparisonLoading(false);
      if(result.error){fail(matrixV2ErrorMessage(result.error.message));return;}
      setComparison(result.data as MatrixVersionComparison);
      window.requestAnimationFrame(()=>comparisonRef.current?.scrollIntoView({behavior:"smooth",block:"start"}));
    })();
    return()=>{alive=false;};
  },[compareIds,fail,supabase]);

  const toggleCompare=(id:string)=>setCompareIds(current=>current.includes(id)
    ?current.filter(value=>value!==id)
    :current.length<2?[...current,id]:[current[1],id]);
  const sections=[...new Set((payload?.audit??[]).map(entry=>entry.section))].sort();
  const actors=[...new Set((payload?.audit??[]).map(entry=>entry.actor))].sort();
  const normalizedQuery=query.trim().toLocaleLowerCase("pl-PL");
  const audit=(payload?.audit??[]).filter(entry=>(!section||entry.section===section)
    &&(!actor||entry.actor===actor)
    &&(!fromDate||entry.createdAt.slice(0,10)>=fromDate)
    &&(!toDate||entry.createdAt.slice(0,10)<=toDate)
    &&(!normalizedQuery||`${entry.section} ${entry.actor} ${auditActionLabel(entry.action)} ${auditEntrySubject(entry)}`.toLocaleLowerCase("pl-PL").includes(normalizedQuery)));
  const versionById=new Map((payload?.versions??[]).map(version=>[version.id,version]));
  const left=compareIds[0]?versionById.get(compareIds[0]):undefined;
  const right=compareIds[1]?versionById.get(compareIds[1]):undefined;

  return <><button className="drawer-scrim top" onClick={close}/><aside className="drawer matrix-history-drawer top">
    <div className="drawer-head"><div><p className="eyebrow">MATRIX • PEŁNA HISTORIA</p><h2>Wersje i dziennik zmian</h2></div><button className="icon-button" onClick={close}><X/></button></div>
    <div className="drawer-content">
      <div className="matrix-history-intro"><HistoryIcon/><span><strong>Poprzednie wersje nie są nadpisywane</strong><small>Możesz otworzyć podsumowanie wersji tylko do odczytu, porównać dwie wersje oraz sprawdzić kto i kiedy zmieniał Matrix.</small></span></div>
      <nav className="matrix-history-tabs"><button className={view==="versions"?"active":""} onClick={()=>setView("versions")}>Wersje Matrixa</button><button className={view==="audit"?"active":""} onClick={()=>setView("audit")}>Audit trail</button></nav>
      {loading&&<p className="matrix-v2-empty">Wczytuję historię…</p>}
      {!loading&&view==="versions"&&<>
        <div className="matrix-history-compare-help"><span><strong>Porównanie wersji</strong><small>Zaznacz dokładnie dwie wersje. Porównanie pokaże, które sekcje i liczby elementów się zmieniły.</small></span><b>{compareIds.length}/2</b></div>
        <div className="matrix-history-compare-status" role="status" aria-live="polite">{compareIds.length<2?`Wybierz jeszcze ${2-compareIds.length} ${compareIds.length===0?"wersje":"wersję"}.`:comparisonLoading?"Porównuję wybrane wersje…":comparison?"Porównanie jest gotowe i znajduje się poniżej.":"Oczekiwanie na wynik porównania."}</div>
        {left&&right&&comparison&&<section ref={comparisonRef} tabIndex={-1} className="matrix-version-comparison"><header><strong>Wynik: v{left.version} → v{right.version}</strong><small>{comparison.sections.filter(item=>item.changed).length+(comparison.settingsChanged?1:0)} zmienionych sekcji</small></header>{comparison.settingsChanged&&<div><span>Ustawienia firmy</span><b>Zmienione</b></div>}{comparison.sections.filter(item=>item.changed).map(item=><div key={item.key}><span>{item.label}</span><strong>{item.leftCount} → {item.rightCount}</strong></div>)}{!comparison.settingsChanged&&!comparison.sections.some(item=>item.changed)&&<p>Wersje mają identyczną konfigurację operacyjną.</p>}</section>}
        <div className="matrix-version-list">{(payload?.versions??[]).map(version=><details key={version.id} open={version.id===currentVersionId}>
          <summary><label onClick={event=>event.stopPropagation()}><input type="checkbox" checked={compareIds.includes(version.id)} onChange={()=>toggleCompare(version.id)}/><span>Porównaj</span></label><span><b>v{version.version} • {version.name}</b><small>{matrixVersionStatusLabel(version.status)}{version.id===currentVersionId?" • obecnie otwarta":""}</small></span><time>{formatHistoryDate(version.publishedAt??version.createdAt)}</time></summary>
          <div className="matrix-version-readonly"><div><ShieldCheck/><span><strong>Podgląd tylko do odczytu</strong><small>Utworzona przez: {version.createdBy}{version.publishedBy?` • opublikowana przez: ${version.publishedBy}`:""}</small></span></div><dl>{Object.entries(version.counts).map(([key,value])=><div key={key}><dt>{matrixVersionCountLabel(key)}</dt><dd>{value}</dd></div>)}</dl><p>Obowiązuje: {version.effectiveFrom}{version.effectiveTo?` – ${version.effectiveTo}`:" – bez daty końcowej"}</p></div>
        </details>)}</div>
      </>}
      {!loading&&view==="audit"&&<>
        <div className="matrix-history-filters"><label>Sekcja<select value={section} onChange={event=>setSection(event.target.value)}><option value="">Wszystkie sekcje</option>{sections.map(value=><option key={value}>{value}</option>)}</select></label><label>Osoba<select value={actor} onChange={event=>setActor(event.target.value)}><option value="">Wszyscy</option>{actors.map(value=><option key={value}>{value}</option>)}</select></label><label>Od<input type="date" value={fromDate} onChange={event=>setFromDate(event.target.value)}/></label><label>Do<input type="date" value={toDate} onChange={event=>setToDate(event.target.value)}/></label><label>Szukaj<input value={query} onChange={event=>setQuery(event.target.value)} placeholder="np. obsada, publikacja, pracownik"/></label></div>
        <p className="matrix-history-result-count">{audit.length} z {payload?.audit.length??0} wpisów</p>
        <div className="matrix-audit-list">{audit.map(entry=><details key={entry.id}><summary><span><b>{auditEntrySubject(entry)}</b><small>{entry.section} • {entry.actor}</small></span><time>{formatHistoryDate(entry.createdAt)}</time><strong>{auditActionLabel(entry.action)}</strong></summary><div className="matrix-audit-detail"><AuditPayload title="Przed zmianą" data={entry.oldData}/><AuditPayload title="Po zmianie" data={entry.newData}/></div></details>)}{!audit.length&&<p className="matrix-v2-empty">Brak wpisów spełniających filtry.</p>}</div>
      </>}
    </div>
  </aside></>;
}

function formatHistoryDate(value:string){return new Intl.DateTimeFormat("pl-PL",{dateStyle:"short",timeStyle:"short"}).format(new Date(value));}
function matrixVersionStatusLabel(status:MatrixRevisionVersion["status"]){return status==="ACTIVE"?"Aktywna":status==="DRAFT"?"Wersja robocza":"Archiwalna";}
function matrixVersionCountLabel(key:string){return ({employees:"Pracownicy",roles:"Role",locations:"Lokale",duties:"Obowiązki",shifts:"Zmiany",staffingRules:"Reguły obsady",scenarios:"Scenariusze",strategies:"Warianty"} as Record<string,string>)[key]??key;}
function auditActionLabel(action:string){return ({UPSERT:"Zapisano zmianę",PUBLISH:"Opublikowano",ARCHIVE:"Zarchiwizowano",RESTORE:"Przywrócono",APPLY:"Zaimportowano",BULK_ADJUST_STAFFING:"Zmieniono zbiorczo",BULK_SAVE_STAFFING:"Dodano zbiorczo",SET_DAYS:"Zmieniono dostępność"} as Record<string,string>)[action]??"Zmieniono";}
function auditEntrySubject(entry:MatrixAuditEntry){
  if(entry.action==="PUBLISH")return "Publikacja Matrixa";
  const data=asRecord(entry.newData?.data??entry.newData);
  const named=String(data.name??data.employeeNo??data.code??"").trim();
  const type=entry.entityType.replace(/^matrix_v2_/,"").replaceAll("_"," ");
  return named||({staffing_rule:"Reguła wymaganej obsady",employee:"Dane pracownika",shift:"Zmiana",role:"Rola",location:"Lokal",duty:"Obowiązek",scenario:"Scenariusz",strategy:"Wariant biznesowy"} as Record<string,string>)[type]||"Zmiana w Matrixie";
}
function AuditPayload({title,data}:{title:string;data?:Record<string,unknown>|null}){
  const source=asRecord(data?.data??data);
  const hidden=new Set(["id","matrixVersionId","matrix_version_id","sourceMetadata","contentHash","workforceHash"]);
  const entries=Object.entries(source).filter(([key])=>!hidden.has(key)).slice(0,16);
  return <section><h4>{title}</h4>{entries.length?<dl>{entries.map(([key,value])=><div key={key}><dt>{auditFieldLabel(key)}</dt><dd>{auditValue(value)}</dd></div>)}</dl>:<p>Brak wcześniejszej wartości w historycznym wpisie.</p>}</section>;
}
function auditFieldLabel(key:string){return ({name:"Nazwa",code:"Kod",active:"Aktywna",employeeNo:"Numer pracownika",employmentStart:"Zatrudnienie od",employmentEnd:"Zatrudnienie do",operation:"Sposób działania",countValue:"Liczba osób",validFrom:"Ważne od",validTo:"Ważne do",version:"Wersja",effectiveFrom:"Obowiązuje od",reason:"Powód",updated:"Liczba zmienionych",saved:"Liczba zapisanych",delta:"Zmiana liczby osób"} as Record<string,string>)[key]??key.replace(/([A-Z])/g," $1").replace(/^./,letter=>letter.toUpperCase());}
function auditValue(value:unknown){if(value===null||value===undefined||value==="")return "—";if(typeof value==="boolean")return value?"Tak":"Nie";if(Array.isArray(value))return `${value.length} elementów`;if(typeof value==="object")return `${Object.keys(asRecord(value)).length} ustawień`;return String(value);}

type MatrixImportIssue={sheet:string;row:number;code:string;message:string};
type MatrixImportArchive={employeeId:string;employeeNo:string;employeeName:string;email?:string|null;reason:"NOT_IN_FILE"|"DUPLICATE_IDENTITY"};
type MatrixImportPreview={valid:boolean;errors:MatrixImportIssue[];warnings:MatrixImportIssue[];employeesToArchive?:MatrixImportArchive[];summary:{employees:number;employeeDuties?:number;shifts:number;staffingRules:number;roleDuties:number;total:number;employeesToUpdate?:number;employeesToCreate?:number;employeesToArchive?:number}};
type MatrixImportMode="UPDATE"|"REPLACE";

async function downloadMatrixTemplate(data:MatrixV2Workspace){
  const XLSX=await import("xlsx");
  const workbook=XLSX.utils.book_new();
  const add=(name:string,headers:string[],rows:(string|number|boolean|null)[][]=[])=>{
    const sheet=XLSX.utils.aoa_to_sheet([headers,...rows]);
    sheet["!autofilter"]={ref:`A1:${XLSX.utils.encode_col(headers.length-1)}${Math.max(1,rows.length+1)}`};
    sheet["!freeze"]={xSplit:0,ySplit:1};
    sheet["!cols"]=headers.map(header=>({wch:Math.min(34,Math.max(14,header.length+2))}));
    XLSX.utils.book_append_sheet(workbook,sheet,name);
  };
  const instructions=XLSX.utils.aoa_to_sheet([
    ["MATRIX ALPHA 16 — import zbiorczy","Zasada"],
    ["Nowy pracownik","Pozostaw Numer pracownika pusty. System nada kolejny wolny numer GP-### automatycznie."],
    ["Aktualizacja pracownika","Podaj istniejący numer lub e-mail. Nieistniejący numer zostanie odrzucony w podglądzie."],
    ["Kody","Kody ról, lokali, obowiązków i scenariuszy skopiuj z arkusza Słowniki."],
    ["Listy","Kody lokali oraz dni rozdzielaj przecinkiem; dni: 1=poniedziałek, 7=niedziela."],
    ["Kompetencje pracownika","Każdy aktywny obowiązek ma osobną kolumnę w arkuszu Pracownicy. Wpisz TAK tylko przy osobach, które mogą go wykonywać."],
    ["Lokale pracownika","Kolumny <KOD>_STANDARD i <KOD>_NADGODZINY są niezależne. Lokal bazowy musi być również dozwolony standardowo."],
    ["Ograniczenia pracownika","Tylko rano, Tylko popołudnie i Bez weekendów trafiają do profilu używanego przez silnik. Nie zaznaczaj jednocześnie obu pór."],
    ["Zawartość pliku","Arkusze zawierają aktualną wersję roboczą Matrixa. Zachowaj Numer pracownika lub e-mail, aby aktualizować właściwą osobę."],
    ["Tryb aktualizacji","Zmienia i dodaje wyłącznie osoby obecne w pliku; pozostałych nie dotyka."],
    ["Tryb zastąpienia","Po podglądzie archiwizuje w wersji roboczej osoby nieobecne w pliku. Historia i audit trail pozostają zachowane."],
    ["Pory","MORNING, MIDDLE albo EVENING."],
    ["Preferencje","INHERIT, PREFERRED, NEUTRAL, AVOIDED albo BLOCKED. Matrix pracodawcy ma pierwszeństwo."],
    ["Bezpieczeństwo","Najpierw użyj Podglądu. Zapis wszystkich arkuszy odbywa się atomowo w jednej transakcji."],
  ]);
  instructions["!cols"]=[{wch:30},{wch:100}];
  XLSX.utils.book_append_sheet(workbook,instructions,"Instrukcja");
  const activeDutyCodes=data.duties.filter(item=>item.active).map(item=>item.code);
  const activeLocations=data.locations.filter(item=>item.active);
  const exportRateDate=String(data.month??data.matrixVersion.effective_from??new Date().toISOString()).slice(0,10);
  const employeeRows=data.employees.filter(employee=>employee.active).map(employee=>{
    const role=data.roles.find(item=>item.id===employee.primaryRoleId);
    const employeeLocationGrants=(data.employeeLocations??[]).filter(item=>item.employee_id===employee.id&&item.active);
    const locationCodes=employeeLocationGrants.filter(item=>item.standard_allowed).map(item=>data.locations.find(location=>location.id===item.location_id)?.code).filter(Boolean);
    const baseLocationCode=data.locations.find(location=>employeeLocationGrants.some(grant=>grant.location_id===location.id&&grant.home_location))?.code??"";
    const activeRate=(data.employeePayRates??[]).filter(item=>item.employee_id===employee.id&&item.active
      &&item.valid_from<=exportRateDate&&(!item.valid_to||item.valid_to>=exportRateDate))
      .sort((a,b)=>b.valid_from.localeCompare(a.valid_from))[0];
    const duties=new Set((data.employeeDuties??[]).filter(item=>item.employee_id===employee.id&&item.active).map(item=>data.duties.find(duty=>duty.id===item.duty_id)?.code).filter(Boolean));
    const preferences=employee.shiftPeriodPreferences??{};
    const locationGrantCells=activeLocations.flatMap(location=>{
      const grant=employeeLocationGrants.find(item=>item.location_id===location.id);
      return [grant?.standard_allowed?"TAK":"NIE",grant?.overtime_allowed?"TAK":"NIE"];
    });
    return [employee.employeeNo,employee.active?"TAK":"NIE",employee.firstName,employee.lastName,employee.email??"",role?.code??"",locationCodes.join(", "),baseLocationCode,...locationGrantCells,employee.employmentStart??"",employee.employmentEnd??"",Number(employee.nominalMonthlyMinutes??0)/60,Number(employee.maximumMonthlyMinutes??0)/60,Number(employee.maximumWeeklyMinutes??0)/60,employee.maximumConsecutiveDays,employee.minimumRestMinutes===null||employee.minimumRestMinutes===undefined?"":employee.minimumRestMinutes/60,employee.onlyMorning?"TAK":"NIE",employee.onlyEvening?"TAK":"NIE",employee.noWeekends?"TAK":"NIE",activeRate?activeRate.base_rate_minor/100:"",employee.contractType??activeRate?.contract_type??"INNE",employee.workTimePolicy??"CONTRACT_DEFAULT",data.month?`${String(data.month).slice(0,7)}-01`:"",preferences.MORNING??"INHERIT",preferences.MIDDLE??"INHERIT",preferences.EVENING??"INHERIT",...activeDutyCodes.map(code=>duties.has(code)?"TAK":"")];
  });
  const locationGrantHeaders=activeLocations.flatMap(location=>[`${location.code}_STANDARD`,`${location.code}_NADGODZINY`]);
  add("Pracownicy",["Numer pracownika","Aktywny","Imię","Nazwisko","E-mail","Kod roli","Kody lokali","Lokal bazowy",...locationGrantHeaders,"Zatrudniony od","Zatrudniony do","Nominał godzin","Limit miesięczny godzin","Limit tygodniowy godzin","Maks. kolejnych dni","Minimalny odpoczynek godzin","Tylko rano","Tylko popołudnie","Bez weekendów","Stawka godzinowa","Rodzaj umowy","Polityka czasu pracy","Miesiąc preferencji","Preferencja rano","Preferencja środek","Preferencja wieczór",...activeDutyCodes],employeeRows);
  add("Zmiany",["Kod","Nazwa","Kod lokalu","Pora","Od","Do","Następny dzień","Dni","Kolejność","Aktywna"],data.shiftTemplates.map(shift=>[shift.code,shift.name,data.locations.find(location=>location.id===shift.location_id)?.code??"",shift.shift_period,time(shift.starts_at),time(shift.ends_at),shift.ends_next_day?"TAK":"NIE",shift.day_mask.join(","),shift.sort_order,shift.active?"TAK":"NIE"]));
  add("Obsada",["Kod scenariusza","Kod zmiany","Kod lokalu","Kod roli","Kod obowiązku","Operacja","Liczba osób","Aktywna"],data.staffingRules.map(rule=>{
    const shift=data.shiftTemplates.find(item=>item.id===rule.shift_template_id);
    return [data.scenarios.find(item=>item.id===rule.scenario_id)?.code??"",shift?.code??"",data.locations.find(item=>item.id===shift?.location_id)?.code??"",data.roles.find(item=>item.id===rule.role_id)?.code??"",data.duties.find(item=>item.id===rule.duty_id)?.code??"",rule.operation,rule.count_value??"",rule.active?"TAK":"NIE"];
  }));
  add("Role-Obowiązki",["Kod roli","Kod obowiązku","Znaczenie","Minimum","Obowiązek zmianowy","Pora","Aktywne"],data.roleDuties.map(link=>[data.roles.find(item=>item.id===link.role_id)?.code??"",data.duties.find(item=>item.id===link.duty_id)?.code??"",link.assignment_mode,link.minimum_count,link.shift_obligation?"TAK":"NIE",link.shift_period??"",link.active?"TAK":"NIE"]));
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
  XLSX.writeFile(workbook,`matrix-alpha16-biezaca-baza-v${data.matrixVersion.version}.xlsx`);
}

function MatrixExcelImport({data,busy,setBusy,close,reload,notify,fail}:{data:MatrixV2Workspace;busy:boolean;setBusy:(value:boolean)=>void;close:()=>void;reload:()=>Promise<void>;notify:(message:string)=>void;fail:(message:string)=>void}){
  const supabase=useMemo(()=>createSupabaseBrowserClient(),[]);
  const [file,setFile]=useState<File|null>(null),[payload,setPayload]=useState<Record<string,unknown>|null>(null),[preview,setPreview]=useState<MatrixImportPreview|null>(null),[localError,setLocalError]=useState("");
  const [mode,setMode]=useState<MatrixImportMode>("UPDATE");
  async function inspect(){
    if(!file||!supabase)return;
    setBusy(true);setLocalError("");setPreview(null);
    try{
      const parsed=await readMatrixWorkbook(file);
      if(!parsed.employees.length)throw new Error("Plik nie zawiera żadnego pracownika. Import został zatrzymany bez zmiany danych.");
      const activeImported=parsed.employees.filter(employee=>employee.active!==false).length;
      if(mode==="REPLACE"&&activeImported!==EXPECTED_ACTIVE_EMPLOYEES){
        throw new Error(`Tryb „Zastąp aktywną bazę” wymaga obecnie dokładnie ${EXPECTED_ACTIVE_EMPLOYEES} aktywnych pracowników. Plik zawiera ${activeImported}. Wybierz „Aktualizuj i dodaj” dla częściowej zmiany albo popraw kompletny plik.`);
      }
      const result=await supabase.rpc("matrix_v2_import_preview_uat_v5",{p_payload:parsed,p_mode:mode});
      if(result.error)throw new Error(matrixV2ErrorMessage(result.error.message));
      setPayload(parsed);setPreview(result.data as MatrixImportPreview);
    }catch(error){setLocalError(error instanceof Error?error.message:"Nie udało się odczytać pliku Excel.");}
    finally{setBusy(false);}
  }
  async function applyImport(){
    if(!payload||!preview?.valid||!supabase)return;
    const impact=mode==="REPLACE"?` Zostanie zarchiwizowanych ${preview.summary.employeesToArchive??0} aktywnych pracowników nieobecnych w pliku.`:" Pozostali pracownicy nie zostaną zmienieni.";
    if(!window.confirm(`Zapisać atomowo ${preview.summary.total} wierszy w wersji roboczej Matrixa?${impact}`))return;
    setBusy(true);
    const result=await supabase.rpc("matrix_v2_import_apply_uat_v5",{p_payload:payload,p_mode:mode});
    setBusy(false);
    if(result.error){fail(matrixV2ErrorMessage(result.error.message));return;}
    const archived=Number((result.data as {archivedEmployees?:number})?.archivedEmployees??0);
    notify(`Import zakończony: zapisano ${Number((result.data as {appliedRows?:number})?.appliedRows??preview.summary.total)} wierszy${archived?`, zarchiwizowano ${archived} nieobecnych pracowników`:""}.`);
    close();await reload();
  }
  return <><button className="drawer-scrim top" onClick={close}/><aside className="drawer matrix-v2-drawer top">
    <div className="drawer-head"><div><p className="eyebrow">MATRIX • IMPORT ZBIORCZY</p><h2>Import z pliku Excel</h2></div><button className="icon-button" onClick={close}><X/></button></div>
    <div className="drawer-content">
      <p className="matrix-v2-form-hint">Import modyfikuje tylko wersję roboczą {data.matrixVersion.name}. Najpierw wykonujemy walidację; przy zapisie jeden błędny wiersz cofa całą operację.</p>
      <div className="matrix-import-trust"><ShieldCheck/><span><strong>Bez wymyślonych wartości</strong><small>Puste pola nie są uzupełniane na podstawie nazw ani kodów. Brak wymaganej pory zmiany, scenariusza, operacji lub rodzaju przypisania zatrzyma import i wskaże wiersz do poprawy.</small></span></div>
      <button className="secondary-button full" type="button" onClick={()=>void downloadMatrixTemplate(data)}><Download/> Pobierz bieżącą bazę Matrixa do Excel</button>
      <fieldset className="matrix-import-mode"><legend>Jak zastosować plik?</legend><button type="button" className={mode==="UPDATE"?"active":""} onClick={()=>{setMode("UPDATE");setPreview(null);}}><strong>Aktualizuj i dodaj</strong><small>Zmienia tylko osoby z pliku. Pozostałych nie dotyka.</small></button><button type="button" className={mode==="REPLACE"?"active danger":"danger"} onClick={()=>{setMode("REPLACE");setPreview(null);}}><strong>Zastąp aktywną bazę</strong><small>Osoby nieobecne w pliku zostaną automatycznie zarchiwizowane w wersji roboczej.</small></button></fieldset>
      <label>Plik .xlsx lub .xls<input type="file" accept=".xlsx,.xls" onChange={event=>{setFile(event.target.files?.[0]??null);setPayload(null);setPreview(null);setLocalError("");}}/></label>
      <button className="primary-button full" disabled={!file||busy} onClick={()=>void inspect()}><Upload/> {busy?"Sprawdzam…":"Sprawdź plik i pokaż podgląd"}</button>
      {localError&&<div className="solver-v2-notice warning"><AlertTriangle/>{localError}</div>}
      {preview&&<section className="matrix-import-preview">
        <h3>{preview.valid?"Plik gotowy do zapisu":"Plik wymaga poprawy"}</h3>
        <p>{preview.summary.total} wierszy: {preview.summary.employees} pracowników, {preview.summary.employeeDuties??0} kompetencji pracowników, {preview.summary.shifts} zmian, {preview.summary.staffingRules} reguł obsady i {preview.summary.roleDuties} obowiązków ról.</p>
        <p className="matrix-v2-form-hint">Źródło: {payload?._sourceLayout==="APPS_SCRIPT_BASE"?"starszy układ Apps Script":"szablon GRAFIK PRO"}. Tryb zastąpienia jest dostępny wyłącznie dla kompletnej bazy {EXPECTED_ACTIVE_EMPLOYEES} aktywnych pracowników.</p>
        <div className="matrix-import-impact"><span><small>Aktualizowani</small><b>{preview.summary.employeesToUpdate??0}</b></span><span><small>Nowi</small><b>{preview.summary.employeesToCreate??0}</b></span><span className={mode==="REPLACE"&&Number(preview.summary.employeesToArchive??0)>0?"warning":""}><small>Archiwizowani</small><b>{preview.summary.employeesToArchive??0}</b></span></div>
        {mode==="REPLACE"&&Boolean(preview.employeesToArchive?.length)&&<details className="matrix-import-archive-list" open><summary>Sprawdź osoby przeznaczone do archiwizacji ({preview.employeesToArchive?.length})</summary><ul>{preview.employeesToArchive?.map(item=><li key={item.employeeId}><span><b>{item.employeeName}</b><small>{item.employeeNo}{item.email?` • ${item.email}`:""}</small></span><em>{item.reason==="DUPLICATE_IDENTITY"?"duplikat tej samej osoby":"brak w pliku"}</em></li>)}</ul></details>}
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
  const [contractType,setContractType]=useState(employee?.contractType??"ZLECENIE");
  const employmentContract=["UMOWA_O_PRACE","CZESC_ETATU"].includes(contractType);
  const [workTimePolicy,setWorkTimePolicy]=useState<"CONTRACT_DEFAULT"|"CUSTOM">(employee?.workTimePolicy??"CONTRACT_DEFAULT");
  const enforceIndividualLimits=employmentContract||workTimePolicy==="CUSTOM";
  const minutesAsHours=(value:number|undefined,fallback:number)=>Number(value??fallback)/60;
  async function submit(form:HTMLFormElement){
    try{
      const employmentStart=formText(form,"employmentStart");
      const employmentEnd=formText(form,"employmentEnd");
      if(employmentStart&&(employmentStart<dateHorizon(-50)||employmentStart>dateHorizon(2)))throw new Error("Data rozpoczęcia zatrudnienia jest poza dozwolonym zakresem.");
      if(employmentEnd&&employmentEnd>dateHorizon(10))throw new Error("Data zakończenia zatrudnienia jest zbyt odległa.");
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
        contractType,employmentFraction:formText(form,"employmentFraction")||"1",
        workTimePolicy:employmentContract?"CONTRACT_DEFAULT":workTimePolicy,
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
      <div className="matrix-contract-card">
        <label>Forma współpracy<select name="contractType" value={contractType} onChange={event=>setContractType(event.target.value as NonNullable<MatrixV2Employee["contractType"]>)}><option value="ZLECENIE">Umowa zlecenie</option><option value="B2B">B2B</option><option value="UMOWA_O_PRACE">Umowa o pracę</option><option value="CZESC_ETATU">Umowa o pracę — część etatu</option><option value="INNE">Inna</option></select></label>
        {employmentContract?<><label>Wymiar etatu<input name="employmentFraction" type="number" min="0.01" max="1" step="0.01" defaultValue={employee?.employmentFraction??(contractType==="CZESC_ETATU"?.5:1)}/></label><p>Silnik stosuje limity pracownicze zapisane poniżej oraz twarde zasady bezpieczeństwa.</p></>:<><input type="hidden" name="employmentFraction" value="1"/><p><strong>Elastyczna współpraca.</strong> Domyślnie silnik nie narzuca nominału etatu, 40 godzin tygodniowo, 11 godzin odpoczynku ani maksymalnej liczby dni z rzędu. Obowiązuje zadeklarowana dostępność, brak nakładania zmian, kwalifikacje i twarde niedostępności.</p><label className="check-label"><input type="checkbox" checked={workTimePolicy==="CUSTOM"} onChange={event=>setWorkTimePolicy(event.target.checked?"CUSTOM":"CONTRACT_DEFAULT")}/> Zastosuj indywidualnie uzgodnione limity jako twarde reguły</label></>}
      </div>
      <label>Rola podstawowa<select name="primaryRoleId" required defaultValue={employee?.primaryRoleId??""}><option value="" disabled>Wybierz rolę</option>{roles.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
      <fieldset className="matrix-v2-scopes"><legend>Zwykłe lokale pracy</legend><p className="matrix-v2-form-hint">Wszystkie zaznaczone lokale są równorzędne i mieszczą się w normalnym limicie pracownika.</p>{locations.map(item=><label key={item.id}><input type="checkbox" name="locationIds" value={item.id} defaultChecked={selectedLocations.has(item.id)}/>{item.name}</label>)}</fieldset>
      <div className="form-row"><label>Zatrudniony od<input name="employmentStart" type="date" min={dateHorizon(-50)} max={dateHorizon(2)} defaultValue={employee?.employmentStart??""}/><small>Do 50 lat wstecz lub 2 lata naprzód.</small></label><label>Zatrudniony do<input name="employmentEnd" type="date" min={employee?.employmentStart??dateHorizon(-50)} max={dateHorizon(10)} defaultValue={employee?.employmentEnd??""}/></label></div>
      <h3>{employmentContract?"Czas pracy i limity umowy":"Ustalenia ewidencyjne"}</h3>
      {!employmentContract&&<p className="matrix-v2-form-hint">Poniższe wartości służą do raportowania i kosztów. Nie są automatycznie traktowane jako kodeksowe blokady zleceniobiorcy lub B2B.</p>}
      <div className="form-row"><label>{employmentContract?"Nominał miesięczny":"Planowana liczba godzin"} (godz.)<input name="nominalHours" type="number" min="0" max="744" step="0.25" required defaultValue={minutesAsHours(employee?.nominalMonthlyMinutes,employmentContract?10080:0)}/></label><label>{employmentContract?"Limit miesięczny":"Pułap uzgodniony"} (godz.)<input name="maximumMonthlyHours" type="number" min="0" max="744" step="0.25" required defaultValue={minutesAsHours(employee?.maximumMonthlyMinutes,employmentContract?12600:0)}/></label></div>
      {enforceIndividualLimits?<><div className="form-row"><label>Limit tygodniowy (godz.)<input name="maximumWeeklyHours" type="number" min="0" max="168" step="0.25" required defaultValue={minutesAsHours(employee?.maximumWeeklyMinutes,employmentContract?2400:0)}/></label><label>Maks. kolejnych dni<input name="maximumConsecutiveDays" type="number" min="1" max="31" required defaultValue={employee?.maximumConsecutiveDays??(employmentContract?6:31)}/></label></div><label>Minimalny odpoczynek (godz.)<input name="minimumRestHours" type="number" min="0" max="48" step="0.25" defaultValue={employee?.minimumRestMinutes===null||employee?.minimumRestMinutes===undefined?"":minutesAsHours(employee.minimumRestMinutes,employmentContract?660:0)}/><small>{employmentContract?"Puste pole oznacza użycie domyślnej reguły dla umów pracowniczych.":"Ta wartość stanie się twardą regułą tylko dlatego, że zaznaczono indywidualne limity."}</small></label></>:<><input type="hidden" name="maximumWeeklyHours" value="0"/><input type="hidden" name="maximumConsecutiveDays" value="31"/><input type="hidden" name="minimumRestHours" value="0"/></>}
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
  const [staffingRoleId,setStaffingRoleId]=useState(String(item?.role_id??data.roles.find(role=>role.active)?.id??""));
  const [staffingScenarioId,setStaffingScenarioId]=useState(String(item?.scenario_id??data.scenarios.find(scenario=>scenario.active&&scenario.is_default)?.id??data.scenarios.find(scenario=>scenario.active)?.id??""));
  const [staffingDutyId,setStaffingDutyId]=useState(String(item?.duty_id??""));
  const staffingScenario=data.scenarios.find(scenario=>scenario.id===staffingScenarioId);
  const baseStaffingScenario=!staffingScenario?.parent_scenario_id;
  useEffect(()=>{
    if(kind==="STAFFING_RULE"&&!item?.id&&baseStaffingScenario&&operation!=="SET")setOperation("SET");
  },[baseStaffingScenario,item?.id,kind,operation,setOperation]);
  if (["ROLE","LOCATION","DUTY","STRATEGY"].includes(kind)) return <>
    <NameAndCode item={item}/>
    {kind === "LOCATION" && <label>Strefa czasowa<input name="timezone" required list="matrix-location-timezones" defaultValue={String(item?.timezone ?? "")}/><datalist id="matrix-location-timezones"><option value="Europe/Warsaw"/><option value="Europe/London"/><option value="Europe/Berlin"/><option value="UTC"/></datalist><small>Wybierz lub wpisz strefę IANA; wartość nie jest ustawiana automatycznie.</small></label>}
    {kind === "DUTY" && <label>Opis<textarea name="description" defaultValue={String(item?.description ?? "")}/></label>}
    {kind === "STRATEGY" && <><label>Opis wariantu<textarea name="description" defaultValue={String(item?.description ?? "")}/></label><input type="hidden" name="solverCode" value="CP_SAT"/></>}
    {(kind === "ROLE" || kind === "DUTY") && <label>Kolor<input name="color" type="color" defaultValue={String(item?.color ?? (kind === "ROLE" ? "#7257d8" : "#4a8d78"))}/></label>}
    {kind==="DUTY"?<DutyState item={item}/>:<CommonState item={item}/>}
  </>;
  if (kind === "SHIFT") return <>
    <label>Lokal<select name="locationId" required defaultValue={String(item?.location_id ?? "")}>{data.locations.filter(x=>x.active).map(location=><option value={location.id} key={location.id}>{location.name}</option>)}</select></label>
    <NameAndCode item={item}/>
    <div className="matrix-v2-form-hint"><strong>To jest niezależna zmiana.</strong> Klasyfikacja rano/środek/wieczór zostanie wyliczona automatycznie z godziny rozpoczęcia wyłącznie na potrzeby preferencji.</div>
    <div className="form-row"><label>Od (24 h)<input name="startsAt" type="text" inputMode="numeric" required pattern="(?:[01][0-9]|2[0-3]):[0-5][0-9]" placeholder="10:00" defaultValue={time(String(item?.starts_at ?? "10:00"))}/><small>Wpisz godzinę i minuty, np. 10:30.</small></label><label>Do (24 h)<input name="endsAt" type="text" inputMode="numeric" required pattern="(?:[01][0-9]|2[0-3]):[0-5][0-9]" placeholder="18:00" defaultValue={time(String(item?.ends_at ?? "18:00"))}/><small>Wpisz godzinę i minuty, np. 18:45.</small></label></div>
    <label className="check-label"><input name="endsNextDay" type="checkbox" defaultChecked={Boolean(item?.ends_next_day)}/> Kończy się następnego dnia</label>
    <DaySelector selected={(item?.day_mask as number[] | undefined) ?? WEEKDAYS.map(day=>day.value)}/>
    <CommonState item={item}/>
  </>;
  if (kind === "ROLE_DUTY") return <>
    {item?.id&&<><input type="hidden" name="roleId" value={String(item.role_id)}/><input type="hidden" name="dutyId" value={String(item.duty_id)}/></>}
    <label>Rola<select name="roleId" required disabled={Boolean(item?.id)} defaultValue={String(item?.role_id ?? "")}>{data.roles.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Obowiązek<select name="dutyId" required disabled={Boolean(item?.id)} defaultValue={String(item?.duty_id ?? "")}>{data.duties.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    <label>Znaczenie<select name="assignmentMode" defaultValue={String(item?.assignment_mode ?? "OPTIONAL")}><option value="REQUIRED">Wymagany</option><option value="OPTIONAL">Opcjonalny</option><option value="EXTRA">Dodatkowy</option></select></label>
    <label>Minimalna liczba na zmianie<input name="minimumCount" type="number" min="0" defaultValue={Number(item?.minimum_count ?? 0)}/><small>Dla obowiązku wymaganego minimum musi wynosić co najmniej 1.</small></label>
    <p className="matrix-v2-form-hint">Konkretną zmianę i wymaganą liczbę osób ustawiasz niżej w tej samej sekcji „Zmiany i obsada”.</p>
    <ActiveToggle item={item}/>
  </>;
  if (kind === "EMPLOYEE_ROLE") return <>
    <EmployeeContextField data={data} employeeId={String(item?.employee_id??"")}/>
    <label>Rola<select name="roleId" required disabled={Boolean(item?.id)} defaultValue={String(item?.role_id ?? "")}>{data.roles.filter(x=>x.active||x.id===item?.role_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    {item?.id&&<input type="hidden" name="roleId" value={String(item.role_id)}/>}
    <div className="form-row"><label>Ważna od<input name="validFrom" type="date" defaultValue={String(item?.valid_from??"")}/></label><label>Ważna do<input name="validTo" type="date" defaultValue={String(item?.valid_to??"")}/></label></div>
    <label className="check-label"><input name="isPrimary" type="checkbox" defaultChecked={Boolean(item?.is_primary)}/> Rola podstawowa</label>
    <label className="check-label"><input name="canLead" type="checkbox" defaultChecked={Boolean(item?.can_lead)}/> Może prowadzić zespół</label>
    <ActiveToggle item={item}/>
  </>;
  if (kind === "EMPLOYEE_LOCATION") return <>
    <EmployeeContextField data={data} employeeId={String(item?.employee_id??"")}/>
    <label>Lokal<select name="locationId" required disabled={Boolean(item?.id)} defaultValue={String(item?.location_id ?? "")}>{data.locations.filter(x=>x.active||x.id===item?.location_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label>
    {item?.id&&<input type="hidden" name="locationId" value={String(item.location_id)}/>}
    <div className="form-row"><label>Ważny od<input name="validFrom" type="date" defaultValue={String(item?.valid_from??"")}/></label><label>Ważny do<input name="validTo" type="date" defaultValue={String(item?.valid_to??"")}/></label></div>
    <label className="check-label"><input name="standardAllowed" type="checkbox" defaultChecked={Boolean(item?.standard_allowed)}/> Może pracować standardowo</label>
    <label className="check-label"><input name="overtimeAllowed" type="checkbox" defaultChecked={Boolean(item?.overtime_allowed)}/> Może pracować w nadgodzinach</label>
    <ActiveToggle item={item}/>
  </>;
  if (kind === "EMPLOYEE_DUTY") return <>
    <EmployeeContextField data={data} employeeId={String(item?.employee_id??"")}/>
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
    <label>Scenariusz<select name="scenarioId" required disabled={Boolean(item?.id)} value={staffingScenarioId} onChange={event=>setStaffingScenarioId(event.target.value)}>{data.scenarios.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select><small>{baseStaffingScenario?"Scenariusz bazowy ustala docelową liczbę osób.":`Ten scenariusz dziedziczy po „${itemName(data.scenarios,staffingScenario?.parent_scenario_id)}” i może zmienić bazową obsadę.`}</small></label>
    {item?.id
      ?<div className="matrix-v2-selection-summary"><small>Zmiana</small><strong>{itemName(data.shiftTemplates,String(item.shift_template_id))}</strong><span>{itemName(data.locations,data.shiftTemplates.find(shift=>shift.id===item.shift_template_id)?.location_id??"")}</span></div>
      :<ShiftTemplateMultiPicker data={data} initialLocationId={String(item?.location_id??"")} initialSelectedIds={item?.shift_template_id?[String(item.shift_template_id)]:[]}/>}
    <div className="form-row"><label>Rola<select name="roleId" required disabled={Boolean(item?.id)} value={staffingRoleId} onChange={event=>setStaffingRoleId(event.target.value)}>{data.roles.filter(x=>x.active).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select></label><label>Obowiązek lub kompetencja<select name="dutyId" disabled={Boolean(item?.id)} value={staffingDutyId} onChange={event=>setStaffingDutyId(event.target.value)}><option value="">Bez dodatkowego wymogu</option>{data.duties.filter(x=>x.active||x.id===item?.duty_id).map(x=><option value={x.id} key={x.id}>{x.name}</option>)}</select><small>Jeżeli wybierzesz obowiązek, zapis atomowo połączy go z rolą. Nic nie zostanie cicho pominięte.</small></label></div>
    {baseStaffingScenario
      ?<label>Wymagana liczba osób<input name="countValue" type="number" min="1" step="1" required defaultValue={Number(item?.count_value??1)}/><small>Co najmniej jedna osoba na każdej wybranej zmianie.</small></label>
      :<OperationSelector operation={operation} setOperation={setOperation} currency={currency} staffing baseStaffingScenario={false} item={item}/>}
    <ActiveToggle item={item}/>
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
    <DaySelector selected={(item?.day_mask as number[] | undefined) ?? WEEKDAYS.map(day=>day.value)}/><div className="form-row"><label>Godziny płatnego okna od (24 h)<input name="localStart" type="text" inputMode="numeric" pattern="(?:[01][0-9]|2[0-3]):[0-5][0-9]" placeholder="22:00" disabled={payMethod.includes("THRESHOLD")} defaultValue={time(String(item?.local_start ?? "")) === "—" ? "" : time(String(item?.local_start))}/></label><label>Godziny płatnego okna do (24 h)<input name="localEnd" type="text" inputMode="numeric" pattern="(?:[01][0-9]|2[0-3]):[0-5][0-9]" placeholder="06:00" disabled={payMethod.includes("THRESHOLD")} defaultValue={time(String(item?.local_end ?? "")) === "—" ? "" : time(String(item?.local_end))}/></label></div><p className="matrix-v2-form-hint">Dla dodatku godzinowego, procentowego lub mnożnika naliczane są wyłącznie minuty rzeczywiście przecinające to okno. Reguły progowe nie łączą się z oknem godzinowym.</p>
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
    <label>Minimalny odpoczynek (min)<input name="scenarioMinimumRestMinutes" type="number" min="0" step="1" defaultValue={optionalInput(overrides.minimumRestMinutes)}/></label>
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
  return <details className="matrix-v2-advanced-settings"><summary>Zaawansowane parametry obliczeń — zwykle nie zmieniaj</summary>
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
  </details>;
}

function NameAndCode({item}:{item?:Record<string,unknown>}) { return <><label>Nazwa<input name="name" required maxLength={160} defaultValue={String(item?.name ?? "")}/></label><label>Identyfikator konfiguracji<input name="code" maxLength={80} defaultValue={String(item?.code ?? "")} placeholder="Utworzy się automatycznie z nazwy"/><small>Stabilny identyfikator używany przy imporcie i integracjach.</small></label></>; }
function EmployeeContextField({data,employeeId}:{data:MatrixV2Workspace;employeeId:string}){
  const employee=data.employees.find(item=>item.id===employeeId);
  if(employee)return <><div className="matrix-v2-selection-summary"><small>Pracownik</small><strong>{employee.firstName} {employee.lastName}</strong><span>{employee.employeeNo}</span></div><input type="hidden" name="employeeId" value={employeeId}/></>;
  return <div className="matrix-v2-validation warning"><AlertTriangle/><span><strong>Najpierw wybierz pracownika w sekcji „Pracownicy i umowy”</strong><small>Role, lokale i kompetencje dodaje się z karty konkretnej osoby — bez przewijania długiej listy pracowników.</small></span></div>;
}
function CommonState({item}:{item?:Record<string,unknown>}) { return <><input name="sortOrder" type="hidden" value={Number(item?.sort_order ?? 0)}/><label className="check-label"><input name="active" type="checkbox" defaultChecked={item?.active === undefined ? true : Boolean(item.active)}/> Element aktywny</label><small className="matrix-v2-form-hint">Kolejność wyświetlania jest zarządzana automatycznie przez system.</small></>; }
function DutyState({item}:{item?:Record<string,unknown>}) { return <><input name="sortOrder" type="hidden" value={Number(item?.sort_order ?? 0)}/><label className="check-label"><input name="active" type="checkbox" defaultChecked={item?.active === undefined ? true : Boolean(item.active)}/> Obowiązek aktywny</label><small className="matrix-v2-form-hint">Odznaczenie bezpiecznie archiwizuje obowiązek. Przed zapisem system pokaże wszystkie aktywne zależności; historia nie zostanie usunięta.</small></>; }
function ActiveToggle({item}:{item?:Record<string,unknown>}) { return <label className="check-label"><input name="active" type="checkbox" defaultChecked={item?.active === undefined ? true : Boolean(item.active)}/> Reguła aktywna</label>; }
function DaySelector({selected}:{selected:number[]}) { return <fieldset className="matrix-v2-days"><legend>Dni tygodnia</legend>{WEEKDAYS.map(day=><label key={day.value}><input type="checkbox" name="days" value={day.value} defaultChecked={selected.includes(day.value)}/>{day.label}</label>)}</fieldset>; }
function ScopeSelector({title,name,items,selected}:{title:string;name:string;items:{id:string;name:string;active:boolean}[];selected:string[]}) { return <fieldset className="matrix-v2-scopes"><legend>{title}</legend>{items.filter(x=>x.active||selected.includes(x.id)).map(x=><label key={x.id}><input type="checkbox" name={name} value={x.id} defaultChecked={selected.includes(x.id)}/>{x.name}{!x.active?" (wyłączony)":""}</label>)}</fieldset>; }
function ShiftTemplateMultiPicker({data,initialLocationId,initialSelectedIds=[]}:{data:MatrixV2Workspace;initialLocationId:string;initialSelectedIds?:string[]}){
  const [selected,setSelected]=useState<string[]>(initialSelectedIds);
  const locations=[...data.locations.filter(location=>location.active)].sort((left,right)=>{
    if(left.id===initialLocationId)return -1;
    if(right.id===initialLocationId)return 1;
    return left.sort_order-right.sort_order||left.name.localeCompare(right.name,"pl");
  });
  const activeShifts=data.shiftTemplates.filter(shift=>shift.active);
  const toggle=(id:string,checked:boolean)=>setSelected(current=>checked
    ?current.includes(id)?current:[...current,id]
    :current.filter(value=>value!==id));
  const toggleLocation=(ids:string[],checked:boolean)=>setSelected(current=>checked
    ?[...new Set([...current,...ids])]
    :current.filter(value=>!ids.includes(value)));
  return <fieldset className="matrix-v2-shift-picker"><legend>Zmiany objęte wymaganiem</legend>
    <div className="matrix-v2-shift-picker-head"><span><strong>{selected.length?plural(selected.length,"wybrana zmiana","wybrane zmiany","wybranych zmian"):"Nie wybrano jeszcze zmian"}</strong><small>Możesz zastosować jedną regułę do wielu zmian i lokali jednocześnie.</small></span>{selected.length>0&&<button type="button" className="secondary-button" onClick={()=>setSelected([])}>Wyczyść wybór</button>}</div>
    <div className="matrix-v2-shift-picker-locations">{locations.map(location=>{
      const shifts=activeShifts.filter(shift=>shift.location_id===location.id);
      if(!shifts.length)return null;
      const allSelected=shifts.every(shift=>selected.includes(shift.id));
      return <details key={location.id} open={location.id===initialLocationId||locations.length<=2}>
        <summary><span><MapPin/><b>{location.name}</b><small>{shifts.filter(shift=>selected.includes(shift.id)).length} z {shifts.length} wybranych</small></span></summary>
        <div className="matrix-v2-shift-picker-list"><label className="select-location"><input type="checkbox" checked={allSelected} onChange={event=>toggleLocation(shifts.map(shift=>shift.id),event.target.checked)}/><span><b>Wszystkie zmiany w tym lokalu</b><small>Zaznacz lub odznacz cały lokal jednym kliknięciem.</small></span></label>{shifts.map(shift=><label key={shift.id}><input type="checkbox" name="shiftTemplateIds" value={shift.id} checked={selected.includes(shift.id)} onChange={event=>toggle(shift.id,event.target.checked)}/><span><b>{shift.name}</b><small>{time(shift.starts_at)}–{time(shift.ends_at)}{shift.ends_next_day?" • następny dzień":""} • {shiftPeriodLabel(shift.shift_period)}</small></span></label>)}</div>
      </details>;
    })}</div>
  </fieldset>;
}
function StaffingOperationSelector({operation,setOperation,item,baseScenario=false}:{operation:string;setOperation:(value:string)=>void;item?:Record<string,unknown>;baseScenario?:boolean}){
  const choices=baseScenario?[{
    value:"SET",title:"Ustal wymaganą liczbę osób",description:"Podaj docelową liczbę osób tej roli na każdej wybranej zmianie.",
  }]:[
    {value:"SET",title:"Wymagaj łącznie",description:"Ustal końcową liczbę osób tej roli na każdej wybranej zmianie."},
    {value:"ADD",title:"Dodaj ponad bazę",description:"W scenariuszu dziedziczącym zwiększ bazowe wymaganie o podaną liczbę osób."},
    {value:"REMOVE",title:"Wyłącz to wymaganie",description:"W tym scenariuszu usuń odziedziczone wymaganie dla wskazanej roli."},
    ...(operation==="MULTIPLY"?[{value:"MULTIPLY",title:"Zachowaj mnożnik",description:"Starsze ustawienie zaawansowane. Możesz je pozostawić albo zastąpić jasną regułą powyżej."}]:[]),
  ];
  return <fieldset className="matrix-v2-operation-picker"><legend>Co ma zrobić ta reguła?</legend><div>{choices.map(choice=><label key={choice.value} className={operation===choice.value?"selected":""}><input type="radio" name="operation" value={choice.value} checked={operation===choice.value} onChange={()=>setOperation(choice.value)}/><span><b>{choice.title}</b><small>{choice.description}</small></span></label>)}</div>{["SET","ADD"].includes(operation)&&<label className="matrix-v2-operation-value">{operation==="SET"?"Łączna liczba wymaganych osób":"Ile osób dodać ponad bazę"}<input name="countValue" type="number" min="0" step="1" required defaultValue={Number(item?.count_value??0)}/></label>}{operation==="MULTIPLY"&&<label className="matrix-v2-operation-value">Nowa wartość procentowa<input name="multiplierPercent" type="number" min="0" step="0.01" required defaultValue={Number(item?.multiplier_basis_points??10000)/100}/><small>100% = bez zmiany, 150% = półtora raza więcej.</small></label>}</fieldset>;
}
function OperationSelector({operation,setOperation,currency,item,staffing=false,baseStaffingScenario=false}:{operation:string;setOperation:(value:string)=>void;currency:string;item?:Record<string,unknown>;staffing?:boolean;baseStaffingScenario?:boolean}) {
  if(staffing)return <StaffingOperationSelector operation={operation} setOperation={setOperation} item={item} baseScenario={baseStaffingScenario}/>;
  const choices=[
    {value:"SET",title:"Ustal budżet",description:"Wpisana kwota staje się budżetem dla wybranego zakresu."},
    {value:"ADD",title:"Zmień budżet o kwotę",description:"Dodaj albo odejmij kwotę od budżetu odziedziczonego ze scenariusza bazowego."},
    {value:"MULTIPLY",title:"Zmień budżet procentowo",description:"Przelicz budżet bazowy, np. 110% oznacza wzrost o 10%."},
    {value:"REMOVE",title:"Nie stosuj limitu",description:"Usuń odziedziczony limit budżetu dla tego zakresu."},
  ];
  return <fieldset className="matrix-v2-operation-picker"><legend>Jak ma działać budżet w tym scenariuszu?</legend><div>{choices.map(choice=><label key={choice.value} className={operation===choice.value?"selected":""}><input type="radio" name="operation" value={choice.value} checked={operation===choice.value} onChange={()=>setOperation(choice.value)}/><span><b>{choice.title}</b><small>{choice.description}</small></span></label>)}</div>{["SET","ADD"].includes(operation)&&<label className="matrix-v2-operation-value">{operation==="SET"?`Kwota budżetu (${currency})`:`Zmiana kwoty (${currency})`}<input name="amount" type="number" min={operation==="SET"?"0":undefined} step="0.01" required defaultValue={minorToInput(item?.amount_minor)}/></label>}{operation==="MULTIPLY"&&<label className="matrix-v2-operation-value">Budżet po zmianie (%)<input name="multiplierPercent" type="number" min="0" step="0.01" required defaultValue={Number(item?.multiplier_basis_points ?? 10000)/100}/><small>100% = bez zmiany, 150% = o połowę więcej.</small></label>}</fieldset>;
}
function PayValueFields({method,item,currency}:{method:string;item?:Record<string,unknown>;currency:string}) { if(method==="FIXED_PER_SHIFT")return <label>Kwota za zmianę ({currency})<input name="amount" type="number" min="0" step="0.01" required defaultValue={minorToInput(item?.amount_minor)}/></label>;if(method==="PER_HOUR")return <label>Kwota za godzinę ({currency})<input name="hourly" type="number" min="0" step="0.01" required defaultValue={minorToInput(item?.rate_minor_per_hour)}/></label>;if(method==="PERCENT_BASE")return <label>Procent stawki podstawowej<input name="percent" type="number" min="0" step="0.01" required defaultValue={basisPercentToInput(item?.percent_basis_points)}/></label>;if(method==="MULTIPLIER")return <label>Mnożnik stawki<input name="multiplier" type="number" min="0" step="0.01" required defaultValue={basisMultiplierToInput(item?.multiplier_basis_points)}/></label>;return <div className="form-row"><label>Próg (minuty)<input name="thresholdMinutes" type="number" min="0" required defaultValue={Number(item?.threshold_minutes ?? 0)}/></label><label>Dodatek za godzinę po progu ({currency})<input name="hourly" type="number" min="0" step="0.01" required defaultValue={minorToInput(item?.rate_minor_per_hour)}/></label></div>; }

function drawerTitle(kind:MatrixV2SaveKind,editing:boolean){const labels:Record<MatrixV2SaveKind,string>={MATRIX_SETTINGS:"ustawienia Matrixa",ROLE:"rolę",LOCATION:"lokal",DUTY:"obowiązek",SHIFT:"szablon zmiany",ROLE_DUTY:"powiązanie roli i obowiązku",EMPLOYEE_ROLE:"rolę pracownika",EMPLOYEE_LOCATION:"lokal pracownika",EMPLOYEE_DUTY:"kompetencję pracownika",SCENARIO:"scenariusz",STAFFING_RULE:"regułę obsady",STRATEGY:"strategię wariantu",OBJECTIVE:"kryterium strategii",SCENARIO_STRATEGY:"wariant scenariusza",PAY_RULE:"dodatek płacowy",SCENARIO_PAY_RULE:"modyfikację dodatku",SCENARIO_BUDGET:"budżet scenariusza"};return `${editing?"Edytuj":"Dodaj"} ${labels[kind]}`;}
function formText(form:HTMLFormElement,name:string){return String(new FormData(form).get(name)??"").trim();}
function checked(form:HTMLFormElement,name:string){return new FormData(form).has(name);}
function optionalNumber(value:string,multiplier=1){if(value==="")return null;const number=Number(value);if(!Number.isFinite(number))throw new Error("Wpisz prawidłową wartość liczbową.");return Math.round(number*multiplier);}
function requiredNumber(value:string,multiplier=1){const result=optionalNumber(value,multiplier);if(result===null)throw new Error("Uzupełnij wszystkie wymagane wartości liczbowe.");return result;}
function codeFrom(value:string){return value.replace(/[Łł]/g,"L").normalize("NFD").replace(/[\u0300-\u036f]/g,"").toUpperCase().replace(/[^A-Z0-9]+/g,"_").replace(/^_+|_+$/g,"").slice(0,80);}
function minorToInput(value:unknown){return value===undefined||value===null?"":Number(value)/100;}
function maxDate(first:string,second?:string|null){return second&&second>first?second:first;}
function minDate(first:string,second?:string|null){return second&&second<first?second:first;}
function dateHorizon(years:number){const date=new Date();date.setUTCHours(12,0,0,0);date.setUTCFullYear(date.getUTCFullYear()+years);return date.toISOString().slice(0,10);}
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
  const minimumRest=optionalIntegerValue(formText(form,"scenarioMinimumRestMinutes"),"Minimalny odpoczynek",0);
  const missingAvailability=optionalBooleanValue(formText(form,"scenarioMissingAvailability"),"Brak wpisu dostępności");
  const requireOptimal=optionalBooleanValue(formText(form,"scenarioRequireOptimal"),"Wymaganie optimum");
  const randomSeed=optionalIntegerValue(formText(form,"scenarioRandomSeed"),"Ziarno losowe",0,2147483647);
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
  if(kind==="SHIFT"){const days=data.getAll("days").map(Number);if(!days.length)throw new Error("Wybierz co najmniej jeden dzień tygodnia.");const startsAt=parseTime24(formText(form,"startsAt"),"Godzina rozpoczęcia") as string;const endsAt=parseTime24(formText(form,"endsAt"),"Godzina zakończenia") as string;return{...common(),locationId:formText(form,"locationId"),shiftPeriod:automaticShiftPeriod(startsAt),startsAt,endsAt,endsNextDay:checked(form,"endsNextDay"),days};}
  if(kind==="ROLE_DUTY"){const assignmentMode=formText(form,"assignmentMode"),minimumCount=requiredNumber(formText(form,"minimumCount")||"0");if(assignmentMode==="REQUIRED"&&minimumCount<1)throw new Error("Obowiązek wymagany musi mieć minimalną liczbę co najmniej 1.");return{roleId:formText(form,"roleId"),dutyId:formText(form,"dutyId"),assignmentMode,minimumCount,shiftObligation:false,shiftPeriod:null,active:checked(form,"active")};}
  if(kind==="EMPLOYEE_ROLE"){const validFrom=formText(form,"validFrom"),validTo=formText(form,"validTo");if(validFrom&&validTo&&validTo<validFrom)throw new Error("Data końcowa nie może być wcześniejsza od początkowej.");return{employeeId:formText(form,"employeeId"),roleId:formText(form,"roleId"),isPrimary:checked(form,"isPrimary"),canLead:checked(form,"canLead"),active:checked(form,"active"),validFrom:validFrom||null,validTo:validTo||null};}
  if(kind==="EMPLOYEE_LOCATION"){const validFrom=formText(form,"validFrom"),validTo=formText(form,"validTo");if(validFrom&&validTo&&validTo<validFrom)throw new Error("Data końcowa nie może być wcześniejsza od początkowej.");if(!checked(form,"standardAllowed")&&!checked(form,"overtimeAllowed"))throw new Error("Wybierz zwykły limit lub dopuszczenie nadgodzin.");return{employeeId:formText(form,"employeeId"),locationId:formText(form,"locationId"),standardAllowed:checked(form,"standardAllowed"),overtimeAllowed:checked(form,"overtimeAllowed"),homeLocation:false,active:checked(form,"active"),validFrom:validFrom||null,validTo:validTo||null};}
  if(kind==="EMPLOYEE_DUTY"){const validFrom=formText(form,"validFrom"),validTo=formText(form,"validTo");if(validFrom&&validTo&&validTo<validFrom)throw new Error("Data końcowa nie może być wcześniejsza od początkowej.");return{employeeId:formText(form,"employeeId"),dutyId:formText(form,"dutyId"),roleId:formText(form,"roleId")||null,locationId:formText(form,"locationId")||null,active:checked(form,"active"),validFrom:validFrom||null,validTo:validTo||null};}
  if(kind==="SCENARIO"){const validFrom=formText(form,"validFrom"),validTo=formText(form,"validTo");if(validFrom&&validTo&&validTo<validFrom)throw new Error("Data zakończenia scenariusza nie może być wcześniejsza od daty rozpoczęcia.");return{...common(),description:formText(form,"description"),parentScenarioId:formText(form,"parentScenarioId")||null,color:formText(form,"color"),isDefault:checked(form,"isDefault"),validFrom:validFrom||null,validTo:validTo||null,settingsOverrides:scenarioSettingsOverridesFromForm(form)};}
  if(kind==="STAFFING_RULE"){
    const shiftTemplateIds=item?.id?[]:data.getAll("shiftTemplateIds").map(String).filter(Boolean);
    if(!item?.id&&!shiftTemplateIds.length)throw new Error("Wybierz co najmniej jedną zmianę objętą wymaganiem.");
    const scenarioId=formText(form,"scenarioId"),roleId=formText(form,"roleId");
    if(!scenarioId||!roleId)throw new Error("Wybierz scenariusz i rolę.");
    const countValue=["SET","ADD"].includes(operation)?requiredNumber(formText(form,"countValue")):null;
    if(operation==="SET"&&countValue!==null&&countValue<1)throw new Error("Wymagana liczba osób musi wynosić co najmniej 1.");
    return{scenarioId,shiftTemplateId:formText(form,"shiftTemplateId"),shiftTemplateIds,roleId,dutyId:formText(form,"dutyId")||null,operation,countValue,multiplierBasisPoints:operation==="MULTIPLY"?requiredNumber(formText(form,"multiplierPercent"),100):null,active:checked(form,"active"),sourceMetadata:item?.source_metadata??{}};
  }
  if(kind==="OBJECTIVE")return{strategyId:formText(form,"strategyId"),tier:requiredNumber(formText(form,"tier")),metricCode:formText(form,"metricCode"),direction:formText(form,"direction"),weight:requiredNumber(formText(form,"weight")),tolerance:requiredNumber(formText(form,"tolerance")),sortOrder:requiredNumber(formText(form,"sortOrder")||String(item?.sort_order??0)),parameters:item?.parameters??{},active:checked(form,"active")};
  if(kind==="SCENARIO_STRATEGY"){const strategyId=formText(form,"strategyId");if(!strategyId)throw new Error("Wybierz strategię wariantu.");return{scenarioId:formText(form,"scenarioId"),strategyId,sortOrder:requiredNumber(formText(form,"sortOrder")||String(item?.sort_order??0)),active:checked(form,"active"),objectiveOverrides:objectiveOverridesFromForm(form,workspace,strategyId),solverOverrides:solverOverridesFromForm(form)};}
  if(kind==="PAY_RULE"){const days=data.getAll("days").map(Number);if(!days.length)throw new Error("Wybierz co najmniej jeden dzień tygodnia.");const localStart=parseTime24(formText(form,"localStart"),"Początek płatnego okna",true),localEnd=parseTime24(formText(form,"localEnd"),"Koniec płatnego okna",true);if((localStart===null)!==(localEnd===null))throw new Error("Uzupełnij obie godziny płatnego okna albo pozostaw obie puste.");const payload:Record<string,unknown>={...common(),description:formText(form,"description"),calculationMethod:payMethod,currency,priority:requiredNumber(formText(form,"priority")),stackingGroup:formText(form,"stackingGroup")||null,stackingMode:formText(form,"stackingMode"),days,localStart,localEnd,validFrom:formText(form,"validFrom")||null,validTo:formText(form,"validTo")||null,roleIds:data.getAll("roleIds"),dutyIds:data.getAll("dutyIds"),locationIds:data.getAll("locationIds"),shiftIds:data.getAll("shiftIds")};if(payMethod==="FIXED_PER_SHIFT")payload.amountMinor=requiredNumber(formText(form,"amount"),100);if(["PER_HOUR","SHIFT_DURATION_THRESHOLD_PER_HOUR","MONTHLY_THRESHOLD_PER_HOUR"].includes(payMethod))payload.rateMinorPerHour=requiredNumber(formText(form,"hourly"),100);if(payMethod==="PERCENT_BASE")payload.percentBasisPoints=requiredNumber(formText(form,"percent"),100);if(payMethod==="MULTIPLIER")payload.multiplierBasisPoints=requiredNumber(formText(form,"multiplier"),10000);if(payMethod.includes("THRESHOLD"))payload.thresholdMinutes=requiredNumber(formText(form,"thresholdMinutes"));return payload;}
  if(kind==="SCENARIO_PAY_RULE")return{scenarioId:formText(form,"scenarioId"),payRuleId:formText(form,"payRuleId"),enabled:checked(form,"enabled"),amountMinor:optionalNumber(formText(form,"amount"),100),rateMinorPerHour:optionalNumber(formText(form,"hourly"),100),percentBasisPoints:optionalNumber(formText(form,"percent"),100),multiplierBasisPoints:optionalNumber(formText(form,"multiplier"),10000),formulaExpression:item?.formula_expression??null};
  const budgetMonth=formText(form,"budgetMonth");return{scenarioId:formText(form,"scenarioId"),budgetMonth:budgetMonth?`${budgetMonth}-01`:null,locationId:formText(form,"locationId")||null,roleId:formText(form,"roleId")||null,dutyId:formText(form,"dutyId")||null,operation,amountMinor:["SET","ADD"].includes(operation)?requiredNumber(formText(form,"amount"),100):null,multiplierBasisPoints:operation==="MULTIPLY"?requiredNumber(formText(form,"multiplierPercent"),100):null,currency,hardLimit:checked(form,"hardLimit"),warningPercent:requiredNumber(formText(form,"warningPercent")),sourceMetadata:item?.source_metadata??{}};
}
