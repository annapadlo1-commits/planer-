export const UAT_SUPABASE_PROJECT_REF = "nhthrtpkfpmufmrmdyjg";
export const DEFAULT_UAT_APP_ORIGIN = "https://planer-git-codex-uat-consolidated-fixes-planner10.vercel.app";

function validHttpsOrigin(value: string | undefined) {
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.origin : null;
  } catch {
    return null;
  }
}

export function configuredCanonicalAppOrigin() {
  const explicit = validHttpsOrigin(
    process.env.NEXT_PUBLIC_CANONICAL_APP_ORIGIN ?? process.env.GOOGLE_OAUTH_REDIRECT_ORIGIN,
  );
  if (explicit) return explicit;
  return process.env.NEXT_PUBLIC_SUPABASE_URL?.includes(UAT_SUPABASE_PROJECT_REF)
    ? DEFAULT_UAT_APP_ORIGIN
    : null;
}

export function canonicalUrl(pathname: string, search = "", hash = "") {
  const origin = configuredCanonicalAppOrigin();
  return origin ? `${origin}${pathname}${search}${hash}` : null;
}
