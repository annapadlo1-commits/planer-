import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";

let browserClient: SupabaseClient | null | undefined;

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

  if (!url || !key) return null;
  // Every screen, drawer and provider must share one auth/session instance.
  // Creating a fresh client during route remounts caused short windows where
  // an OWNER request was sent without the refreshed token and the schedule
  // screen fell back to stale Matrix counts.
  if (browserClient === undefined) browserClient = createBrowserClient(url, key);
  return browserClient;
}

export function supabaseProjectRef() {
  const value = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!value) return "brak-projektu";
  try { return new URL(value).hostname.split(".")[0] || "nieznany-projekt"; }
  catch { return "nieznany-projekt"; }
}

export function applicationEnvironmentLabel() {
  const projectRef = supabaseProjectRef();
  if (projectRef === "nhthrtpkfpmufmrmdyjg") return "UAT";
  if (projectRef === "bdybebzvzapihjdauehg") return "PRODUKCJA";
  const configured = process.env.NEXT_PUBLIC_APP_ENV?.trim();
  if (configured) return configured.toLocaleUpperCase("pl-PL");
  return process.env.NODE_ENV === "production" ? "UAT/PRODUKCJA — SPRAWDŹ PROJEKT" : "LOKALNE";
}
