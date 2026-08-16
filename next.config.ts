import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  async headers() {
    return [{
      source: "/:path*",
      headers: [{ key: "Cross-Origin-Opener-Policy", value: "same-origin-allow-popups" }],
    }];
  },
  // Vercel exposes VERCEL_ENV only to the build/server runtime.  Mirror the
  // non-secret environment name into the browser bundle so the Supabase
  // safety guard can fail closed before an auth client is created.
  env: {
    NEXT_PUBLIC_VERCEL_ENV: process.env.VERCEL_ENV || "local",
  },
};

export default nextConfig;
