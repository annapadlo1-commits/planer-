import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { supabaseEnvironmentGuard } from "@/lib/supabase/client";

function preventAuthenticatedResponseCaching(response: NextResponse) {
  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  response.headers.set("Pragma", "no-cache");
  response.headers.set("Expires", "0");
  return response;
}

export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
    || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !key || !supabaseEnvironmentGuard().allowed) {
    return preventAuthenticatedResponseCaching(supabaseResponse);
  }

  // The server client is request-scoped. Never share it between Vercel requests.
  const supabase = createServerClient(url, key, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, cacheHeaders) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        supabaseResponse = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) =>
          supabaseResponse.cookies.set(name, value, options));
        Object.entries(cacheHeaders).forEach(([header, value]) =>
          supabaseResponse.headers.set(header, value));
      },
    },
  });

  // getClaims() verifies the JWT and lets @supabase/ssr rotate an expired token
  // before the Client Component starts. Do not replace this with getSession().
  await supabase.auth.getClaims();
  return preventAuthenticatedResponseCaching(supabaseResponse);
}
