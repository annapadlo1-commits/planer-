"use client";

import type { User } from "@supabase/supabase-js";
import { Database, Loader2, LockKeyhole, Mail, ShieldCheck } from "lucide-react";
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import {
  authEventAction,
  browserIsOffline,
  classifySessionFailure,
  clearProtectedBrowserState,
  SESSION_CHECK_FAILED_MESSAGE,
  SESSION_EXPIRED_MESSAGE,
} from "@/lib/auth-session";
import { parseCompanyTimeContext } from "@/lib/company-time";
import {
  applicationEnvironmentLabel,
  createSupabaseBrowserClient,
  hasSupabaseConfig,
  supabaseEnvironmentGuard,
  supabaseProjectRef,
} from "@/lib/supabase/client";
import { userSafeErrorMessage } from "@/lib/user-safe-error";

type LiveSummary = {
  employees: number;
  locations: number;
  shifts: number;
  events: number;
};

type AppAccess = {
  provisioning_available?: boolean;
  roles?: { app_role: string; scope_role?: string | null; scope_location?: string | null }[];
  employee?: {
    employee_no: string;
    first_name: string;
    last_name: string;
    primary_role: string;
    active: boolean;
  } | null;
};

type WorkspaceIssue = "MISSING_CONFIGURATION" | "TIMEZONE_CONFIGURATION_FAILED" | "WORKSPACE_LOAD_FAILED" | null;

function isMissingCompanyConfiguration(error: { code?: string; message?: string } | null) {
  const value = `${error?.code ?? ""}|${error?.message ?? ""}`.toUpperCase();
  return value.includes("MATRIX_V2_NOT_FOUND") || value.includes("MATRIX_V2_FOR_MONTH_NOT_FOUND");
}

