import { randomBytes } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import {
  GOOGLE_DRIVE_FILE_SCOPE,
  GOOGLE_OAUTH_CLIENT_ID,
  GOOGLE_OAUTH_ACTION_COOKIE,
  GOOGLE_OAUTH_TARGET_COOKIE,
  GOOGLE_OAUTH_RETURN_COOKIE,
  GOOGLE_OAUTH_STATE_COOKIE,
  authenticatedAppUser,
  canonicalOAuthStartUrl,
  googleDriveOAuthAction,
  googleDriveImportTarget,
  googleOAuthCallbackUrl,
  returnUrlWithStatus,
  safeReturnTo,
  secureCookie,
} from "../../oauth-shared";

export const runtime = "nodejs";

export async function GET(request: NextRequest) {
  const canonicalStart = canonicalOAuthStartUrl(request);
  if (canonicalStart) return NextResponse.redirect(canonicalStart);
  const returnTo = safeReturnTo(request.nextUrl.searchParams.get("returnTo"));
  const action = googleDriveOAuthAction(request.nextUrl.searchParams.get("action"));
  const target = googleDriveImportTarget(request.nextUrl.searchParams.get("target"));
  if (!await authenticatedAppUser()) {
    return NextResponse.redirect(returnUrlWithStatus(request, returnTo, "app_auth_required"));
  }
  if (!process.env.GOOGLE_OAUTH_CLIENT_SECRET) {
    return NextResponse.redirect(returnUrlWithStatus(request, returnTo, "configuration_error"));
  }

  const state = randomBytes(32).toString("base64url");
  const authorizationUrl = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  authorizationUrl.searchParams.set("client_id", GOOGLE_OAUTH_CLIENT_ID);
  authorizationUrl.searchParams.set("redirect_uri", googleOAuthCallbackUrl(request));
  authorizationUrl.searchParams.set("response_type", "code");
  authorizationUrl.searchParams.set("scope", GOOGLE_DRIVE_FILE_SCOPE);
  authorizationUrl.searchParams.set("access_type", "online");
  authorizationUrl.searchParams.set("include_granted_scopes", action === "import" ? "false" : "true");
  authorizationUrl.searchParams.set("prompt", "consent");
  authorizationUrl.searchParams.set("state", state);
  if (action === "import") {
    authorizationUrl.searchParams.set("trigger_onepick", "true");
    authorizationUrl.searchParams.set(
      "mimetypes",
      "application/vnd.google-apps.spreadsheet,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    );
  }

  const response = NextResponse.redirect(authorizationUrl);
  const cookieOptions = {
    httpOnly: true,
    secure: secureCookie(request),
    sameSite: "lax" as const,
    maxAge: 10 * 60,
    path: "/api/google-drive/oauth/callback",
  };
  response.cookies.set(GOOGLE_OAUTH_STATE_COOKIE, state, cookieOptions);
  response.cookies.set(GOOGLE_OAUTH_RETURN_COOKIE, returnTo, cookieOptions);
  response.cookies.set(GOOGLE_OAUTH_ACTION_COOKIE, action, cookieOptions);
  response.cookies.set(GOOGLE_OAUTH_TARGET_COOKIE, target, cookieOptions);
  return response;
}
