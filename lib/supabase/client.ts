import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";

let browserClient: SupabaseClient | null | undefined;

const UAT_PROJECT_REF = "nhthrtpkfpmufmrmdyjg";
const PRODUCTION_PROJECT_REF = "bdybebzvzapihjdauehg";
const MISSING_PROJECT_REF = "brak-projektu";
const UNKNOWN_PROJECT_REF = "nieznany-projekt";
const PROJECT_BY_ENVIRONMENT: Readonly<Record<string, string>> = Object.freeze({
  preview: UAT_PROJECT_REF,
  production: PRODUCTION_PROJECT_REF,
  development: UAT_PROJECT_REF,
  local: UAT_PROJECT_REF,
});

export type SupabaseEnvironmentGuard = {
  allowed: boolean;
  projectRef: string;
  deploymentEnvironment: string;
  message: string;
};

export function evaluateSupabaseEnvironment(
  url: string | undefined,
  deploymentEnvironment: string | undefined,
): SupabaseEnvironmentGuard {
  let projectRef = MISSING_PROJECT_REF;
  if (url) {
    try {
      const parsed = new URL(url);
      const hostMatch = parsed.hostname.match(/^([a-z0-9]+)\.supabase\.co$/u);
      const isCanonicalOrigin = parsed.protocol === "https:"
        && parsed.username === ""
        && parsed.password === ""
        && parsed.port === ""
        && parsed.pathname === "/"
        && parsed.search === ""
        && parsed.hash === "";
      projectRef = isCanonicalOrigin && hostMatch?.[1]
        ? hostMatch[1]
        : UNKNOWN_PROJECT_REF;
    } catch {
      projectRef = UNKNOWN_PROJECT_REF;
    }
  }
  const environment = (deploymentEnvironment ?? "").trim().toLowerCase();
  const expectedProjectRef = PROJECT_BY_ENVIRONMENT[environment];

  if (projectRef === MISSING_PROJECT_REF) {
    return {
      allowed: false,
      projectRef,
      deploymentEnvironment: environment,
      message: "Brakuje adresu projektu Supabase. Dostęp został bezpiecznie zablokowany. Przejdź do Vercel → Environment Variables, ustaw NEXT_PUBLIC_SUPABASE_URL dla bieżącego środowiska i ponów wdrożenie.",
    };
  }

  if (projectRef === UNKNOWN_PROJECT_REF) {
    return {
      allowed: false,
      projectRef,
      deploymentEnvironment: environment,
      message: "Adres Supabase nie wskazuje rozpoznanego, dozwolonego projektu. Dostęp został bezpiecznie zablokowany. Przejdź do Vercel → Environment Variables i ustaw kanoniczny adres projektu dla bieżącego środowiska.",
    };
  }

  if (!expectedProjectRef) {
    return {
      allowed: false,
      projectRef,
      deploymentEnvironment: environment,
      message: "Nie rozpoznano środowiska wdrożenia. Dostęp do Supabase został bezpiecznie zablokowany. Ustaw środowisko na Preview, Production albo lokalny Development i uruchom aplikację ponownie.",
    };
  }

  if (projectRef !== expectedProjectRef) {
    const message = environment === "preview" && projectRef === PRODUCTION_PROJECT_REF
      ? "Wdrożenie testowe wskazuje produkcyjną bazę. Dostęp został bezpiecznie zablokowany. Przejdź do Vercel → Environment Variables i przypisz zmienne UAT do tej gałęzi, a następnie wykonaj redeploy Preview."
      : environment === "production" && projectRef === UAT_PROJECT_REF
        ? "Wdrożenie produkcyjne wskazuje bazę UAT. Dostęp został bezpiecznie zablokowany. Sprawdź zmienne środowiska Production w Vercel przed ponownym wdrożeniem."
        : "Projekt Supabase nie jest dozwolony dla bieżącego środowiska. Dostęp został bezpiecznie zablokowany. Przejdź do ustawień środowiska i przypisz właściwy projekt przed ponownym uruchomieniem.";
    return { allowed: false, projectRef, deploymentEnvironment: environment, message };
  }

  return { allowed: true, projectRef, deploymentEnvironment: environment, message: "" };
}

export function supabaseEnvironmentGuard() {
  return evaluateSupabaseEnvironment(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_VERCEL_ENV || process.env.VERCEL_ENV,
  );
}

export function hasSupabaseConfig() {
  return Boolean(
    process.env.NEXT_PUBLIC_SUPABASE_URL &&
      (process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ||
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY),
  );
}

export function createSupabaseBrowserClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ||
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !key || !supabaseEnvironmentGuard().allowed) return null;
  // Every screen, drawer and provider must share one auth/session instance.
  // Creating a fresh client during route remounts caused short windows where
  // an OWNER request was sent without the refreshed token and the schedule
  // screen fell back to stale Matrix counts.
  if (browserClient === undefined) browserClient = createBrowserClient(url, key);
  return browserClient;
}

export function supabaseProjectRef() {
  return supabaseEnvironmentGuard().projectRef;
}

export function applicationEnvironmentLabel() {
  const projectRef = supabaseProjectRef();
  if (projectRef === UAT_PROJECT_REF) return "UAT";
  if (projectRef === PRODUCTION_PROJECT_REF) return "PRODUKCJA";
  const configured = process.env.NEXT_PUBLIC_APP_ENV?.trim();
  if (configured) return configured.toLocaleUpperCase("pl-PL");
  return process.env.NODE_ENV === "production" ? "UAT/PRODUKCJA — SPRAWDŹ PROJEKT" : "LOKALNE";
}
