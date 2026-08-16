import { NextResponse, type NextRequest } from "next/server";
import {
  GOOGLE_DRIVE_TOKEN_COOKIE,
  GOOGLE_OAUTH_CLIENT_ID,
  GOOGLE_OAUTH_RETURN_COOKIE,
  GOOGLE_OAUTH_STATE_COOKIE,
  authenticatedAppUser,
  googleOAuthCallbackUrl,
  returnUrlWithStatus,
  safeReturnTo,
  secureCookie,
} from "../../oauth-shared";

export const runtime = "nodejs";

type GoogleTokenResponse = {
  access_token?: string;
  expires_in?: number;
  error?: string;
  error_description?: string;
};

function redirectAndClear(request: NextRequest, returnTo: string, status: string) {
  const response = NextResponse.redirect(returnUrlWithStatus(request, returnTo, status));
  response.cookies.set(GOOGLE_OAUTH_STATE_COOKIE, "", {
    httpOnly: true, secure: secureCookie(request), sameSite: "lax", maxAge: 0,
    path: "/api/google-drive/oauth/callback",
  });
  response.cookies.set(GOOGLE_OAUTH_RETURN_COOKIE, "", {
    httpOnly: true, secure: secureCookie(request), sameSite: "lax", maxAge: 0,
    path: "/api/google-drive/oauth/callback",
  });
  return response;
}

export async function GET(request: NextRequest) {
  const returnTo = safeReturnTo(request.cookies.get(GOOGLE_OAUTH_RETURN_COOKIE)?.value ?? "/");
  if (!await authenticatedAppUser()) return redirectAndClear(request, returnTo, "app_auth_required");
  if (request.nextUrl.searchParams.get("error")) return redirectAndClear(request, returnTo, "denied");

  const expectedState = request.cookies.get(GOOGLE_OAUTH_STATE_COOKIE)?.value;
  const state = request.nextUrl.searchParams.get("state");
  const code = request.nextUrl.searchParams.get("code");
  const clientSecret = process.env.GOOGLE_OAUTH_CLIENT_SECRET;
  if (!expectedState || !state || state !== expectedState || !code) {
    return redirectAndClear(request, returnTo, "state_error");
  }
  if (!clientSecret) return redirectAndClear(request, returnTo, "configuration_error");

  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: GOOGLE_OAUTH_CLIENT_ID,
      client_secret: clientSecret,
      redirect_uri: googleOAuthCallbackUrl(request),
      grant_type: "authorization_code",
    }),
    cache: "no-store",
  });
  const token = await tokenResponse.json().catch(() => null) as GoogleTokenResponse | null;
  if (!tokenResponse.ok || !token?.access_token) return redirectAndClear(request, returnTo, "token_error");

  const response = redirectAndClear(request, returnTo, "ready");
  response.cookies.set(GOOGLE_DRIVE_TOKEN_COOKIE, token.access_token, {
    httpOnly: true,
    secure: secureCookie(request),
    sameSite: "lax",
    maxAge: Math.min(Math.max(Number(token.expires_in ?? 600), 60), 10 * 60),
    path: "/api/google-drive/upload",
  });
  return response;
}
