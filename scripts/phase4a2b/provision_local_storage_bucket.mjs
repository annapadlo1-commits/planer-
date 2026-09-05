#!/usr/bin/env node

const storageUrl = process.env.SUPABASE_STORAGE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!storageUrl) {
  console.error("SUPABASE_STORAGE_URL is required");
  process.exit(1);
}
if (!serviceRoleKey) {
  console.error("SUPABASE_SERVICE_ROLE_KEY is required");
  process.exit(1);
}

let parsed;
try {
  parsed = new URL(storageUrl);
} catch {
  console.error("refusing non-local Supabase URL");
  process.exit(1);
}

const port = Number(parsed.port);
const localHost = parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";
const localPath = parsed.pathname === "/" || parsed.pathname === "/storage/v1"
  || parsed.pathname === "/storage/v1/";
const safeUrl = parsed.protocol === "http:"
  && localHost
  && localPath
  && parsed.username === ""
  && parsed.password === ""
  && parsed.search === ""
  && parsed.hash === ""
  && parsed.port !== "";

if (!safeUrl) {
  console.error("refusing non-local Supabase URL");
  process.exit(1);
}
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error("refusing invalid local Storage port");
  process.exit(1);
}

const endpoint = new URL(`${parsed.pathname.replace(/\/$/u, "")}/bucket`, parsed);
const response = await fetch(endpoint, {
  method: "POST",
  headers: {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    id: "profile-avatars",
    name: "profile-avatars",
    public: false,
    file_size_limit: 5_242_880,
    allowed_mime_types: ["image/jpeg", "image/png", "image/webp"],
    type: "STANDARD",
  }),
});

if (response.status !== 200 && response.status !== 201) {
  console.error(`Storage API returned HTTP ${response.status}`);
  process.exit(1);
}

console.log("profile-avatars bucket provisioned through local Storage API");
