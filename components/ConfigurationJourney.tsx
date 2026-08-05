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
} satisfies Record<SetupStepKey, typeof Building2>;

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
  compact = false,
}: {
  data: MatrixV2Workspace;
  month: string;
  onOpenStep: (section: SetupSection, step: SetupStepKey, focus?: SetupFocus) => void;
  onCreateSchedule: () => void;
  compact?: boolean;
}) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [serverReadiness, setServerReadiness] = useState<MatrixV2PublicationReadiness | null>(null);
  const [serverError, setServerError] = useState("");
  const [checking, setChecking] = useState(data.editable);
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
  }, [data.editable, month, signature, supabase, timezone]);

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

  return <section id={compact ? undefined : "configuration-step-readiness"} className={`configuration-journey ${compact ? "compact" : ""}`} aria-labelledby="configuration-journey-title">
    <header className="configuration-journey-head">
      <div>
        <p className="eyebrow">PROWADZONA KONFIGURACJA</p>
        <h2 id="configuration-journey-title">{journey.ready ? "Firma jest gotowa do planowania" : "Dokończ konfigurację firmy"}</h2>
        <p>System odczytuje rzeczywiste dane i zawsze wskazuje jeden następny krok. Możesz wrócić w dowolnym momencie.</p>
      </div>
      <div className={`configuration-progress ${journey.ready ? "ready" : ""}`} aria-label={`Ukończono ${journey.completed} z ${journey.total} etapów`}>
        <strong>{journey.percent}%</strong>
        <span><i style={{ width: `${journey.percent}%` }} /></span>
        <small>{journey.completed} z {journey.total} etapów</small>
      </div>
    </header>

    {next ? <div className="configuration-next-action">
      <span className="configuration-next-icon"><WandSparkles /></span>
      <div><small>NASTĘPNA NAJLEPSZA AKCJA</small><strong>{next.label}</strong><p>{next.description}</p></div>
      <button className="primary-button" onClick={() => onOpenStep(next.section, next.key)}>Przejdź dalej <ArrowRight /></button>
    </div> : <div className="configuration-next-action ready">
      <span className="configuration-next-icon"><CheckCircle2 /></span>
      <div><small>KONFIGURACJA GOTOWA</small><strong>Możesz przygotować grafik na {month}</strong><p>Kontekst miesiąca i opublikowanej konfiguracji zostanie zachowany.</p></div>
      <button className="primary-button" onClick={onCreateSchedule}>Utwórz grafik <ArrowRight /></button>
    </div>}

    <ol className="configuration-steps">
      {journey.steps.map((step, index) => {
        const Icon = stepIcons[step.key];
        return <li key={step.key} className={step.state}>
          <button type="button" onClick={() => onOpenStep(step.section, step.key)} aria-current={step.state === "current" ? "step" : undefined}>
            <span className="configuration-step-index">{step.complete ? <Check /> : checking && step.key === "readiness" ? <Loader2 className="spin" /> : <Icon />}</span>
            <span><small>KROK {index + 1}</small><strong>{step.label}</strong><p>{step.description}</p><em>{step.detail}</em></span>
            {step.complete ? <CheckCircle2 className="configuration-step-status" /> : <CircleDashed className="configuration-step-status" />}
          </button>
        </li>;
      })}
    </ol>

    {(serverError || journey.blockers.length > 0) && <div className="configuration-blockers">
      <div><AlertTriangle /><span><strong>{blockerTitle}</strong><small>{serverError ? "Odśwież dane i ponów kontrolę gotowości." : blockerHelp}</small></span></div>
      {journey.blockers.slice(0, 5).map(blocker => {
        const action = configurationBlockerAction(blocker, data, month);
        return <button type="button" key={`${blocker.code}:${blocker.employeeId ?? blocker.shiftTemplateId ?? blocker.message}`} onClick={() => onOpenStep(action.section, action.step, action.focus)}>
          <span><b>{action.title}</b><small>{action.message}</small><em>{action.actionLabel}</em></span><ArrowRight />
        </button>;
      })}
      {journey.blockers.length > 5 && <small className="configuration-blockers-more">Pokazano 5 z {journey.blockers.length} problemów. Po naprawieniu profilu lista odświeży się automatycznie.</small>}
    </div>}
  </section>;
}
