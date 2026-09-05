"use client";

import {
  AlertTriangle,
  ArrowRight,
  BriefcaseBusiness,
  Building2,
  CalendarClock,
  Check,
  CheckCircle2,
  CircleDashed,
  Loader2,
  RefreshCw,
  ShieldCheck,
  SlidersHorizontal,
  Users,
  WandSparkles,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import type { MatrixV2PublicationReadiness, MatrixV2Workspace } from "@/lib/matrix-v2";
import {
  configurationBlockerAction,
  configurationJourney,
  type SetupSection,
  type SetupFocus,
  type SetupStepKey,
} from "@/lib/product-journey";

const stepIcons = {
  company: Building2,
  roles: BriefcaseBusiness,
  shifts: CalendarClock,
  employees: Users,
  variants: SlidersHorizontal,
  readiness: ShieldCheck,
  publication: CheckCircle2,
} satisfies Record<SetupStepKey, typeof Building2>;

const stepGuidance: Record<SetupStepKey, { purpose: string; actions: string[]; result: string }> = {
  company: {
    purpose: "Ustalamy wspólne zasady firmy, zanim powstaną role, zmiany i grafiki.",
    actions: ["Sprawdź strefę czasową i walutę", "Dodaj wszystkie lokale, w których układasz grafik"],
    result: "Każda późniejsza zmiana i stawka będzie liczona w prawidłowym miejscu i czasie.",
  },
  roles: {
    purpose: "Role opisują stanowiska, a obowiązki tylko dodatkowe kwalifikacje potrzebne na wybranych zmianach.",
    actions: ["Dodaj stanowiska używane w firmie", "Przypisz obowiązek tylko tam, gdzie jest naprawdę wymagany"],
    result: "System nie będzie wymagał sztucznych obowiązków od każdej roli.",
  },
  shifts: {
    purpose: "Szablon zmiany łączy lokal, godziny, dni tygodnia i wymaganą liczbę osób.",
    actions: ["Dodaj godziny i dni każdej zmiany", "W tej samej karcie ustaw role i minimalną obsadę"],
    result: "Generator otrzyma kompletną informację, kogo i kiedy ma zaplanować.",
  },
  employees: {
    purpose: "Każda osoba potrzebuje roli, zwykłego lokalu pracy oraz danych umowy i stawki.",
    actions: ["Dodaj lub zaimportuj zespół", "Uzupełnij role, lokale, limity i stawki dla miesiąca grafiku"],
    result: "Profile będą gotowe do bezpiecznego użycia przez silnik i finanse.",
  },
  variants: {
    purpose: "Warianty pokazują różne decyzje biznesowe, a nie trzy kopie tego samego grafiku.",
    actions: ["Wybierz scenariusz bazowy", "Włącz strategie, które chcesz rzeczywiście porównywać"],
    result: "Lider zobaczy koszt, pokrycie i równomierność dla każdego podejścia.",
  },
  readiness: {
    purpose: "Ostatnia kontrola łączy wszystkie dane i wskazuje dokładne miejsce każdego problemu.",
    actions: ["Otwórz wskazany problem", "Po naprawie uruchom kontrolę ponownie"],
    result: "Dopiero pozytywny wynik odblokuje publikację konfiguracji i generator.",
  },
  publication: {
    purpose: "Generator czyta wyłącznie opublikowaną konfigurację właściwą dla wybranego miesiąca.",
    actions: ["Kliknij „Opublikuj konfigurację”", "Potwierdź datę obowiązywania i sprawdzoną wersję"],
    result: "Po ponownym odczycie aktywnej wersji aplikacja odblokuje tworzenie grafiku.",
  },
};

function localDate(timezone: string) {
  const parts = new Intl.DateTimeFormat("en", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  const value = Object.fromEntries(parts.map(part => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

export function ConfigurationJourney({
  data,
  month,
  onOpenStep,
  onCreateSchedule,
  onConfigurationChanged,
  compact = false,
}: {
  data: MatrixV2Workspace;
  month: string;
  onOpenStep: (section: SetupSection, step: SetupStepKey, focus?: SetupFocus) => void;
  onCreateSchedule: () => void;
  onConfigurationChanged?: () => Promise<void>;
  compact?: boolean;
}) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [serverReadiness, setServerReadiness] = useState<MatrixV2PublicationReadiness | null>(null);
  const [serverError, setServerError] = useState("");
  const [checking, setChecking] = useState(data.editable);
  const [checkRevision, setCheckRevision] = useState(0);
  const [showAllBlockers, setShowAllBlockers] = useState(false);
  const [deactivatingShiftId, setDeactivatingShiftId] = useState<string | null>(null);
  const timezone = String(data.matrixVersion.settings?.timezone ?? "Europe/Warsaw");
  const signature = JSON.stringify({
    version: data.matrixVersion,
    locations: data.locations.map(item => [item.id, item.active]),
    roles: data.roles.map(item => [item.id, item.active]),
    duties: data.duties.map(item => [item.id, item.active]),
    roleDuties: data.roleDuties.map(item => [item.id, item.role_id, item.duty_id, item.active]),
    shifts: data.shiftTemplates.map(item => [item.id, item.location_id, item.day_mask, item.active]),
    staffing: data.staffingRules.map(item => [item.id, item.scenario_id, item.shift_template_id, item.role_id, item.duty_id, item.operation, item.count_value, item.active]),
    scenarios: data.scenarios.map(item => [item.id, item.is_default, item.active]),
    strategies: data.strategies.map(item => [item.id, item.active]),
    scenarioStrategies: data.scenarioStrategies.map(item => [item.id, item.scenario_id, item.strategy_id, item.active]),
    employees: data.employees.map(item => [item.id, item.active]),
    employeeRoles: data.employeeRoles.map(item => [item.id, item.employee_id, item.role_id, item.active]),
    employeeLocations: data.employeeLocations.map(item => [item.id, item.employee_id, item.location_id, item.standard_allowed, item.active]),
    employeePayRates: data.employeePayRates.map(item => [item.id, item.employee_id, item.valid_from, item.valid_to, item.active]),
  });

  useEffect(() => {
    let alive = true;
    setServerError("");
    if (!supabase || !data.editable) {
      setServerReadiness(null);
      setChecking(false);
      return () => { alive = false; };
    }
    setServerReadiness(null);
    setChecking(true);
    void supabase.rpc("matrix_v2_publication_readiness_uat_v2", {
      p_effective_from: localDate(timezone),
      p_schedule_month: `${month}-01`,
    }).then(result => {
      if (!alive) return;
      setChecking(false);
      if (result.error) {
        setServerReadiness(null);
        setServerError("Nie udało się wykonać serwerowej kontroli gotowości.");
        return;
      }
      setServerReadiness(result.data as MatrixV2PublicationReadiness);
    });
    return () => { alive = false; };
  }, [checkRevision, data.editable, month, signature, supabase, timezone]);

  const journey = configurationJourney(data, month, serverReadiness);
  const next = journey.next;
  const payRateBlockers = journey.blockers.filter(blocker => blocker.code === "MISSING_PAY_RATE");
  const onlyPayRateBlockers = payRateBlockers.length === journey.blockers.length && payRateBlockers.length > 0;
  const blockerTitle = serverError
    || (onlyPayRateBlockers
      ? `${payRateBlockers.length} ${payRateBlockers.length === 1 ? "pracownik nie ma" : "pracowników nie ma"} stawki obejmującej cały miesiąc`
      : `${journey.blockers.length} problemów blokuje publikację`);
  const blockerHelp = onlyPayRateBlockers
    ? "Kliknij osobę. Otworzymy jej profil, przewiniemy do historii stawek i ustawimy kursor w formularzu."
    : "Kliknij problem, aby przejść bezpośrednio do miejsca naprawy.";
  const currentGuide = next ? stepGuidance[next.key] : null;
  const firstRun = data.employees.every(item => !item.active)
    || data.locations.every(item => !item.active)
    || data.shiftTemplates.every(item => !item.active);
  const visibleBlockers = showAllBlockers ? journey.blockers : journey.blockers.slice(0, 5);

  async function deactivateUnstaffedShift(shiftId: string) {
    const shift = data.shiftTemplates.find(item => item.id === shiftId);
    if (!supabase || !shift || !data.editable) return;
    if (!window.confirm(`Wyłączyć zmianę „${shift.name}”?\n\nNie będzie wymagała obsady ani trafiała do generatora. Historia pozostanie w wersji konfiguracji.`)) return;
    setDeactivatingShiftId(shiftId);
    const result = await supabase.rpc("matrix_v2_admin_save_alpha16", {
      p_kind: "SHIFT",
      p_id: shift.id,
      p_data: {
        code: shift.code,
        name: shift.name,
        locationId: shift.location_id,
        shiftPeriod: shift.shift_period,
        startsAt: shift.starts_at,
        endsAt: shift.ends_at,
        endsNextDay: shift.ends_next_day,
        days: shift.day_mask,
        sortOrder: shift.sort_order,
        color: shift.color,
        active: false,
      },
    });
    setDeactivatingShiftId(null);
    if (result.error) {
      setServerError("Nie udało się wyłączyć tej zmiany. Otwórz jej kartę i spróbuj ponownie.");
      return;
    }
    await onConfigurationChanged?.();
    setCheckRevision(value => value + 1);
  }

  return <section id={compact ? undefined : "configuration-step-readiness"} className={`configuration-journey ${compact ? "compact" : ""}`} aria-labelledby="configuration-journey-title">
    <header className="configuration-journey-head">
      <div>
        <p className="eyebrow">PROWADZONA KONFIGURACJA</p>
        <h2 id="configuration-journey-title">{journey.ready ? "Firma jest gotowa do planowania" : next?.key === "publication" ? "Opublikuj gotową konfigurację" : "Dokończ konfigurację firmy"}</h2>
        <p>System odczytuje rzeczywiste dane i zawsze wskazuje jeden następny krok. Możesz wrócić w dowolnym momencie.</p>
      </div>
      <div className={`configuration-progress ${journey.ready ? "ready" : ""}`} aria-label={`Ukończono ${journey.completed} z ${journey.total} etapów`}>
        <strong>{journey.percent}%</strong>
        <span><i style={{ width: `${journey.percent}%` }} /></span>
        <small>{journey.completed} z {journey.total} etapów</small>
      </div>
    </header>

    {firstRun && <div className="configuration-first-run">
      <WandSparkles />
      <span><small>PIERWSZE URUCHOMIENIE</small><strong>Przejdziemy od pustej firmy do pierwszego grafiku</strong><p>Nie musisz znać kolejności. Uzupełnij bieżący krok, a następny odblokuje się automatycznie. Możesz bezpiecznie wrócić do ukończonych etapów.</p></span>
    </div>}

    {next ? <div className="configuration-next-action">
      <span className="configuration-next-icon"><WandSparkles /></span>
      <div><small>NASTĘPNA NAJLEPSZA AKCJA</small><strong>{next.label}</strong><p>{next.description}</p></div>
      <button className="primary-button" onClick={() => onOpenStep(next.section, next.key)}>Przejdź dalej <ArrowRight /></button>
    </div> : <div className="configuration-next-action ready">
      <span className="configuration-next-icon"><CheckCircle2 /></span>
      <div><small>KONFIGURACJA GOTOWA</small><strong>Możesz przygotować grafik na {month}</strong><p>Kontekst miesiąca i opublikowanej konfiguracji zostanie zachowany.</p></div>
      <button className="primary-button" onClick={onCreateSchedule}>Utwórz grafik <ArrowRight /></button>
    </div>}

    {next && currentGuide && <section className="configuration-current-guide" aria-label={`Instrukcja kroku ${next.label}`}>
      <header><span><small>TERAZ ROBISZ</small><h3>{next.label}</h3><p>{currentGuide.purpose}</p></span><button className="primary-button" onClick={() => onOpenStep(next.section, next.key)}>Otwórz krok <ArrowRight /></button></header>
      <div><ol>{currentGuide.actions.map(action => <li key={action}>{action}</li>)}</ol><p><CheckCircle2 /><span><small>EFEKT TEGO KROKU</small>{currentGuide.result}</span></p></div>
    </section>}

    <ol className="configuration-steps">
      {journey.steps.map((step, index) => {
        const Icon = stepIcons[step.key];
        return <li key={step.key} className={step.state}>
          <button type="button" disabled={step.state === "blocked"} onClick={() => onOpenStep(step.section, step.key)} aria-current={step.state === "current" ? "step" : undefined}>
            <span className="configuration-step-index">{step.complete ? <Check /> : checking && step.key === "readiness" ? <Loader2 className="spin" /> : <Icon />}</span>
            <span><small>KROK {index + 1}</small><strong>{step.label}</strong><p>{step.description}</p><em>{step.detail}</em></span>
            {step.complete ? <CheckCircle2 className="configuration-step-status" /> : <CircleDashed className="configuration-step-status" />}
          </button>
        </li>;
      })}
    </ol>

    {(serverError || journey.blockers.length > 0) && <div className="configuration-blockers">
      <div><AlertTriangle /><span><strong>{blockerTitle}</strong><small>{serverError ? "Odśwież dane i ponów kontrolę gotowości." : blockerHelp}</small></span></div>
      {visibleBlockers.map(blocker => {
        const action = configurationBlockerAction(blocker, data, month);
        if (blocker.code === "SHIFT_BASE_STAFFING_REQUIRED" && blocker.shiftTemplateId) return <article className="configuration-shift-blocker" key={`${blocker.code}:${blocker.shiftTemplateId}`}>
          <span><b>{action.title}</b><small>{action.message}</small><em>Wybierz jedną akcję: uzupełnij obsadę albo wyłącz zmianę.</em></span>
          <div>
            <button type="button" className="primary-button" onClick={() => onOpenStep(action.section, action.step, action.focus)}>Uzupełnij obsadę <ArrowRight /></button>
            <button type="button" className="secondary-button" disabled={!data.editable || deactivatingShiftId === blocker.shiftTemplateId} title={data.editable ? "Wyłącz tę zmianę w wersji roboczej" : "Najpierw utwórz wersję roboczą konfiguracji"} onClick={() => void deactivateUnstaffedShift(blocker.shiftTemplateId!)}>{deactivatingShiftId === blocker.shiftTemplateId ? <Loader2 className="spin" /> : null} Wyłącz zmianę</button>
          </div>
        </article>;
        return <button type="button" key={`${blocker.code}:${blocker.employeeId ?? blocker.shiftTemplateId ?? blocker.message}`} onClick={() => onOpenStep(action.section, action.step, action.focus)}>
          <span><b>{action.title}</b><small>{action.message}</small><em>{action.actionLabel}</em></span><ArrowRight />
        </button>;
      })}
      {journey.blockers.length > 5 && <button type="button" className="configuration-blockers-toggle" onClick={() => setShowAllBlockers(value => !value)}>{showAllBlockers ? "Pokaż krótszą listę" : `Pokaż wszystkie problemy (${journey.blockers.length})`}</button>}
      <button type="button" className="configuration-readiness-retry" disabled={checking} onClick={() => setCheckRevision(value => value + 1)}><RefreshCw className={checking ? "spin" : ""} /> {checking ? "Sprawdzam dane…" : "Sprawdź gotowość ponownie"}</button>
    </div>}
  </section>;
}
