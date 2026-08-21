import type { AuthChangeEvent } from "@supabase/supabase-js";

export const SESSION_EXPIRED_MESSAGE =
  "Twoja sesja wygasła lub została unieważniona. Zaloguj się ponownie.";

export const SESSION_CHECK_FAILED_MESSAGE =
  "Nie udało się bezpiecznie sprawdzić sesji. Sprawdź połączenie z internetem i spróbuj ponownie.";

type AuthErrorLike = {
  code?: string | null;
  message?: string | null;
  name?: string | null;
  status?: number | null;
};

export type SessionFailureKind = "MISSING" | "INVALID" | "NETWORK";

export function classifySessionFailure(error: AuthErrorLike | null | undefined): SessionFailureKind {
  if (!error) return "MISSING";
  const code = (error.code || "").toLowerCase();
  const name = (error.name || "").toLowerCase();
  const message = (error.message || "").toLowerCase();

  if (
    name.includes("authsessionmissing")
    || code === "session_not_found"
    || message.includes("auth session missing")
  ) return "MISSING";

  if (
    error.status === 401
    || error.status === 403
    || code.includes("refresh_token")
    || code === "bad_jwt"
    || code === "session_expired"
    || code === "user_not_found"
    || message.includes("invalid refresh token")
    || message.includes("refresh token not found")
    || message.includes("invalid jwt")
    || message.includes("token has expired")
    || message.includes("jwt expired")
    || message.includes("session expired")
  ) return "INVALID";

  return "NETWORK";
}

export type AuthEventAction = "CLEAR" | "REFRESH_USER" | "VERIFY" | "IGNORE";

export function authEventAction(event: AuthChangeEvent): AuthEventAction {
  if (event === "SIGNED_OUT") return "CLEAR";
  if (event === "TOKEN_REFRESHED") return "REFRESH_USER";
  if (event === "SIGNED_IN" || event === "USER_UPDATED" || event === "PASSWORD_RECOVERY") return "VERIFY";
  // INITIAL_SESSION is deliberately ignored. AppAuthProvider performs a fresh
  // getUser() check instead of trusting the user embedded in local storage.
  return "IGNORE";
}

type BrowserStorage = Pick<Storage, "clear" | "getItem" | "key" | "length" | "removeItem">;

export function clearProtectedBrowserState(
  localStorage: BrowserStorage | null | undefined,
  sessionStorage: BrowserStorage | null | undefined,
) {
  try { sessionStorage?.clear(); } catch { /* storage can be unavailable in privacy mode */ }
  if (!localStorage) return;
  try {
    const keys: string[] = [];
    for (let index = 0; index < localStorage.length; index += 1) {
      const key = localStorage.key(index);
      if (key?.startsWith("grafik-pro:")) keys.push(key);
    }
    keys.forEach((key) => localStorage.removeItem(key));
  } catch {
    // Logout still clears the Supabase session even when browser storage is blocked.
  }
}
