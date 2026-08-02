"use client";

import { AlertTriangle, CalendarDays, CircleDollarSign, MapPin, Users } from "lucide-react";
import type { SolverWorkspace } from "@/lib/solver-v2";

type Props = {
  workspace: SolverWorkspace;
  timezone: string;
  published?: boolean;
};

function money(value: number | null, currency: string) {
  if (value === null) return "Bez limitu";
  try {
    return new Intl.NumberFormat("pl-PL", {
      style: "currency",
      currency,
      maximumFractionDigits: 2,
    }).format(value / 100);
  } catch {
    return `${new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 2 }).format(value / 100)} ${currency}`;
  }
}

function dateLabel(value: string) {
  const date = new Date(`${value.slice(0, 10)}T12:00:00Z`);
  if (Number.isNaN(date.getTime())) return "Termin zmiany";
  return new Intl.DateTimeFormat("pl-PL", {
    weekday: "long",
    day: "numeric",
    month: "long",
    timeZone: "UTC",
  }).format(date);
}

function monthLabel(value: string) {
  const date = new Date(`${value.slice(0, 7)}-01T12:00:00Z`);
  if (Number.isNaN(date.getTime())) return "Wybrany miesiąc";
  return new Intl.DateTimeFormat("pl-PL", { month: "long", year: "numeric", timeZone: "UTC" }).format(date);
}

function timeLabel(value: string, timezone: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("pl-PL", {
    hour: "2-digit", minute: "2-digit", timeZone: timezone,
  }).format(date);
}

function timestampLabel(value: string | null | undefined, timezone: string) {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat("pl-PL", {
    day: "numeric",
    month: "long",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: timezone,
  }).format(date);
}

function publicationStatus(value?: string) {
  if (value === "PUBLISHED") return "Opublikowany";
  if (value === "ARCHIVED") return "Zarchiwizowany";
  return "Gotowy do publikacji";
}

export function SolverV2Workspace({ workspace, timezone, published = false }: Props) {
  const shiftsByDate = new Map<string, typeof workspace.shifts>();
  for (const shift of workspace.shifts) {
    shiftsByDate.set(shift.date, [...(shiftsByDate.get(shift.date) ?? []), shift]);
  }
  const dates = [...shiftsByDate.entries()].sort(([left], [right]) => left.localeCompare(right));
  const assignmentCount = workspace.variants.reduce((sum, variant) => sum + variant.assignmentCount, 0);
  const unfilledCount = workspace.variants.reduce((sum, variant) => sum + variant.unfilledCount, 0);
  const publishedAt = timestampLabel(workspace.context.publishedAt, timezone);

  return <section className={`solver-workspace ${published ? "published" : ""}`}>
    <div className="solver-workspace-head">
      <span>
        <small>{published ? publicationStatus(workspace.context.status) : "Podgląd wybranego wariantu"}</small>
        <strong>{workspace.context.name}</strong>
        <em>{monthLabel(workspace.context.month)} • {workspace.context.scenario.name}</em>
      </span>
      {published && <b>{publicationStatus(workspace.context.status)}</b>}
    </div>

    {publishedAt && <div className="solver-workspace-published-at">Opublikowano {publishedAt}</div>}

    <div className="solver-workspace-summary">
      <span><Users/><small>Przydziały</small><strong>{assignmentCount}</strong></span>
      <span><AlertTriangle/><small>Braki</small><strong>{unfilledCount}</strong></span>
      <span><CalendarDays/><small>Dni ze zmianami</small><strong>{dates.length}</strong></span>
    </div>

    {workspace.finance && <div className="solver-workspace-finance">
      <div><CircleDollarSign/><span><small>Koszt podstawowy</small><strong>{money(workspace.finance.baseCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Dodatki z Matrixa</small><strong>{money(workspace.finance.additionsCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Łączny koszt</small><strong>{money(workspace.finance.totalCostMinor, workspace.finance.currency)}</strong></span></div>
      <div><span><small>Budżet scenariusza</small><strong>{money(workspace.finance.budgetMinor, workspace.finance.currency)}</strong></span></div>
    </div>}

    <div className="solver-workspace-calendar">
      <h4>Obsada według dni</h4>
      {dates.length === 0 && <div className="solver-workspace-empty">Ten wariant nie zawiera jeszcze zmian do pokazania.</div>}
      {dates.map(([date, shifts], dateIndex) => {
        const people = shifts.reduce((sum, shift) => sum + shift.assignments.length, 0);
        return <details key={date} open={dateIndex === 0}>
          <summary>
            <span><CalendarDays/><strong>{dateLabel(date)}</strong></span>
            <small>{shifts.length} {shifts.length === 1 ? "zmiana" : "zmian"} • {people} przydziałów</small>
          </summary>
          <div className="solver-workspace-shifts">
            {shifts.map(shift => <article key={`${shift.slotGroupKey}:${shift.location.id}:${shift.shiftTemplate.id}`}>
              <header>
                <span><MapPin/><strong>{shift.location.name}</strong></span>
                <span>{timeLabel(shift.startsAt,shift.location.timezone ?? timezone)}–{timeLabel(shift.endsAt,shift.location.timezone ?? timezone)}</span>
              </header>
              <h5>{shift.shiftTemplate.name}</h5>
              {shift.assignments.length === 0
                ? <p className="solver-workspace-empty">Brak przydzielonych osób</p>
                : <div className="solver-workspace-people">
                  {shift.assignments.map(assignment => <div key={assignment.id}>
                    <span>
                      <strong>{[assignment.employee.firstName, assignment.employee.lastName].filter(Boolean).join(" ") || "Pracownik"}</strong>
                      <small>{assignment.role.name}</small>
                    </span>
                    <em>{assignment.duties.length
                      ? assignment.duties.map(duty => duty.name).join(", ")
                      : "Bez dodatkowych obowiązków"}</em>
                  </div>)}
                </div>}
            </article>)}
          </div>
        </details>;
      })}
    </div>

    <details className="solver-workspace-issues" open={workspace.issues.length > 0 && workspace.issues.length <= 8}>
      <summary>
        <span><AlertTriangle/><strong>Braki i uwagi</strong></span>
        <small>{workspace.issues.length}</small>
      </summary>
      {workspace.issues.length === 0
        ? <p>Nie zgłoszono braków ani uwag do tego wariantu.</p>
        : <div>
          {workspace.issues.map(issue => <article key={issue.id}>
            <strong>{issue.message}</strong>
            {(issue.role || issue.duty) && <small>
              {[issue.role?.name, issue.duty?.name].filter(Boolean).join(" • ")}
            </small>}
          </article>)}
        </div>}
    </details>
  </section>;
}
