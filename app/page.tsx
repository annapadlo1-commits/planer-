"use client";

import {
  AlertTriangle,
  BarChart3,
  Bell,
  CalendarDays,
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  CircleDollarSign,
  Clock3,
  Download,
  Filter,
  Gauge,
  ListChecks,
  LogIn,
  LogOut,
  MapPin,
  Menu,
  Plus,
  RefreshCw,
  Search,
  Settings,
  ShieldCheck,
  Sparkles,
  Users,
  WandSparkles,
  Wifi,
  X,
} from "lucide-react";
import { useMemo, useState } from "react";
import {
  Area,
  AreaChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { useAppAuth } from "@/components/AppAuthProvider";

type Location = "KRUCZA" | "PAWILONY";
type ShiftKey = "RANO" | "ŚRODEK" | "WIECZÓR";
type NavKey =
  | "centrum"
  | "generator"
  | "kalendarz"
  | "zespol"
  | "budzet"
  | "analizy"
  | "czas"
  | "administracja";

type Drawer =
  | { kind: "shortage"; title: string; subtitle: string }
  | { kind: "event"; title: string; subtitle: string }
  | { kind: "shift"; title: string; subtitle: string }
  | { kind: "plan"; title: string; subtitle: string }
  | null;

type CalendarFocus = "LOKAL" | "ROLA" | "PRACOWNIK";

const monthDays = Array.from({ length: 35 }, (_, index) => {
  const day = index - 1;
  return day > 0 && day <= 31 ? day : null;
});

const calendarEvents = {
  8: { label: "Inwentaryzacja", tone: "violet", location: "PAWILONY" },
  11: { label: "Wesele • 120 os.", tone: "orange", location: "KRUCZA" },
  18: { label: "Sprzątanie generalne", tone: "teal", location: "KRUCZA" },
  24: { label: "Event firmowy", tone: "coral", location: "PAWILONY" },
} as const;

const days = [
  { dow: "Pon", day: 6, occupancy: { KRUCZA: 96, PAWILONY: 94 } },
  { dow: "Wt", day: 7, occupancy: { KRUCZA: 90, PAWILONY: 89 } },
  { dow: "Śr", day: 8, occupancy: { KRUCZA: 86, PAWILONY: 86 }, today: true },
  { dow: "Czw", day: 9, occupancy: { KRUCZA: 94, PAWILONY: 92 } },
  { dow: "Pt", day: 10, occupancy: { KRUCZA: 96, PAWILONY: 94 } },
  { dow: "Sob", day: 11, occupancy: { KRUCZA: 102, PAWILONY: 100 } },
  { dow: "Niedz", day: 12, occupancy: { KRUCZA: 78, PAWILONY: 75 } },
];

const people = [
  { initials: "AN", name: "Alicja Nowak", role: "Kelner", tone: "violet" },
  { initials: "MK", name: "Marek Kozłowski", role: "Barman + kierownik", tone: "amber" },
  { initials: "KP", name: "Karolina Pawlak", role: "Pizzabar", tone: "blue" },
  { initials: "ZS", name: "Zofia Sikora", role: "Pomoc", tone: "orange" },
  { initials: "MW", name: "Michał Wrona", role: "Kelner + host", tone: "green" },
  { initials: "ŁK", name: "Łukasz Król", role: "Barman", tone: "amber" },
  { initials: "AP", name: "Aleksandra Piotrowska", role: "Kelner + kierownik", tone: "orange" },
  { initials: "TN", name: "Tomasz Nowicki", role: "Prep", tone: "violet" },
  { initials: "KK", name: "Kinga Kaczmarek", role: "Barman", tone: "violet" },
  { initials: "AB", name: "Antoni Borkowski", role: "Pizzabar", tone: "amber" },
  { initials: "PS", name: "Patrycja Sobczak", role: "Barman + kierownik", tone: "violet" },
  { initials: "JM", name: "Jakub Maj", role: "Pomoc", tone: "violet" },
];

const navItems: { key: NavKey; label: string; icon: typeof Gauge }[] = [
  { key: "centrum", label: "Centrum dowodzenia", icon: Gauge },
  { key: "generator", label: "Generator grafiku", icon: WandSparkles },
  { key: "kalendarz", label: "Kalendarz operacyjny", icon: CalendarDays },
  { key: "zespol", label: "Zespół", icon: Users },
  { key: "budzet", label: "Budżet i koszty", icon: CircleDollarSign },
  { key: "analizy", label: "Analizy i prognozy", icon: BarChart3 },
  { key: "czas", label: "Rejestr czasu", icon: Clock3 },
  { key: "administracja", label: "Administracja", icon: Settings },
];

const chartData = [
  { day: "1 lip", plan: 86, actual: 84 },
  { day: "5 lip", plan: 89, actual: 91 },
  { day: "10 lip", plan: 94, actual: 92 },
  { day: "15 lip", plan: 91, actual: 88 },
  { day: "20 lip", plan: 96, actual: 93 },
  { day: "25 lip", plan: 95, actual: 97 },
  { day: "31 lip", plan: 98, actual: 96 },
];

function occupancyClass(value: number) {
  if (value < 80) return "critical";
  if (value < 90) return "warning";
  return "good";
}

function personFor(location: Location, shift: ShiftKey, dayIndex: number) {
  const base =
    location === "KRUCZA"
      ? shift === "RANO"
        ? 0
        : shift === "ŚRODEK"
          ? 2
          : 5
      : shift === "RANO"
        ? 8
        : shift === "ŚRODEK"
          ? 10
          : 9;
  return people[(base + dayIndex) % people.length];
}

function shiftTime(location: Location, shift: ShiftKey, dayIndex: number) {
  const weekend = dayIndex > 4;
  if (location === "KRUCZA") {
    if (shift === "RANO") return "10:00–17:00";
    if (shift === "ŚRODEK") return weekend ? "15:00–23:00" : "—";
    return weekend ? "17:00–03:00" : "17:00–01:00";
  }
  if (shift === "RANO") return weekend ? "12:00–19:00" : "10:00–17:00";
  if (shift === "ŚRODEK") return "—";
  return weekend ? "19:00–05:00" : "17:00–01:00";
}

function ManagerCalendar({
  onOpen,
  notify,
}: {
  onOpen: (drawer: Drawer) => void;
  notify: (message: string) => void;
}) {
  const [focus, setFocus] = useState<CalendarFocus>("LOKAL");
  const [role, setRole] = useState("Wszystkie role");
  const [location, setLocation] = useState("Oba lokale");
  const [selectedDay, setSelectedDay] = useState(11);

  return (
    <div className="content manager-calendar">
      <section className="calendar-toolbar">
        <div>
          <p className="eyebrow">WIDOK MENADŻERSKI</p>
          <h2>Lipiec 2026</h2>
          <p>Zmieniaj perspektywę, sprawdzaj obsadę i planuj wyjątki bez szukania po tabelach.</p>
        </div>
        <div className="toolbar-actions">
          <button className="secondary-button" onClick={() => notify("Eksport CSV został przygotowany dla aktualnego widoku")}>
            <Download size={16} /> Eksportuj
          </button>
          <button className="primary-button" onClick={() => onOpen({ kind: "event", title: "Nowy event / wyjątek dnia", subtitle: "Zdefiniuj wpływ na zmiany i obsadę" })}>
            <Plus size={17} /> Dodaj zdarzenie
          </button>
        </div>
      </section>

      <section className="calendar-controls">
        <div className="segmented">
          {(["LOKAL", "ROLA", "PRACOWNIK"] as CalendarFocus[]).map((item) => (
            <button key={item} className={focus === item ? "active" : ""} onClick={() => setFocus(item)}>
              {item === "LOKAL" ? "Lokal" : item === "ROLA" ? "Rola" : "Pracownik"}
            </button>
          ))}
        </div>
        <label>Lokal<select value={location} onChange={(e) => setLocation(e.target.value)}><option>Oba lokale</option><option>KRUCZA</option><option>PAWILONY</option></select></label>
        <label>Rola<select value={role} onChange={(e) => setRole(e.target.value)}><option>Wszystkie role</option><option>Kelner</option><option>Barman</option><option>Pizzabar</option><option>Prep</option><option>Pomoc</option><option>Host</option></select></label>
        {focus === "PRACOWNIK" && <label>Pracownik<select><option>Alicja Nowak</option><option>Marek Kozłowski</option><option>Karolina Pawlak</option></select></label>}
        <span className="control-summary"><Filter size={14} /> {location} • {role}</span>
      </section>

      <section className="month-layout">
        <div className="month-card">
          <div className="month-weekdays">{["Pon", "Wt", "Śr", "Czw", "Pt", "Sob", "Niedz"].map((day) => <span key={day}>{day}</span>)}</div>
          <div className="month-grid">
            {monthDays.map((day, index) => {
              const event = day ? calendarEvents[day as keyof typeof calendarEvents] : undefined;
              const staffing = day ? 76 + ((day * 7) % 25) : 0;
              return (
                <button key={index} disabled={!day} className={`month-day ${day === selectedDay ? "selected" : ""} ${staffing < 84 ? "has-risk" : ""}`} onClick={() => day && setSelectedDay(day)}>
                  {day && <>
                    <span className="day-number">{day}</span>
                    <span className={`staffing-chip ${staffing < 84 ? "risk" : ""}`}>{staffing}%</span>
                    <div className="mini-people">
                      {people.slice(day % 5, day % 5 + 4).map((person) => <span key={person.name} className={`avatar ${person.tone}`} title={person.name}>{person.initials}</span>)}
                      <b>+{day % 8 + 8}</b>
                    </div>
                    {event && <span className={`calendar-event ${event.tone}`}>{event.label}</span>}
                    <span className="day-locations"><i className="violet-dot" /> K <i className="amber-dot" /> P</span>
                  </>}
                </button>
              );
            })}
          </div>
        </div>

        <aside className="day-panel">
          <div className="day-panel-head">
            <div><p className="eyebrow">WYBRANY DZIEŃ</p><h3>{selectedDay} lipca 2026</h3><span>Sobota • oba lokale</span></div>
            <button className="icon-button" onClick={() => onOpen({ kind: "event", title: `${selectedDay} lipca — nowy wyjątek`, subtitle: "Event, zmiana godzin, zamknięcie lub dodatkowa zmiana" })}><Plus size={17} /></button>
          </div>
          <article className="day-event">
            <span className="status-icon amber"><CalendarDays size={19} /></span>
            <div><strong>Wesele — Sala Kryształowa</strong><small>KRUCZA • 18:00–02:00 • niepotwierdzone</small></div>
            <button onClick={() => onOpen({ kind: "event", title: "Wesele — Sala Kryształowa", subtitle: "Potrzebna weryfikacja od Michała Zielińskiego" })}><ChevronRight size={17} /></button>
          </article>
          <h4>Zmiany i obsada</h4>
          {[
            ["KRUCZA", "RANO 10:00–17:00", "18 / 18", "100%"],
            ["KRUCZA", "ŚRODEK 15:00–23:00", "3 / 3", "100%"],
            ["KRUCZA", "WIECZÓR 17:00–03:00", "18 / 21", "86%"],
            ["PAWILONY", "RANO 12:00–19:00", "2 / 2", "100%"],
            ["PAWILONY", "WIECZÓR 19:00–05:00", "4 / 4", "100%"],
          ].map((shift) => (
            <button className="day-shift" key={`${shift[0]}-${shift[1]}`} onClick={() => onOpen({ kind: "shift", title: `${shift[0]} • ${shift[1]}`, subtitle: `${selectedDay} lipca • obsada ${shift[3]}` })}>
              <span><strong>{shift[0]}</strong><small>{shift[1]}</small></span><em>{shift[2]}</em><b className={shift[3] === "86%" ? "risk" : ""}>{shift[3]}</b><ChevronRight size={16} />
            </button>
          ))}
          <button className="primary-button full" onClick={() => notify("Otwieram edycję operacyjną dnia z historią zmian")}>Edytuj plan dnia</button>
        </aside>
      </section>
    </div>
  );
}

const employeeShifts = [
  { date: "Pon, 6 lip", location: "KRUCZA", shift: "RANO", time: "10:00–17:00", role: "Kelner", hours: 7 },
  { date: "Wt, 7 lip", location: "KRUCZA", shift: "WIECZÓR", time: "17:00–01:00", role: "Kelner", hours: 8 },
  { date: "Czw, 9 lip", location: "KRUCZA", shift: "RANO", time: "10:00–17:00", role: "Kelner", hours: 7 },
  { date: "Pt, 10 lip", location: "KRUCZA", shift: "ŚRODEK", time: "15:00–23:00", role: "Host", hours: 8 },
  { date: "Sob, 11 lip", location: "KRUCZA", shift: "WIECZÓR", time: "17:00–03:00", role: "Kelner", hours: 10 },
  { date: "Pon, 13 lip", location: "KRUCZA", shift: "RANO", time: "10:00–17:00", role: "Kelner", hours: 7 },
];

function exportCsv(filename: string, rows: (string | number)[][]) {
  const csv = rows.map((row) => row.map((cell) => `"${String(cell).replaceAll('"', '""')}"`).join(";")).join("\n");
  const blob = new Blob([`\uFEFF${csv}`], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}

function EmployeeSchedule({ notify }: { notify: (message: string) => void }) {
  const total = employeeShifts.reduce((sum, item) => sum + item.hours, 0);
  return (
    <div className="content employee-view">
      <section className="employee-hero">
        <div className="employee-identity"><span className="avatar avatar-large violet">AN</span><div><p className="eyebrow">WIDOK PRACOWNIKA</p><h2>Alicja Nowak</h2><span>Kelner • KRUCZA • może pełnić funkcję HOST</span></div></div>
        <div className="employee-stats"><span><small>Zaplanowano</small><strong>{total} h</strong></span><span><small>Nominał miesiąca</small><strong>168 h</strong></span><span><small>Wykorzystanie</small><strong>28%</strong></span></div>
        <button className="secondary-button" onClick={() => {
          exportCsv("grafik-alicja-nowak-lipiec-2026.csv", [["Data", "Lokal", "Zmiana", "Godziny", "Rola", "Liczba godzin"], ...employeeShifts.map((item) => [item.date, item.location, item.shift, item.time, item.role, item.hours])]);
          notify("Wyeksportowano grafik Alicji Nowak");
        }}><Download size={16} /> Eksportuj grafik</button>
      </section>
      <section className="employee-layout">
        <article className="employee-schedule-card">
          <div className="card-header"><div><p className="eyebrow">LIPIEC 2026</p><h2>Moje zmiany</h2></div><span className="published-pill"><Check size={14} /> Grafik opublikowany</span></div>
          <div className="employee-shift-list">
            {employeeShifts.map((item, index) => (
              <button className="employee-shift-row" key={`${item.date}-${item.time}`} onClick={() => notify(`${item.date}: ${item.location}, ${item.time}`)}>
                <span className={`shift-symbol ${item.shift.toLowerCase()}`}>{item.shift === "RANO" ? "☀" : item.shift === "ŚRODEK" ? "◐" : "☾"}</span>
                <span><strong>{item.date}</strong><small>{item.location} • {item.role}</small></span>
                <span><strong>{item.time}</strong><small>{item.shift}</small></span>
                <em>{item.hours} h</em>
                {index === 4 && <b className="event-marker">EVENT</b>}
                <ChevronRight size={17} />
              </button>
            ))}
          </div>
        </article>
        <aside className="employee-side">
          <article className="action-card"><h3>Potrzebujesz zmiany?</h3><p>Zgłoś niedostępność, zaproponuj zamianę lub wyślij wniosek do menadżera.</p><button className="primary-button full" onClick={() => notify("Otwieram nowy wniosek o zmianę grafiku")}><Plus size={16} /> Nowy wniosek</button></article>
          <article className="action-card"><h3>Nadchodząca zmiana</h3><strong>Pon, 6 lip • 10:00</strong><p>KRUCZA • Kelner • zmiana poranna</p><span className="shift-countdown"><Clock3 size={16} /> za 3 dni</span></article>
          <article className="action-card"><h3>Podsumowanie</h3><div className="summary-lines"><span>Zmiany poranne <b>3</b></span><span>Zmiany wieczorne <b>2</b></span><span>Event / środek <b>1</b></span><span>Weekendowe <b>2</b></span></div></article>
        </aside>
      </section>
    </div>
  );
}

function AttendancePanel({ notify }: { notify: (message: string) => void }) {
  const [checkedIn, setCheckedIn] = useState(false);
  const [now, setNow] = useState("09:58");
  const history = [
    ["29.07.2026", "KRUCZA", "09:57", "17:04", "7 h 07 min", "Zgodne"],
    ["28.07.2026", "KRUCZA", "16:54", "01:08", "8 h 14 min", "Zgodne"],
    ["26.07.2026", "KRUCZA", "09:59", "17:02", "7 h 03 min", "Zgodne"],
    ["25.07.2026", "KRUCZA", "16:51", "03:12", "10 h 21 min", "Do weryfikacji"],
  ];
  return (
    <div className="content attendance-view">
      <section className="attendance-grid">
        <article className={`clock-card ${checkedIn ? "active" : ""}`}>
          <p className="eyebrow">REJESTRACJA CZASU</p><h2>{checkedIn ? "Zmiana rozpoczęta" : "Gotowa do rozpoczęcia"}</h2>
          <div className="live-clock">{now}<small>30 lipca 2026 • Europe/Warsaw</small></div>
          <div className="clock-location"><MapPin size={17} /><span><strong>KRUCZA</strong><small>Weryfikacja lokalizacji: poprawna</small></span><Check size={18} /></div>
          <button className={`clock-button ${checkedIn ? "checkout" : ""}`} onClick={() => {
            setCheckedIn(!checkedIn);
            setNow(checkedIn ? "17:06" : "10:01");
            notify(checkedIn ? "Zakończenie zmiany zapisane" : "Rozpoczęcie zmiany zapisane");
          }}>{checkedIn ? <><LogOut size={21} /> Zakończ zmianę</> : <><LogIn size={21} /> Rozpocznij zmianę</>}</button>
          <p className="verification-note"><ShieldCheck size={15} /> QR lokalu + konto pracownika + lokalizacja urządzenia. Zdjęcie nie jest wymagane.</p>
        </article>
        <article className="attendance-summary">
          <div><p className="eyebrow">DZISIAJ</p><h2>Plan a wykonanie</h2></div>
          <div className="attendance-timeline"><span className="done"><i /><b>10:00</b><small>Planowany start</small></span><span className={checkedIn ? "done" : ""}><i /><b>{checkedIn ? "10:01" : "—"}</b><small>Rzeczywisty start</small></span><span><i /><b>17:00</b><small>Planowany koniec</small></span></div>
          <div className="attendance-kpis"><span><small>Plan</small><strong>7 h</strong></span><span><small>Wykonanie</small><strong>{checkedIn ? "trwa" : "0 h"}</strong></span><span><small>Odchylenie</small><strong>{checkedIn ? "+1 min" : "—"}</strong></span></div>
        </article>
      </section>
      <section className="history-card">
        <div className="card-header"><div><p className="eyebrow">EWIDENCJA</p><h2>Historia obecności</h2></div><button className="secondary-button" onClick={() => {
          exportCsv("rejestr-czasu-lipiec-2026.csv", [["Data", "Lokal", "Wejście", "Wyjście", "Czas", "Status"], ...history]);
          notify("Wyeksportowano rejestr czasu");
        }}><Download size={16} /> Eksportuj CSV</button></div>
        <div className="attendance-table">
          <div className="attendance-row header"><span>Data</span><span>Lokal</span><span>Wejście</span><span>Wyjście</span><span>Czas</span><span>Status</span></div>
          {history.map((row) => <div className="attendance-row" key={row[0]}>{row.map((cell, index) => <span key={index} className={cell === "Do weryfikacji" ? "needs-review" : ""}>{cell}</span>)}</div>)}
        </div>
      </section>
    </div>
  );
}

export default function GrafikPro() {
  const { connected, configured, summary, user, access, signOut, refresh } = useAppAuth();
  const [activeNav, setActiveNav] = useState<NavKey>("centrum");
  const [locations, setLocations] = useState<Location[]>(["KRUCZA", "PAWILONY"]);
  const [calendarMode, setCalendarMode] = useState<"Tydzień" | "2 tygodnie" | "Miesiąc">("Tydzień");
  const [drawer, setDrawer] = useState<Drawer>(null);
  const [mobileMenu, setMobileMenu] = useState(false);
  const [toast, setToast] = useState("");
  const [filtersOpen, setFiltersOpen] = useState(false);

  const activeLocations = useMemo(
    () => (locations.length ? locations : (["KRUCZA", "PAWILONY"] as Location[])),
    [locations],
  );

  function toggleLocation(location: Location) {
    setLocations((current) =>
      current.includes(location)
        ? current.filter((item) => item !== location)
        : [...current, location],
    );
  }

  function notify(message: string) {
    setToast(message);
    window.setTimeout(() => setToast(""), 2600);
  }

  return (
    <main className="app-shell">
      <aside className={`sidebar ${mobileMenu ? "open" : ""}`}>
        <div className="brand">
          <span className="brand-mark">G</span>
          <span className="brand-name">GRAFIK PRO <small>3.0</small></span>
          <button className="icon-button mobile-close" onClick={() => setMobileMenu(false)} aria-label="Zamknij menu">
            <X size={20} />
          </button>
        </div>

        <nav>
          {navItems.map(({ key, label, icon: Icon }) => (
            <button
              key={key}
              className={`nav-item ${activeNav === key ? "active" : ""}`}
              onClick={() => {
                setActiveNav(key);
                setMobileMenu(false);
                if (key !== "centrum") notify(`${label}: moduł został dodany do mapy wersji 3.0`);
              }}
            >
              <Icon size={21} strokeWidth={1.8} />
              <span>{label}</span>
            </button>
          ))}
        </nav>

        <div className="sidebar-footer">
          <button className="profile">
            <span className="avatar avatar-photo">KN</span>
            <span>
              <strong>{access?.employee ? `${access.employee.first_name} ${access.employee.last_name}` : user?.email?.split("@")[0] || "Katarzyna Nowak"}</strong>
              <small>{access?.roles?.[0]?.app_role === "OWNER" ? "Właściciel demo" : access?.employee?.primary_role || "Dyrektor operacyjny"}</small>
            </span>
            <ChevronRight size={17} />
          </button>
          {user && <button className="sidebar-signout" onClick={() => void signOut()}><LogOut size={15} /> Wyloguj się</button>}
          <button className="company">
            <span className="company-icon">GP</span>
            <span><strong>GRAFIK PRO DEMO</strong><small>KRUCZA • PAWILONY</small></span>
            <ChevronDown size={16} />
          </button>
        </div>
      </aside>

      {mobileMenu && <button className="scrim" onClick={() => setMobileMenu(false)} aria-label="Zamknij menu" />}

      <section className="workspace">
        <header className="topbar">
          <button className="icon-button menu-button" onClick={() => setMobileMenu(true)} aria-label="Otwórz menu">
            <Menu size={21} />
          </button>
          <div>
            <p className="eyebrow">OPERACJE / LIPIEC 2026</p>
            <h1>{activeNav === "centrum" ? "Centrum dowodzenia" : navItems.find((item) => item.key === activeNav)?.label}</h1>
          </div>
          <div className="topbar-actions">
            <button className={`live-status ${connected ? "online" : ""}`} onClick={() => void refresh()} title="Odśwież połączenie">
              {configured ? <Wifi size={15} /> : <RefreshCw size={15} />}
              <span>{connected ? `Supabase • ${summary?.employees || 0} osób` : configured ? "Łączenie z bazą" : "Dane demo"}</span>
            </button>
            <button className="date-selector"><CalendarDays size={17} /> lipiec 2026 <ChevronDown size={15} /></button>
            <div className="location-selector">
              {(["KRUCZA", "PAWILONY"] as Location[]).map((location) => (
                <button
                  key={location}
                  className={locations.includes(location) ? "selected" : ""}
                  onClick={() => toggleLocation(location)}
                >
                  <MapPin size={15} /> {location}
                </button>
              ))}
            </div>
            <button className="icon-button notification-button" aria-label="Powiadomienia" onClick={() => notify("Masz 5 zadań, w tym 2 pilne")}>
              <Bell size={19} /><span>5</span>
            </button>
            <button className="primary-button" onClick={() => setDrawer({ kind: "plan", title: "Nowy wariant planu", subtitle: "lipiec 2026 • oba lokale" })}>
              <Plus size={18} /> Nowy plan
            </button>
          </div>
        </header>

        {!["centrum", "kalendarz", "zespol", "czas"].includes(activeNav) && (
          <div className="module-banner">
            <Sparkles size={20} />
            <div>
              <strong>{navItems.find((item) => item.key === activeNav)?.label}</strong>
              <span>Ten ekran jest już uwzględniony w strukturze GRAFIK PRO 3.0. Pierwszy działający przekrój pokazuje Centrum dowodzenia.</span>
            </div>
            <button onClick={() => setActiveNav("centrum")}>Wróć do centrum</button>
          </div>
        )}

        {activeNav === "kalendarz" ? (
          <ManagerCalendar onOpen={setDrawer} notify={notify} />
        ) : activeNav === "zespol" ? (
          <EmployeeSchedule notify={notify} />
        ) : activeNav === "czas" ? (
          <AttendancePanel notify={notify} />
        ) : <div className="content">
          <section className="kpi-grid">
            <button className="kpi-card" onClick={() => notify("Filtr: wszystkie zmiany z obsadą poniżej 100%")}>
              <span className="kpi-icon violet"><Users size={25} /></span>
              <span><small>Obsada • {summary?.employees || 76} pracowników</small><strong>94%</strong><em className="up">↗ +4 p.p.</em></span>
              <span className="sparkline violet-line"><i /><i /><i /><i /><i /><i /></span>
            </button>
            <button className="kpi-card" onClick={() => setDrawer({ kind: "shortage", title: "3 otwarte braki", subtitle: "2 na Kruczej • 1 na Pawilonach" })}>
              <span className="kpi-icon coral"><AlertTriangle size={24} /></span>
              <span><small>Braki</small><strong>3</strong><em className="down">↗ +1 vs. cze</em></span>
              <span className="mini-bars">{[30, 55, 40, 72, 58, 88].map((h, i) => <i key={i} style={{ height: `${h}%` }} />)}</span>
            </button>
            <button className="kpi-card" onClick={() => notify("Otwieram koszty pracy według lokalizacji i roli")}>
              <span className="kpi-icon teal"><CircleDollarSign size={25} /></span>
              <span><small>Budżet</small><strong>78%</strong><em className="up">↗ +5 p.p.</em></span>
              <span className="ring" style={{ "--value": "78%" } as React.CSSProperties}><b>78</b></span>
            </button>
            <button className="kpi-card" onClick={() => setDrawer({ kind: "event", title: "5 zadań", subtitle: "2 wymagają reakcji dzisiaj" })}>
              <span className="kpi-icon orange"><ListChecks size={25} /></span>
              <span><small>Zadania</small><strong>5</strong><em className="down">2 pilne</em></span>
              <span className="ring orange-ring" style={{ "--value": "34%" } as React.CSSProperties}><b>2</b></span>
            </button>
          </section>

          <section className="main-grid">
            <div className="calendar-card">
              <div className="card-header">
                <div>
                  <p className="eyebrow">PLAN OPERACYJNY</p>
                  <h2>Kalendarz operacyjny</h2>
                </div>
                <div className="calendar-actions">
                  <div className="segmented">
                    {(["Tydzień", "2 tygodnie", "Miesiąc"] as const).map((mode) => (
                      <button key={mode} className={calendarMode === mode ? "active" : ""} onClick={() => setCalendarMode(mode)}>{mode}</button>
                    ))}
                  </div>
                  <button className={`secondary-button ${filtersOpen ? "active" : ""}`} onClick={() => setFiltersOpen(!filtersOpen)}>
                    <Filter size={16} /> Filtry
                  </button>
                  <button className="icon-button" aria-label="Ustawienia kalendarza"><Settings size={17} /></button>
                </div>
              </div>

              {filtersOpen && (
                <div className="filter-bar">
                  <Search size={16} />
                  <span>Aktywne filtry:</span>
                  <button>Wszystkie role <X size={13} /></button>
                  <button>Zmiany standardowe <X size={13} /></button>
                  <button onClick={() => setFiltersOpen(false)}>Wyczyść</button>
                </div>
              )}

              <div className="calendar-scroll">
                <div className="schedule-grid">
                  <div className="grid-corner"><button className="icon-button"><ChevronLeft size={16} /></button></div>
                  {days.map((day) => (
                    <button key={day.day} className={`day-head ${day.today ? "today" : ""}`}>
                      <span>{day.dow}</span><strong>{day.day}</strong><small>lip</small>
                    </button>
                  ))}

                  {activeLocations.flatMap((location) => [
                    <div className="location-row" key={`${location}-label`}>
                      <span><MapPin size={14} /><strong>{location}</strong></span>
                      <small>Obsada dzienna</small>
                    </div>,
                    ...days.map((day) => (
                      <button
                        key={`${location}-${day.day}-occupancy`}
                        className={`occupancy ${occupancyClass(day.occupancy[location])}`}
                        onClick={() => setDrawer({
                          kind: "shift",
                          title: `${location} • ${day.dow}, ${day.day} lipca`,
                          subtitle: `Obsada ${day.occupancy[location]}% • kliknij zmianę, aby zobaczyć szczegóły`,
                        })}
                      >
                        <span>{location === "KRUCZA" ? (day.day === 11 ? "51 / 50" : "48 / 50") : (day.day === 12 ? "27 / 36" : "34 / 36")}</span>
                        <strong>{day.occupancy[location]}%</strong>
                      </button>
                    )),
                    ...(["RANO", "ŚRODEK", "WIECZÓR"] as ShiftKey[]).flatMap((shift) => [
                      <div className={`shift-label ${shift.toLowerCase()}`} key={`${location}-${shift}-label`}>
                        <span className="shift-symbol">{shift === "RANO" ? "☀" : shift === "ŚRODEK" ? "◐" : "☾"}</span>
                        <span><strong>{shift}</strong><small>{shiftTime(location, shift, 5)}</small></span>
                      </div>,
                      ...days.map((day, dayIndex) => {
                        const person = personFor(location, shift, dayIndex);
                        const time = shiftTime(location, shift, dayIndex);
                        const isEmpty = time === "—";
                        const shortage = (location === "KRUCZA" && shift === "WIECZÓR" && dayIndex === 2)
                          || (location === "PAWILONY" && shift === "WIECZÓR" && dayIndex === 5);
                        return (
                          <button
                            key={`${location}-${shift}-${day.day}`}
                            disabled={isEmpty}
                            className={`shift-cell ${shift.toLowerCase()} ${isEmpty ? "empty" : ""}`}
                            onClick={() => setDrawer({
                              kind: "shift",
                              title: `${location} • ${shift} • ${day.dow}, ${day.day} lipca`,
                              subtitle: `${time} • ${shortage ? "brakuje pracowników" : "obsada zgodna z planem"}`,
                            })}
                          >
                            {!isEmpty && <>
                              <span className={`avatar ${person.tone}`}>{person.initials}</span>
                              <span className="cell-extra">+{dayIndex % 3 + 1}</span>
                              {shortage && <span className="shortage-badge">–{location === "KRUCZA" ? 3 : 2}</span>}
                            </>}
                          </button>
                        );
                      }),
                    ]),
                  ])}
                </div>
              </div>

              <div className="calendar-legend">
                <span><i className="dot violet-dot" /> Pełna obsada</span>
                <span><i className="dot amber-dot" /> Uwaga</span>
                <span><i className="dot red-dot" /> Braki krytyczne</span>
                <button onClick={() => setCalendarMode("Miesiąc")}>Zobacz cały miesiąc <ChevronRight size={15} /></button>
              </div>
            </div>

            <aside className="insight-rail">
              <article className="insight-card shortage-card">
                <div className="insight-head">
                  <span className="status-icon red"><AlertTriangle size={20} /></span>
                  <h3>Braki obsadowe</h3>
                  <span className="pill red-pill">3 otwarte</span>
                </div>
                {[
                  ["Śr, 8 lip • KRUCZA", "WIECZÓR 17:00–01:00", "Kelner", "Brak: 3"],
                  ["Niedz, 12 lip • KRUCZA", "WIECZÓR 17:00–03:00", "Barman", "Brak: 1"],
                  ["Sob, 11 lip • PAWILONY", "WIECZÓR 19:00–05:00", "Pomoc", "Brak: 2"],
                ].map((item) => (
                  <button key={item[0]} className="alert-row" onClick={() => setDrawer({ kind: "shortage", title: item[0], subtitle: `${item[1]} • ${item[2]} • ${item[3]}` })}>
                    <span><strong>{item[0]}</strong><small>{item[1]} • {item[2]}</small></span>
                    <em>{item[3]}</em><ChevronRight size={16} />
                  </button>
                ))}
                <button className="card-link" onClick={() => setDrawer({ kind: "shortage", title: "Wszystkie braki", subtitle: "3 otwarte • 7 rozwiązanych w tym miesiącu" })}>
                  Zobacz wszystkie braki <ChevronRight size={15} />
                </button>
              </article>

              <article className="insight-card event-card">
                <div className="insight-head">
                  <span className="status-icon amber"><CalendarDays size={20} /></span>
                  <h3>Event wymaga weryfikacji</h3>
                  <span className="pill amber-pill">Pilne</span>
                </div>
                <div className="event-body">
                  <strong>Wesele — Sala Kryształowa</strong>
                  <div className="event-meta"><span><CalendarDays size={14} /> Sob, 11 lip 2026</span><span><Clock3 size={14} /> 18:00–02:00</span></div>
                  <div className="guest-count"><Users size={15} /> 120 gości • KRUCZA</div>
                  <div className="assignee">
                    <span className="avatar amber">MZ</span>
                    <span><small>Potrzebna weryfikacja od</small><strong>Michał Zieliński</strong></span>
                  </div>
                </div>
                <button className="card-link" onClick={() => setDrawer({ kind: "event", title: "Wesele — Sala Kryształowa", subtitle: "Potrzebna weryfikacja od Michała Zielińskiego" })}>
                  Przejdź do zadania <ChevronRight size={15} />
                </button>
              </article>

              <article className="insight-card budget-card">
                <div className="insight-head">
                  <span className="status-icon teal"><BarChart3 size={21} /></span>
                  <h3>Sygnał budżetowy</h3>
                  <span className="pill teal-pill">W normie</span>
                </div>
                <div className="budget-number"><span>Koszty pracy</span><strong>78%</strong></div>
                <div className="progress"><i style={{ width: "78%" }} /></div>
                <small>214 560 zł / 275 000 zł • prognoza: 97%</small>
                <button className="card-link" onClick={() => notify("Budżet: szczegóły kosztów według lokalizacji, roli i dnia")}>
                  Zobacz szczegóły <ChevronRight size={15} />
                </button>
              </article>
            </aside>
          </section>

          <section className="analytics-strip">
            <div className="analytics-copy">
              <p className="eyebrow">PROGNOZA</p>
              <h2>Obsada a zapotrzebowanie</h2>
              <p>Plan reaguje na wydarzenia, budżet i rzeczywiste wykonanie. Kliknij punkt, aby zobaczyć konkretny dzień.</p>
              <div className="analysis-stats"><span><strong>+6%</strong><small>ruch vs. czerwiec</small></span><span><strong>–2,4%</strong><small>koszt / roboczogodz.</small></span></div>
            </div>
            <div className="chart-wrap" aria-label="Wykres planowanej i rzeczywistej obsady">
              <ResponsiveContainer width="100%" height={190}>
                <AreaChart data={chartData}>
                  <defs>
                    <linearGradient id="planGradient" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="5%" stopColor="#7457e8" stopOpacity={0.28} />
                      <stop offset="95%" stopColor="#7457e8" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid stroke="#ebe7ef" vertical={false} />
                  <XAxis dataKey="day" tickLine={false} axisLine={false} fontSize={11} />
                  <YAxis domain={[70, 105]} tickLine={false} axisLine={false} fontSize={11} />
                  <Tooltip contentStyle={{ borderRadius: 12, border: "1px solid #ded8cf" }} />
                  <Area type="monotone" dataKey="plan" stroke="#7457e8" fill="url(#planGradient)" strokeWidth={3} name="Plan" />
                  <Area type="monotone" dataKey="actual" stroke="#f59e45" fill="transparent" strokeWidth={2} name="Wykonanie" />
                </AreaChart>
              </ResponsiveContainer>
            </div>
          </section>
        </div>}
      </section>

      {drawer && (
        <>
          <button className="drawer-scrim" onClick={() => setDrawer(null)} aria-label="Zamknij szczegóły" />
          <aside className="drawer" role="dialog" aria-modal="true" aria-label={drawer.title}>
            <div className="drawer-head">
              <div><p className="eyebrow">SZCZEGÓŁY OPERACYJNE</p><h2>{drawer.title}</h2><span>{drawer.subtitle}</span></div>
              <button className="icon-button" onClick={() => setDrawer(null)} aria-label="Zamknij"><X size={19} /></button>
            </div>

            {drawer.kind === "plan" ? (
              <div className="drawer-content">
                <label>Nazwa wariantu<input defaultValue="Plan operacyjny 2026-07 — v1" /></label>
                <label>Scenariusz<select defaultValue="BAZOWY"><option>BAZOWY</option><option>EVENTOWY</option><option>OSZCZĘDNY</option></select></label>
                <label>Tryb optymalizacji<select defaultValue="ZRÓWNOWAŻONY"><option>ZRÓWNOWAŻONY</option><option>MINIMALNY KOSZT</option><option>MAKSYMALNA OBSADA</option><option>PREFERENCJE</option></select></label>
                <label>Poziom obsady<select defaultValue="OPTYMALNY"><option>MINIMALNY</option><option>OPTYMALNY</option><option>PEŁNY</option></select></label>
                <div className="impact-box"><Sparkles size={19} /><span><strong>Prognozowany wynik</strong><small>94–98% obsady • koszt 268–276 tys. zł • 0 naruszeń twardych reguł</small></span></div>
                <button className="primary-button full" onClick={() => { setDrawer(null); notify("Zadanie generowania wariantu zostało dodane do kolejki"); }}><WandSparkles size={18} /> Generuj wariant</button>
              </div>
            ) : (
              <div className="drawer-content">
                <div className="detail-status"><ShieldCheck size={20} /><span><strong>{drawer.kind === "shortage" ? "Wymaga działania" : "Dane zsynchronizowane"}</strong><small>Ostatnia aktualizacja: dzisiaj, 22:41</small></span></div>
                <h3>{drawer.kind === "event" ? "Wpływ na grafik" : "Pracownicy i wymagania"}</h3>
                {(drawer.kind === "event" ? people.slice(0, 4) : people.slice(0, 6)).map((person, index) => (
                  <button className="person-row" key={person.name}>
                    <span className={`avatar ${person.tone}`}>{person.initials}</span>
                    <span><strong>{person.name}</strong><small>{person.role}</small></span>
                    <span className={`availability ${index === 2 ? "bad" : ""}`}>{index === 2 ? "Niedostępny" : "Dostępny"}</span>
                    <ChevronRight size={16} />
                  </button>
                ))}
                {drawer.kind === "event" && (
                  <div className="impact-box"><Users size={19} /><span><strong>Po potwierdzeniu</strong><small>+2 kelnerów, +1 barman, +1 pomoc • szacowany koszt +1 840 zł</small></span></div>
                )}
                <div className="drawer-actions">
                  <button className="secondary-button" onClick={() => setDrawer(null)}>Zamknij</button>
                  <button className="primary-button" onClick={() => { setDrawer(null); notify(drawer.kind === "event" ? "Event został potwierdzony — plan oznaczono jako nieaktualny" : "Uruchomiono wyszukiwanie zastępstwa"); }}>
                    {drawer.kind === "event" ? <><Check size={17} /> Potwierdź event</> : <><Search size={17} /> Znajdź zastępstwo</>}
                  </button>
                </div>
              </div>
            )}
          </aside>
        </>
      )}

      {toast && <div className="toast"><Check size={17} /> {toast}</div>}
    </main>
  );
}
