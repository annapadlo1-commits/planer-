"use client";

import type { User } from "@supabase/supabase-js";
import { Check, Database, Loader2, LockKeyhole, Mail, ShieldCheck } from "lucide-react";
import { createContext, useContext, useEffect, useMemo, useState } from "react";
import {
  applicationEnvironmentLabel,
  createSupabaseBrowserClient,
  hasSupabaseConfig,
  supabaseEnvironmentGuard,
  supabaseProjectRef,
} from "@/lib/supabase/client";

type LiveSummary = {
  employees: number;
  locations: number;
  shifts: number;
  events: number;
};

type AppAccess = {
  roles?: { app_role: string; scope_role?: string | null; scope_location?: string | null }[];
  employee?: {
    employee_no: string;
    first_name: string;
    last_name: string;
    primary_role: string;
  } | null;
};

type AuthContextValue = {
  configured: boolean;
  connected: boolean;
  loading: boolean;
  user: User | null;
  access: AppAccess | null;
  summary: LiveSummary | null;
  error: string;
  refresh: () => Promise<void>;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue>({
  configured: false,
  connected: false,
  loading: false,
  user: null,
  access: null,
  summary: null,
  error: "",
  refresh: async () => undefined,
  signOut: async () => undefined,
});

export function useAppAuth() {
  return useContext(AuthContext);
}

export function AppAuthProvider({ children }: { children: React.ReactNode }) {
  const configured = hasSupabaseConfig();
  const environmentGuard = supabaseEnvironmentGuard();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [loading, setLoading] = useState(configured && environmentGuard.allowed);
  const [user, setUser] = useState<User | null>(null);
  const [access, setAccess] = useState<AppAccess | null>(null);
  const [summary, setSummary] = useState<LiveSummary | null>(null);
  const [error, setError] = useState("");

  async function loadLiveData(activeUser?: User | null) {
    if (!supabase || !activeUser) return;
    setError("");
    try {
      const [
        accessResult,
        matrixResult,
      ] = await Promise.all([
        supabase.rpc("current_user_access_v2"),
        supabase.rpc("matrix_v2_workspace",{p_month:`${new Date().toISOString().slice(0,7)}-01`}),
      ]);

      const firstError = [
        accessResult.error,
        matrixResult.error,
      ].find(Boolean);
      if (firstError) throw firstError;

      setAccess((accessResult.data || null) as AppAccess | null);
      const matrix=(matrixResult.data??{}) as {employees?:unknown[];locations?:unknown[];shiftTemplates?:unknown[]};
      setSummary({
        employees: matrix.employees?.length || 0,
        locations: matrix.locations?.length || 0,
        shifts: matrix.shiftTemplates?.length || 0,
        events: 0,
      });
    } catch (cause) {
      const message =
        cause instanceof Error
          ? cause.message
          : cause && typeof cause === "object" && "message" in cause
            ? String((cause as { message: unknown }).message)
            : "Nie udało się pobrać danych Supabase.";
      setError(message);
    }
  }

  async function refresh() {
    if (!supabase) return;
    setLoading(true);
    const { data } = await supabase.auth.getUser();
    setUser(data.user);
    await loadLiveData(data.user);
    setLoading(false);
  }

  useEffect(() => {
    if (!supabase) return;
    supabase.auth.getSession().then(async ({ data }) => {
      setUser(data.session?.user || null);
      await loadLiveData(data.session?.user || null);
      setLoading(false);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((event, session) => {
      setUser(session?.user || null);
      if (session?.user && (event === "SIGNED_IN" || event === "USER_UPDATED")) void loadLiveData(session.user);
      else if (!session?.user) {
        setAccess(null);
        setSummary(null);
      }
    });
    return () => listener.subscription.unsubscribe();
  }, [supabase]);

  async function signOut() {
    await supabase?.auth.signOut();
  }

  const value = {
    configured,
    connected: Boolean(user && summary && !error),
    loading,
    user,
    access,
    summary,
    error,
    refresh,
    signOut,
  };

  if (!environmentGuard.allowed) {
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><ShieldCheck size={24} /></span>
          <p className="eyebrow">BLOKADA BEZPIECZEŃSTWA ŚRODOWISKA</p>
          <h1>To wdrożenie nie może połączyć się z tą bazą</h1>
          <p>{environmentGuard.message}</p>
          <small>Środowisko: {environmentGuard.deploymentEnvironment} • projekt: {environmentGuard.projectRef}</small>
        </section>
      </main>
    );
  }

  if (!configured) {
    return (
      <AuthContext.Provider value={value}>
        <div className="demo-mode-banner"><Database size={14} /> Tryb demonstracyjny — dodaj zmienne Supabase w Vercel, aby włączyć dane online.</div>
        {children}
      </AuthContext.Provider>
    );
  }

  if (loading) {
    return <div className="auth-loading"><Loader2 className="spin" size={28} /><strong>Łączenie z SZAFUNEK…</strong><span>Sprawdzamy sesję i uprawnienia.</span></div>;
  }

  if (!user) {
    return <LoginScreen />;
  }

  if (!error && access && (!access.roles || access.roles.length === 0)) {
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><ShieldCheck size={24} /></span>
          <p className="eyebrow">KONTO AKTYWNE</p>
          <h1>Oczekuje na nadanie dostępu</h1>
          <p>Konto <strong>{user.email}</strong> zostało rozpoznane, ale nie ma jeszcze przypisanej roli ani zespołu. Właściciel może nadać dostęp w Administracji.</p>
          <button className="secondary-button" onClick={() => void refresh()}>Sprawdź ponownie</button>
          <button className="login-switch" onClick={() => void signOut()}>Wyloguj się</button>
        </section>
      </main>
    );
  }

  return (
    <AuthContext.Provider value={value}>
      {error && <div className="connection-error"><strong>Połączenie wymaga uwagi</strong><span>{error}</span><button onClick={() => void refresh()}>Spróbuj ponownie</button></div>}
      {children}
    </AuthContext.Provider>
  );
}

function LoginScreen() {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [mode, setMode] = useState<"login" | "signup">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [isError, setIsError] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!supabase) return;
    setBusy(true);
    setMessage("");
    setIsError(false);
    const result = mode === "login"
      ? await supabase.auth.signInWithPassword({ email, password })
      : await supabase.auth.signUp({
          email,
          password,
          options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
        });
    setBusy(false);
    if (result.error) {
      setIsError(true);
      setMessage(result.error.message);
      return;
    }
    if (mode === "signup" && !result.data.session) {
      setMessage("Konto utworzone. Sprawdź e-mail i potwierdź rejestrację.");
    } else {
      setMessage("Logowanie zakończone.");
    }
  }

  return (
    <main className="login-page">
      <section className="login-brand">
        <span className="brand-mark">SZ</span>
        <p className="eyebrow">SZAFUNEK</p>
        <h1>Planowanie, które zna realia Twojego zespołu.</h1>
        <p>Grafiki ról, dwa lokale, eventy, budżet, zastępstwa i rejestr czasu w jednym bezpiecznym miejscu.</p>
        <div className="login-points">
          <span><Check size={16} /> 76 pracowników demonstracyjnych</span>
          <span><Check size={16} /> KRUCZA i PAWILONY</span>
          <span><Check size={16} /> Dostęp według roli użytkownika</span>
        </div>
      </section>
      <section className="login-panel">
        <div className="login-card">
          <div className="live-status environment-status online" title={`Projekt Supabase: ${supabaseProjectRef()}`}>
            <Database size={15} /><span><b>{applicationEnvironmentLabel()}</b><small>{supabaseProjectRef()}</small></span>
          </div>
          <span className="login-lock"><LockKeyhole size={24} /></span>
          <p className="eyebrow">BEZPIECZNY DOSTĘP</p>
          <h2>{mode === "login" ? "Zaloguj się" : "Utwórz pierwsze konto demo"}</h2>
          <p>{mode === "login" ? "Otwórz swój zakres aplikacji." : "Pierwsze konto otrzyma rolę właściciela demo."}</p>
          <form onSubmit={submit}>
            <label>E-mail<div className="input-with-icon"><Mail size={16} /><input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="anna@firma.pl" /></div></label>
            <label>Hasło<div className="input-with-icon"><ShieldCheck size={16} /><input type="password" required minLength={6} value={password} onChange={(e) => setPassword(e.target.value)} placeholder="Minimum 6 znaków" /></div></label>
            {message && <div className={`auth-message ${isError ? "error" : ""}`}>{message}</div>}
            <button className="primary-button full" disabled={busy}>{busy ? <><Loader2 className="spin" size={17} /> Przetwarzanie…</> : mode === "login" ? "Zaloguj się" : "Utwórz konto demo"}</button>
          </form>
          <button className="login-switch" onClick={() => { setMode(mode === "login" ? "signup" : "login"); setMessage(""); }}>
            {mode === "login" ? "Pierwsze uruchomienie? Utwórz konto demo" : "Masz już konto? Zaloguj się"}
          </button>
          <small>Hasła i sesje obsługuje Supabase Auth. Aplikacja nie przechowuje haseł.</small>
        </div>
      </section>
    </main>
  );
}
