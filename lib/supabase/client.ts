import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";

let browserClient: SupabaseClient | null | undefined;

const UAT_PROJECT_REF = "nhthrtpkfpmufmrmdyjg";
const PRODUCTION_PROJECT_REF = "bdybebzvzapihjdauehg";

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
  let projectRef = "brak-projektu";
  if (url) {
    try { projectRef = new URL(url).hostname.split(".")[0] || "nieznany-projekt"; }
    catch { projectRef = "nieznany-projekt"; }
  }
  const environment = (deploymentEnvironment || "local").trim().toLowerCase();
  const productionOnPreview = environment === "preview" && projectRef === PRODUCTION_PROJECT_REF;
  const uatOnProduction = environment === "production" && projectRef === UAT_PROJECT_REF;
  if (productionOnPreview || uatOnProduction) {
    return {
      allowed: false,
      projectRef,
      deploymentEnvironment: environment,
      message: productionOnPreview
        ? "Wdrożenie testowe wskazuje produkcyjną bazę. Dostęp został bezpiecznie zablokowany. Przejdź do Vercel → Environment Variables i przypisz zmienne UAT do tej gałęzi, a następnie wykonaj redeploy Preview."
        : "Wdrożenie produkcyjne wskazuje bazę UAT. Dostęp został bezpiecznie zablokowany. Sprawdź zmienne środowiska Production w Vercel przed ponownym wdrożeniem.",
    };
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
