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
    if (!result?.error) return NextResponse.redirect(destination);
  }

  destination.searchParams.set("auth_error", "Nie udało się potwierdzić konta.");
  return NextResponse.redirect(destination);
}
