"use client";

import { AlertTriangle, BarChart3, CircleDollarSign, Clock3, Filter, Scale, Users } from "lucide-react";
import { useMemo, useState } from "react";

import type { MatrixV2Workspace } from "@/lib/matrix-v2";
import type { OperationalAssignment, OperationalWorkspace } from "@/lib/solver-v2";

type Option = { id: string; name: string };
type EmployeeLoad = {
  id: string;
  employeeNo: string;
  name: string;
  roleId: string;
  roleName: string;
  minutes: number;
  nominalMinutes: number;
  cost: number;
  shifts: number;
  locations: Set<string>;
};

function money(value: number, currency: string) {
  return new Intl.NumberFormat("pl-PL", { style: "currency", currency: currency || "PLN", maximumFractionDigits: 0 }).format(value);
}

function hours(minutes: number) {
  const rounded = Math.round(minutes / 6) / 10;
  return `${new Intl.NumberFormat("pl-PL", { maximumFractionDigits: 1 }).format(rounded)} h`;
}

function assignmentDuration(assignment: OperationalAssignment) {
  return Math.max(0, Math.round((new Date(assignment.ends_at).getTime() - new Date(assignment.starts_at).getTime()) / 60_000));
}

function median(values: number[]) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

export function AnalyticsDashboard({
  data,
  matrix,
  currency,
}: {
  data: OperationalWorkspace;
  matrix: MatrixV2Workspace | null;
  currency: string;
}) {
  const [locationId, setLocationId] = useState("");
  const [roleId, setRoleId] = useState("");
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState<"MOST" | "LEAST" | "DEVIATION">("DEVIATION");

  const roles = useMemo<Option[]>(() => [...new Map(data.assignments.map(item => [item.role_id ?? item.role, {
    id: item.role_id ?? item.role,
    name: item.role_name ?? item.role,
  }])).values()].sort((a, b) => a.name.localeCompare(b.name, "pl-PL")), [data.assignments]);
  const locations = useMemo<Option[]>(() => [...new Map(data.assignments.map(item => [item.location_id ?? item.location, {
    id: item.location_id ?? item.location,
    name: item.location_name ?? item.location,
  }])).values()].sort((a, b) => a.name.localeCompare(b.name, "pl-PL")), [data.assignments]);

  const assignments = useMemo(() => data.assignments.filter(item =>
    (!roleId || (item.role_id ?? item.role) === roleId)
    && (!locationId || (item.location_id ?? item.location) === locationId)
  ), [data.assignments, locationId, roleId]);

  const employeeRows = useMemo(() => {
    const result = new Map<string, EmployeeLoad>();
    for (const assignment of assignments) {
      const row = result.get(assignment.employee_id) ?? {
        id: assignment.employee_id,
        employeeNo: assignment.employee_no,
        name: assignment.name,
        roleId: assignment.role_id ?? assignment.role,
        roleName: assignment.role_name ?? assignment.role,
        minutes: 0,
        nominalMinutes: assignment.nominal_minutes,
        cost: 0,
        shifts: 0,
        locations: new Set<string>(),
      };
      row.minutes += assignmentDuration(assignment);
      row.cost += Number(assignment.cost || 0);
      row.shifts += 1;
      row.locations.add(assignment.location_name ?? assignment.location);
      result.set(row.id, row);
    }
    const normalizedQuery = query.trim().toLocaleLowerCase("pl-PL");
    return [...result.values()]
      .filter(row => !normalizedQuery || `${row.name} ${row.employeeNo} ${row.roleName} ${[...row.locations].join(" ")}`.toLocaleLowerCase("pl-PL").includes(normalizedQuery))
      .sort((a, b) => sort === "MOST" ? b.minutes - a.minutes : sort === "LEAST" ? a.minutes - b.minutes : Math.abs(b.minutes - b.nominalMinutes) - Math.abs(a.minutes - a.nominalMinutes));
  }, [assignments, query, sort]);

  const totalMinutes = assignments.reduce((sum, item) => sum + assignmentDuration(item), 0);
  const totalCost = assignments.reduce((sum, item) => sum + Number(item.cost || 0), 0);
  const missingSeats = data.issues.filter(item => item.issue_type === "SHORTAGE" || item.issue_type === "CAPABILITY_MISSING")
    .reduce((sum, item) => sum + Math.max(0, Number(item.required_count || 0) - Number(item.assigned_count || 0)), 0);
  const coverage = assignments.length + missingSeats ? Math.round(assignments.length / (assignments.length + missingSeats) * 1000) / 10 : 0;
  const budget = Number(data.budget.amount || 0);
  const budgetUsage = budget ? Math.round(totalCost / budget * 100) : 0;
  const minuteValues = employeeRows.map(item => item.minutes);
  const minimum = minuteValues.length ? Math.min(...minuteValues) : 0;
  const maximum = minuteValues.length ? Math.max(...minuteValues) : 0;
  const medianMinutes = median(minuteValues);
  const overNominal = employeeRows.filter(item => item.nominalMinutes > 0 && item.minutes > item.nominalMinutes).length;
  const underNominal = employeeRows.filter(item => item.nominalMinutes > 0 && item.minutes < item.nominalMinutes).length;

  const byRole = useMemo(() => roles.map(role => {
    const rows = assignments.filter(item => (item.role_id ?? item.role) === role.id);
    const minutes = rows.reduce((sum, item) => sum + assignmentDuration(item), 0);
    return { ...role, count: rows.length, minutes, cost: rows.reduce((sum, item) => sum + Number(item.cost || 0), 0) };
  }).sort((a, b) => b.minutes - a.minutes), [assignments, roles]);
  const byLocation = useMemo(() => locations.map(location => {
    const rows = assignments.filter(item => (item.location_id ?? item.location) === location.id);
    const minutes = rows.reduce((sum, item) => sum + assignmentDuration(item), 0);
    return { ...location, count: rows.length, minutes, cost: rows.reduce((sum, item) => sum + Number(item.cost || 0), 0) };
  }).sort((a, b) => b.minutes - a.minutes), [assignments, locations]);

  const structuralShortages = useMemo(() => {
    const grouped = new Map<string, { label: string; occurrences: number; seats: number }>();
    for (const issue of data.issues.filter(item => item.issue_type === "SHORTAGE" || item.issue_type === "CAPABILITY_MISSING")) {
      const shift = data.shifts.find(item => item.id === issue.shift_id);
      const roleName = roles.find(item => item.id === (issue.role_id ?? issue.role))?.name ?? issue.role ?? "Nieokreślona rola";
      const key = `${roleName}:${shift?.location_name ?? shift?.location_code ?? "firma"}:${shift?.shift_name ?? shift?.shift_code ?? "zmiana"}`;
      const row = grouped.get(key) ?? { label: key.replaceAll(":", " • "), occurrences: 0, seats: 0 };
      row.occurrences += 1;
      row.seats += Math.max(0, Number(issue.required_count || 0) - Number(issue.assigned_count || 0));
      grouped.set(key, row);
    }
    return [...grouped.values()].sort((a, b) => b.occurrences - a.occurrences || b.seats - a.seats).slice(0, 6);
  }, [data.issues, data.shifts, roles]);

  if (!data.plan) return <section className="analytics-empty"><BarChart3 /><h2>Analizy pojawią się po opublikowaniu grafiku</h2><p>Panel nie tworzy danych przykładowych. Pokaże koszty, godziny, pokrycie i obciążenie z rzeczywiście opublikowanego grafiku.</p></section>;

  const maxRoleMinutes = Math.max(...byRole.map(item => item.minutes), 1);
  const maxLocationMinutes = Math.max(...byLocation.map(item => item.minutes), 1);
  return <section className="analytics-dashboard">
    <header className="analytics-head"><div><p className="eyebrow">ANALIZY • OPUBLIKOWANY GRAFIK</p><h2>Centrum decyzji</h2><p>{data.plan.name} • wyniki pochodzą wyłącznie z obowiązującego grafiku.</p></div><div className="analytics-context"><strong>{data.plan.optimization_mode}</strong><small>{data.plan.scenario_code}</small></div></header>
    <div className="analytics-filters"><Filter /><label>Lokal<select value={locationId} onChange={event => setLocationId(event.target.value)}><option value="">Wszystkie lokale</option>{locations.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><label>Rola<select value={roleId} onChange={event => setRoleId(event.target.value)}><option value="">Wszystkie role</option>{roles.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><button className="secondary-button" onClick={() => { setLocationId(""); setRoleId(""); setQuery(""); }}>Wyczyść filtry</button></div>
    <div className="analytics-kpis">
      <article><Users /><span><small>Pokrycie wymaganej obsady</small><strong>{coverage}%</strong><em>{missingSeats ? `${missingSeats} nieobsadzonych miejsc` : "Pełna wymagana obsada"}</em></span></article>
      <article><CircleDollarSign /><span><small>Koszt grafiku</small><strong>{money(totalCost, currency)}</strong><em>{budget ? `${budgetUsage}% budżetu • ${money(budget, currency)}` : "Brak budżetu do porównania"}</em></span></article>
      <article><Clock3 /><span><small>Zaplanowana praca</small><strong>{hours(totalMinutes)}</strong><em>{assignments.length} przydziałów</em></span></article>
      <article><Scale /><span><small>Różnica godzin min–max</small><strong>{hours(maximum - minimum)}</strong><em>{hours(minimum)} – {hours(maximum)}</em></span></article>
    </div>
    <div className="analytics-grid">
      <section className="analytics-panel workload-panel"><header><div><h3>Rozkład pracy zespołu</h3><p>Cel godzinowy jest punktem odniesienia, twardy limit pozostaje blokadą.</p></div><span>Mediana {hours(medianMinutes)}</span></header><div className="workload-summary"><span><b>{employeeRows.length}</b><small>osób w analizie</small></span><span><b>{underNominal}</b><small>poniżej celu</small></span><span><b>{overNominal}</b><small>powyżej celu</small></span></div><div className="workload-tools"><label>Znajdź pracownika<input value={query} onChange={event => setQuery(event.target.value)} placeholder="Imię, numer, rola lub lokal" /></label><label>Sortowanie<select value={sort} onChange={event => setSort(event.target.value as typeof sort)}><option value="DEVIATION">Największe odchylenie od celu</option><option value="LEAST">Najmniej godzin</option><option value="MOST">Najwięcej godzin</option></select></label></div><div className="workload-table">{employeeRows.map(row => {
        const difference = row.nominalMinutes > 0 ? row.minutes - row.nominalMinutes : null;
        const ratio = row.nominalMinutes > 0 ? Math.min(140, row.minutes / row.nominalMinutes * 100) : Math.min(100, maximum ? row.minutes / maximum * 100 : 0);
        return <article key={row.id}><div><strong>{row.name}</strong><small>{row.employeeNo} • {row.roleName} • {[...row.locations].join(", ")}</small></div><span><b>{hours(row.minutes)}</b><small>{row.shifts} zmian</small></span><span className={difference === null ? "neutral" : difference > 0 ? "over" : difference < 0 ? "under" : "match"}><b>{difference === null ? "Brak celu" : `${difference > 0 ? "+" : ""}${hours(difference)}`}</b><small>{row.nominalMinutes > 0 ? `cel ${hours(row.nominalMinutes)}` : "uzupełnij cel godzinowy"}</small></span><div className="load-track"><i style={{ width: `${ratio}%` }} /></div></article>;
      })}{!employeeRows.length && <p className="analytics-empty-inline">Brak osób spełniających wybrane filtry.</p>}</div></section>
      <section className="analytics-panel"><header><div><h3>Praca według roli</h3><p>Godziny, przydziały i koszt.</p></div></header><div className="analytics-bars">{byRole.map(item => <article key={item.id}><div><b>{item.name}</b><strong>{hours(item.minutes)}</strong></div><i><span style={{ width: `${item.minutes / maxRoleMinutes * 100}%` }} /></i><small>{item.count} przydziałów • {money(item.cost, currency)}</small></article>)}</div></section>
      <section className="analytics-panel"><header><div><h3>Praca według lokalu</h3><p>Porównanie wykorzystania lokalizacji.</p></div></header><div className="analytics-bars locations">{byLocation.map(item => <article key={item.id}><div><b>{item.name}</b><strong>{hours(item.minutes)}</strong></div><i><span style={{ width: `${item.minutes / maxLocationMinutes * 100}%` }} /></i><small>{item.count} przydziałów • {money(item.cost, currency)}</small></article>)}</div></section>
      <section className="analytics-panel shortage-panel"><header><div><h3>Powtarzalne braki zasobów</h3><p>Diagnoza wzorców, a nie tylko pojedynczych wakatów.</p></div><AlertTriangle /></header>{structuralShortages.length ? <div>{structuralShortages.map(item => <article key={item.label}><span><b>{item.label}</b><small>{item.occurrences} dni/zmian • {item.seats} miejsc do pokrycia</small></span><strong>{item.occurrences >= 3 ? "Brak strukturalny" : "Sprawdź obsadę"}</strong></article>)}</div> : <p className="analytics-success">Brak powtarzalnych nieobsadzonych wzorców w wybranym zakresie.</p>}</section>
    </div>
    {matrix && <footer className="analytics-source"><BarChart3 /><span><b>Jedno źródło danych</b><small>Role, lokale, cele godzinowe i budżety są odczytywane z konfiguracji firmy v{matrix.matrixVersion.version}; przydziały i koszty z opublikowanego grafiku.</small></span></footer>}
  </section>;
}
