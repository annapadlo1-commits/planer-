import { NextResponse, type NextRequest } from "next/server";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get("code");
  const destination = request.nextUrl.clone();
  destination.pathname = "/";
  destination.search = "";

  if (code) {
    const supabase = await createSupabaseServerClient();
    const result = await supabase?.auth.exchangeCodeForSession(code);
    if (!result?.error) return privateRedirect(destination);
  }

  destination.searchParams.set("auth_error", "Nie udało się potwierdzić konta.");
  return privateRedirect(destination);
}

function privateRedirect(destination: URL) {
  const response = NextResponse.redirect(destination);
  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  response.headers.set("Pragma", "no-cache");
  response.headers.set("Expires", "0");
  return response;
}
