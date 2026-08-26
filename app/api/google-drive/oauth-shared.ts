import { createSupabaseServerClient } from "@/lib/supabase/server";
import type { NextRequest } from "next/server";
import { configuredCanonicalAppOrigin } from "@/lib/canonical-app-origin";

export const GOOGLE_OAUTH_CLIENT_ID = process.env.GOOGLE_OAUTH_CLIENT_ID
  ?? process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID
  ?? "371272025154-p2am6470as5adbdp7di90tnbsq61iotp.apps.googleusercontent.com";
export const GOOGLE_DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file";
export const GOOGLE_OAUTH_STATE_COOKIE = "gp_google_oauth_state";
export const GOOGLE_OAUTH_RETURN_COOKIE = "gp_google_oauth_return";
export const GOOGLE_OAUTH_ACTION_COOKIE = "gp_google_oauth_action";
export const GOOGLE_OAUTH_TARGET_COOKIE = "gp_google_oauth_target";
export const GOOGLE_DRIVE_TOKEN_COOKIE = "gp_google_drive_access";
export const GOOGLE_DRIVE_FILE_ID_COOKIE = "gp_google_drive_file_id";
export type GoogleDriveOAuthAction = "upload" | "import";
export type GoogleDriveImportTarget = "matrix" | "access";

export async function authenticatedAppUser() {
  const supabase = await createSupabaseServerClient();
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return null;
  return data.user;
}

export function googleOAuthCallbackUrl(request: NextRequest) {
  return new URL("/api/google-drive/oauth/callback", configuredCanonicalAppOrigin() ?? request.nextUrl.origin).toString();
}

export function safeReturnTo(value: string | null) {
  if (!value || !value.startsWith("/") || value.startsWith("//")) return "/";
  return value;
}

export function googleDriveOAuthAction(value: string | null): GoogleDriveOAuthAction {
  return value === "import" ? "import" : "upload";
}

export function googleDriveImportTarget(value: string | null): GoogleDriveImportTarget {
  return value === "access" ? "access" : "matrix";
}

export function safeGoogleDriveFileId(value: string | null) {
  if (!value || !/^[A-Za-z0-9_-]{10,200}$/.test(value)) return null;
  return value;
}

export function returnUrlWithStatus(request: NextRequest, returnTo: string, status: string) {
  const destination = new URL(safeReturnTo(returnTo), configuredCanonicalAppOrigin() ?? request.nextUrl.origin);
  destination.searchParams.set("googleDriveAuth", status);
  return destination;
}

export function canonicalOAuthStartUrl(request: NextRequest) {
  const origin = configuredCanonicalAppOrigin();
  if (!origin || origin === request.nextUrl.origin) return null;
  return new URL(`${request.nextUrl.pathname}${request.nextUrl.search}`, origin);
}

export function secureCookie(request: NextRequest) {
  return request.nextUrl.protocol === "https:";
}
