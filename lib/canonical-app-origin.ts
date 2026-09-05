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
  return validHttpsOrigin(
    process.env.NEXT_PUBLIC_CANONICAL_APP_ORIGIN ?? process.env.GOOGLE_OAUTH_REDIRECT_ORIGIN,
  );
}

export function canonicalUrl(pathname: string, search = "", hash = "") {
  const origin = configuredCanonicalAppOrigin();
  return origin ? `${origin}${pathname}${search}${hash}` : null;
}
