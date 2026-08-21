import type { NextConfig } from "next";

const appBuildId = process.env.VERCEL_GIT_COMMIT_SHA
  || process.env.GITHUB_SHA
  || process.env.NEXT_PUBLIC_APP_BUILD_ID
  || "local";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [{ key: "Cross-Origin-Opener-Policy", value: "same-origin-allow-popups" }],
      },
      {
        source: "/sw.js",
        headers: [
          { key: "Cache-Control", value: "no-cache, no-store, must-revalidate" },
          { key: "Content-Type", value: "application/javascript; charset=utf-8" },
          { key: "Content-Security-Policy", value: "default-src 'self'; script-src 'self'" },
          { key: "Service-Worker-Allowed", value: "/" },
          { key: "X-Content-Type-Options", value: "nosniff" },
        ],
      },
      {
        source: "/manifest.webmanifest",
        headers: [{ key: "Cache-Control", value: "public, max-age=0, must-revalidate" }],
      },
    ];
  },
  // Vercel exposes VERCEL_ENV only to the build/server runtime.  Mirror the
  // non-secret environment name into the browser bundle so the Supabase
  // safety guard can fail closed before an auth client is created.
  env: {
    NEXT_PUBLIC_VERCEL_ENV: process.env.VERCEL_ENV || "local",
    NEXT_PUBLIC_APP_BUILD_ID: appBuildId,
  },
};

export default nextConfig;