type AuthContextValue = {
  configured: boolean;
  connected: boolean;
  loading: boolean;
  user: User | null;
  access: AppAccess | null;
  summary: LiveSummary | null;
  error: string;
  companyTimezone: string;
  currentCompanyMonth: string;
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
  companyTimezone: "",
  currentCompanyMonth: "",
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
  const [companyTimezone, setCompanyTimezone] = useState("");
  const [currentCompanyMonth, setCurrentCompanyMonth] = useState("");
  const [workspaceIssue, setWorkspaceIssue] = useState<WorkspaceIssue>(null);
  const [sessionCheckError, setSessionCheckError] = useState("");
  const [authNotice, setAuthNotice] = useState("");
  // The server and the first browser render must be identical. Modern Node.js
  // exposes a global navigator without navigator.onLine; reading it during SSR
  // incorrectly rendered the offline screen and caused a hydration mismatch.
  const [offline, setOffline] = useState(false);
  const recoveryRef = useRef<Promise<void> | null>(null);
  const manualSignOutRef = useRef(false);

  const clearAuthenticatedState = useCallback((notice = "") => {
    setUser(null);
    setAccess(null);
    setSummary(null);
    setError("");
    setCompanyTimezone("");
    setCurrentCompanyMonth("");
    setWorkspaceIssue(null);
    setAuthNotice(notice);
  }, []);

  const loadLiveData = useCallback(async (activeUser?: User | null) => {
    if (!supabase || !activeUser) return false;
    setError("");
    setWorkspaceIssue(null);
    try {
      const accessResult = await supabase.rpc("current_user_access_v2");
      if (accessResult.error) {
        setAccess(null);
        setSummary(null);
        setError("Nie udało się pobrać aktualnego zakresu dostępu. Twoja sesja pozostaje zalogowana; spróbuj ponownie.");
        return false;
      }

      const nextAccess=(accessResult.data || null) as AppAccess | null;
      setAccess(nextAccess);

      if(!nextAccess?.roles?.length){
        setSummary(null);
        setCompanyTimezone("");
        setCurrentCompanyMonth("");
        return true;
      }

      const companyTimeResult=await supabase.rpc("current_company_time_context_v1");
      if(companyTimeResult.error){
        setSummary(null);
        setCompanyTimezone("");
        setCurrentCompanyMonth("");
        setWorkspaceIssue("TIMEZONE_CONFIGURATION_FAILED");
        return false;
      }
      let companyTime;
      try{
        companyTime=parseCompanyTimeContext(companyTimeResult.data);
      }catch{
        setSummary(null);
        setCompanyTimezone("");
        setCurrentCompanyMonth("");
        setWorkspaceIssue("TIMEZONE_CONFIGURATION_FAILED");
        return false;
      }
      setCompanyTimezone(companyTime.timezone);
      setCurrentCompanyMonth(companyTime.currentMonth);

      const matrixResult=await supabase.rpc("matrix_v2_workspace",{
        p_month:`${companyTime.currentMonth}-01`,
      });
      if(matrixResult.error){
        setSummary(null);
        setWorkspaceIssue(isMissingCompanyConfiguration(matrixResult.error)
          ? "MISSING_CONFIGURATION"
          : "WORKSPACE_LOAD_FAILED");
        return false;
      }

      const matrix=(matrixResult.data??{}) as {employees?:unknown[];locations?:unknown[];shiftTemplates?:unknown[]};
      setSummary({
        employees: matrix.employees?.length || 0,
        locations: matrix.locations?.length || 0,
        shifts: matrix.shiftTemplates?.length || 0,
        events: 0,
      });
      return true;
    } catch (cause) {
      setAccess(null);
      setSummary(null);
      setCompanyTimezone("");
      setCurrentCompanyMonth("");
      setWorkspaceIssue(null);
      setError("Nie udało się potwierdzić aktualnego zakresu dostępu. Spróbuj ponownie.");
      return false;
    }
  }, [supabase]);

  const recoverFirstRunConfiguration=useCallback(async()=>{
    if(!supabase||!user)return;
    setLoading(true);
    const result=await supabase.rpc("matrix_v2_ensure_first_run_uat_v1");
    if(result.error){
      setLoading(false);
      setWorkspaceIssue("WORKSPACE_LOAD_FAILED");
      return;
    }
    await loadLiveData(user);
    setLoading(false);
  },[loadLiveData,supabase,user]);

  const provisionCurrentAccess=useCallback(async()=>{
    if(!supabase||!user)return;
    setLoading(true);
    setError("");
    const result=await supabase.rpc("application_access_provision_current_user_v1");
    if(result.error){
      setLoading(false);
      setError("Nie udało się aktywować nadanego dostępu. Poproś właściciela o sprawdzenie adresu e-mail w Administracji i spróbuj ponownie.");
      return;
    }
    await loadLiveData(user);
    setLoading(false);
  },[loadLiveData,supabase,user]);

  const recoverSession = useCallback(async (showLoading = true) => {
    if (!supabase) return;
    if (recoveryRef.current) {
      await recoveryRef.current;
      return;
    }

    const recovery = (async () => {
      if (showLoading) setLoading(true);
      setSessionCheckError("");
      if (typeof navigator !== "undefined" && !navigator.onLine) {
        setOffline(true);
        setLoading(false);
        return;
      }

      try {
        const { data, error: userError } = await supabase.auth.getUser();
        if (userError || !data.user) {
          const failure = classifySessionFailure(userError);
          if (failure === "NETWORK") {
            setSessionCheckError(SESSION_CHECK_FAILED_MESSAGE);
          } else {
            if (failure === "INVALID") await supabase.auth.signOut({ scope: "local" });
            clearAuthenticatedState(failure === "INVALID" ? SESSION_EXPIRED_MESSAGE : "");
          }
          setLoading(false);
          return;
        }

        setUser(data.user);
        setAuthNotice("");
        await loadLiveData(data.user);
        setLoading(false);
      } catch {
        setSessionCheckError(SESSION_CHECK_FAILED_MESSAGE);
        setLoading(false);
      }
    })();

    recoveryRef.current = recovery;
    try {
      await recovery;
    } finally {
      if (recoveryRef.current === recovery) recoveryRef.current = null;
    }
  }, [clearAuthenticatedState, loadLiveData, supabase]);

  async function refresh() {
    await recoverSession(true);
  }

  useEffect(() => {
    if (!supabase) return;
    let disposed = false;
    const scheduleVerification = () => {
      window.setTimeout(() => {
        if (!disposed) void recoverSession(false);
      }, 0);
    };
    const { data: listener } = supabase.auth.onAuthStateChange((event, session) => {
      const action = authEventAction(event);
      if (action === "CLEAR") {
        clearAuthenticatedState(manualSignOutRef.current ? "" : SESSION_EXPIRED_MESSAGE);
        setLoading(false);
      } else if (action === "REFRESH_USER") {
        setUser(session?.user || null);
      } else if (action === "VERIFY") {
        scheduleVerification();
      }
    });
    const handleVisibility = () => {
      if (document.visibilityState === "visible") scheduleVerification();
    };
    const handlePageShow = () => scheduleVerification();
    const handleOffline = () => setOffline(true);
    const handleOnline = () => {
      setOffline(false);
      void recoverSession(true);
    };

    if (browserIsOffline(window)) {
      setOffline(true);
      setLoading(false);
    } else {
      void recoverSession(true);
    }
    document.addEventListener("visibilitychange", handleVisibility);
    window.addEventListener("pageshow", handlePageShow);
    window.addEventListener("offline", handleOffline);
    window.addEventListener("online", handleOnline);
    return () => {
      disposed = true;
      listener.subscription.unsubscribe();
      document.removeEventListener("visibilitychange", handleVisibility);
      window.removeEventListener("pageshow", handlePageShow);
      window.removeEventListener("offline", handleOffline);
      window.removeEventListener("online", handleOnline);
    };
  }, [clearAuthenticatedState, recoverSession, supabase]);

  async function signOut() {
    if (!supabase) return;
    manualSignOutRef.current = true;
    setLoading(true);
    setSessionCheckError("");
    const result = await supabase.auth.signOut({ scope: "local" });
    if (result.error && classifySessionFailure(result.error) !== "MISSING") {
      manualSignOutRef.current = false;
      setLoading(false);
      setSessionCheckError("Nie udało się bezpiecznie wylogować. Sprawdź połączenie z internetem i spróbuj ponownie.");
      return;
    }
    clearProtectedBrowserState(window.localStorage, window.sessionStorage);
    clearAuthenticatedState();
    setLoading(false);
    window.location.replace("/");
  }

  const value = {
    configured,
    connected: Boolean(user && access && summary && companyTimezone && currentCompanyMonth && !error && !workspaceIssue && !sessionCheckError && !offline),
    loading,
    user,
    access,
    summary,
    error,
    companyTimezone,
    currentCompanyMonth,
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

  if (offline) {
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><ShieldCheck size={24} /></span>
          <p className="eyebrow">BRAK POŁĄCZENIA</p>
          <h1>Dane firmowe są bezpiecznie ukryte</h1>
          <p>Brak połączenia z internetem. Sprawdź sieć i spróbuj ponownie. Po powrocie połączenia ponownie sprawdzimy sesję i uprawnienia.</p>
        </section>
      </main>
    );
  }

  if (loading) {
    return <div className="auth-loading"><Loader2 className="spin" size={28} /><strong>Łączenie z SZAFUNEK…</strong><span>Sprawdzamy sesję i uprawnienia.</span></div>;
  }

  if (sessionCheckError) {
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><ShieldCheck size={24} /></span>
          <p className="eyebrow">WERYFIKACJA SESJI</p>
          <h1>Nie pokazujemy panelu bez potwierdzenia dostępu</h1>
          <p>{sessionCheckError}</p>
          <button className="secondary-button" onClick={() => void refresh()}>Sprawdź ponownie</button>
        </section>
      </main>
    );
  }

  if (!user) {
    return <LoginScreen notice={authNotice} />;
  }

  if (workspaceIssue === "MISSING_CONFIGURATION" && access) {
    const canRecover=Boolean(access.roles?.some(role=>role.app_role==="OWNER"||role.app_role==="ADMIN"));
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><Database size={24} /></span>
          <p className="eyebrow">PIERWSZA KONFIGURACJA FIRMY</p>
          <h1>Uprawnienia są prawidłowe, ale brakuje konfiguracji firmy</h1>
          <p>Twoje konto i rola zostały potwierdzone. To nie jest odmowa dostępu. Utwórz bezpieczną pustą konfigurację albo spróbuj ponownie po jej przywróceniu.</p>
          {canRecover&&<button className="primary-button" onClick={() => void recoverFirstRunConfiguration()}>Utwórz bezpieczną pustą konfigurację</button>}
          <button className="secondary-button" onClick={() => void refresh()}>Sprawdź ponownie</button>
          {!canRecover&&<small>Konfigurację może odtworzyć właściciel lub administrator.</small>}
        </section>
      </main>
    );
  }

  if (workspaceIssue === "WORKSPACE_LOAD_FAILED" && access) {
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><Database size={24} /></span>
          <p className="eyebrow">POBIERANIE DANYCH FIRMY</p>
          <h1>Uprawnienia potwierdzone, ale nie udało się pobrać przestrzeni roboczej</h1>
          <p>Nie wylogowujemy Cię i nie ukrywamy poprawnie pobranej roli. Spróbuj ponownie; jeśli problem wróci, zgłoś błąd pobierania danych firmy.</p>
          <button className="secondary-button" onClick={() => void refresh()}>Sprawdź ponownie</button>
          <button className="login-switch" onClick={() => void signOut()}>Wyloguj się</button>
        </section>
      </main>
    );
  }

  if (workspaceIssue === "TIMEZONE_CONFIGURATION_FAILED" && access) {
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><Database size={24} /></span>
          <p className="eyebrow">STREFA CZASOWA FIRMY</p>
          <h1>Nie można bezpiecznie wybrać miesiąca</h1>
          <p>Brakuje poprawnej strefy IANA firmy albo serwer zwrócił niepełny kontekst czasu. Przejdź do Konfiguracja firmy → Firma i lokale, popraw strefę, opublikuj konfigurację i spróbuj ponownie.</p>
          <button className="secondary-button" onClick={() => void refresh()}>Sprawdź ponownie</button>
          <button className="login-switch" onClick={() => void signOut()}>Wyloguj się</button>
        </section>
      </main>
    );
  }

  if (error || !access) {
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><ShieldCheck size={24} /></span>
          <p className="eyebrow">KONTROLA UPRAWNIEŃ</p>
          <h1>Nie pokazujemy panelu bez aktualnych uprawnień</h1>
          <p>{error || "Nie udało się odczytać aktualnego zakresu dostępu."}</p>
          <button className="secondary-button" onClick={() => void refresh()}>Sprawdź ponownie</button>
          <button className="login-switch" onClick={() => void signOut()}>Wyloguj się</button>
        </section>
      </main>
    );
  }

  if (!error && access && (!access.roles || access.roles.length === 0)) {
    return (
      <main className="access-pending">
        <section>
          <span className="login-lock"><ShieldCheck size={24} /></span>
          <p className="eyebrow">KONTO AKTYWNE</p>
          <h1>Oczekuje na nadanie dostępu</h1>
          <p>{access.provisioning_available
            ? <>Dostęp dla konta <strong>{user.email}</strong> został nadany. Aktywuj go świadomie, aby powiązać konto z właściwą rolą i profilem pracownika.</>
            : <>Konto <strong>{user.email}</strong> zostało rozpoznane, ale nie ma jeszcze przypisanej roli ani zespołu. Właściciel może nadać dostęp w Administracji.</>}</p>
          {access.provisioning_available&&<button className="primary-button" onClick={()=>void provisionCurrentAccess()}>Aktywuj nadany dostęp</button>}
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

function LoginScreen({ notice = "" }: { notice?: string }) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [mode, setMode] = useState<"login" | "signup">("login");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [isError, setIsError] = useState(false);

  useEffect(() => {
    const callbackError = new URLSearchParams(window.location.search).get("auth_error");
    const nextMessage = notice || callbackError || "";
    if (nextMessage) {
      setMessage(nextMessage);
      setIsError(true);
    }
  }, [notice]);

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
      setMessage(userSafeErrorMessage(result.error, {
        context: mode === "login" ? "auth-login" : "auth-signup",
        summary: mode === "login"
          ? "Nie udało się zalogować."
          : "Nie udało się utworzyć konta.",
        nextStep: mode === "login"
          ? "Sprawdź e-mail i hasło, a następnie spróbuj ponownie."
          : "Sprawdź e-mail i wymagania hasła, a następnie spróbuj ponownie.",
      }));
      return;
    }
    if (mode === "signup" && !result.data.session) {
      setMessage("Konto utworzone. Potwierdź adres e-mail. Dostęp do firmy nadaje jej właściciel lub administrator.");
    } else if (mode === "signup") {
      setMessage("Konto utworzone. Dostęp do firmy nadaje jej właściciel lub administrator.");
    } else {
      setMessage("Logowanie zakończone.");
    }
  }

  return (
    <main className="login-page">
      <section className="login-brand">
        <div className="login-brand-signature">
          <img className="login-brand-lockup" src="/brand/szafunek-lockup-transparent.png" alt="SZAFUNEK" />
          <span className="login-brand-role">PIZZAIOLO</span>
        </div>
        <h1>OGARNIJ ZMIANY</h1>
      </section>
      <section className="login-panel">
        <div className="login-card">
          <img className="login-app-icon" src="/icons/szafunek-192.png" alt="SZAFUNEK" />
          <div className="live-status environment-status online" title={`Projekt Supabase: ${supabaseProjectRef()}`}>
            <Database size={15} /><span><b>{applicationEnvironmentLabel()}</b><small>{supabaseProjectRef()}</small></span>
          </div>
          <span className="login-lock"><LockKeyhole size={24} /></span>
          <p className="eyebrow">BEZPIECZNY DOSTĘP</p>
          <h2>{mode === "login" ? "Zaloguj się" : "Utwórz konto"}</h2>
          <p>{mode === "login" ? "Otwórz swój zakres aplikacji." : "Po rejestracji właściciel lub administrator firmy nada Ci właściwy dostęp."}</p>
          <form onSubmit={submit}>
            <label>E-mail<div className="input-with-icon"><Mail size={16} /><input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="anna@firma.pl" /></div></label>
            <label>Hasło<div className="input-with-icon"><ShieldCheck size={16} /><input type="password" required minLength={6} value={password} onChange={(e) => setPassword(e.target.value)} placeholder="Minimum 6 znaków" /></div></label>
            {message && <div className={`auth-message ${isError ? "error" : ""}`}>{message}</div>}
            <button className="primary-button full" disabled={busy}>{busy ? <><Loader2 className="spin" size={17} /> Przetwarzanie…</> : mode === "login" ? "Zaloguj się" : "Utwórz konto"}</button>
          </form>
          <button className="login-switch" onClick={() => { setMode(mode === "login" ? "signup" : "login"); setMessage(""); }}>
            {mode === "login" ? "Nie masz konta? Utwórz je" : "Masz już konto? Zaloguj się"}
          </button>
          <small>Hasła i sesje obsługuje Supabase Auth. Aplikacja nie przechowuje haseł.</small>
        </div>
      </section>
    </main>
  );
}
