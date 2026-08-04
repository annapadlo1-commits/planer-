import { createBrowserClient } from "@supabase/ssr";

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
  return createBrowserClient(url, key);
}

export function supabaseProjectRef() {
  const value = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!value) return "brak-projektu";
  try { return new URL(value).hostname.split(".")[0] || "nieznany-projekt"; }
  catch { return "nieznany-projekt"; }
}

export function applicationEnvironmentLabel() {
  const configured = process.env.NEXT_PUBLIC_APP_ENV?.trim();
  if (configured) return configured.toLocaleUpperCase("pl-PL");
  return process.env.NODE_ENV === "production" ? "UAT/PRODUKCJA — SPRAWDŹ PROJEKT" : "LOKALNE";
}
