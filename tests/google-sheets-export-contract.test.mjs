import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const integration = await readFile(new URL("../lib/google-sheets-export.ts", import.meta.url), "utf8");
const editor = await readFile(new URL("../components/MatrixV2Editor.tsx", import.meta.url), "utf8");
const oauthStart = await readFile(new URL("../app/api/google-drive/oauth/start/route.ts", import.meta.url), "utf8");
const oauthCallback = await readFile(new URL("../app/api/google-drive/oauth/callback/route.ts", import.meta.url), "utf8");
const serverUpload = await readFile(new URL("../app/api/google-drive/upload/route.ts", import.meta.url), "utf8");
const oauthShared = await readFile(new URL("../app/api/google-drive/oauth-shared.ts", import.meta.url), "utf8");
const canonicalOrigin = await readFile(new URL("../lib/canonical-app-origin.ts", import.meta.url), "utf8");
const appPage = await readFile(new URL("../app/page.tsx", import.meta.url), "utf8");
const nextConfig = await readFile(new URL("../next.config.ts", import.meta.url), "utf8");
const envExample = await readFile(new URL("../.env.example", import.meta.url), "utf8");

test("Google Sheets uses the public OAuth client and the least-privilege Drive scope", () => {
  assert.match(integration, /371272025154-p2am6470as5adbdp7di90tnbsq61iotp\.apps\.googleusercontent\.com/);
  assert.match(integration, /https:\/\/www\.googleapis\.com\/auth\/drive\.file/);
  assert.doesNotMatch(integration, /auth\/drive["']/);
  assert.match(integration, /https:\/\/accounts\.google\.com\/gsi\/client/);
});

test("the browser converts an uploaded xlsx into a native Google spreadsheet", () => {
  assert.match(integration, /upload\/drive\/v3\/files\?uploadType=multipart&fields=id/);
  assert.match(integration, /application\/vnd\.google-apps\.spreadsheet/);
  assert.match(integration, /docs\.google\.com\/spreadsheets\/d\//);
});

test("configuration and access exports retain both Google Sheets and Excel actions", () => {
  assert.ok((editor.match(/Otwórz w Google Sheets/g) ?? []).length >= 2);
  assert.ok((editor.match(/Połącz konto Google/g) ?? []).length >= 2);
  assert.ok((editor.match(/Utwórz arkusz na Dysku Google/g) ?? []).length >= 2);
  assert.match(editor, /Pobierz plik Excel/);
  assert.match(editor, /Pobierz prosty plik Excel/);
});

test("Google authorization happens before workbook generation and does not consume a second popup", () => {
  assert.doesNotMatch(integration, /window\.open/);
  assert.match(integration, /export async function authorizeGoogleDriveFile/);
  assert.match(editor, /const token=await authorizeGoogleDriveFile\(\);\s+const artifact=await buildAccessWorkbook/);
  assert.match(editor, /const token=toGoogle&&!googleServerReady\?await authorizeGoogleDriveFile\(\):null;[\s\S]{0,250}await build/);
  assert.match(editor, /window\.location\.assign\(await uploadWorkbookToGoogleSheets/);
});

test("blocked popup login has a secure authorization-code redirect fallback", () => {
  assert.match(integration, /GIS_LOAD_TIMEOUT_MS = 8_000/);
  assert.match(integration, /GIS_BLOCKED/);
  assert.match(integration, /beginGoogleDriveRedirectAuthorization/);
  assert.match(oauthStart, /searchParams\.set\("response_type", "code"\)/);
  assert.match(oauthStart, /GOOGLE_OAUTH_STATE_COOKIE/);
  assert.match(oauthCallback, /grant_type: "authorization_code"/);
  assert.match(oauthCallback, /GOOGLE_OAUTH_CLIENT_SECRET/);
  assert.doesNotMatch(`${integration}\n${editor}`, /GOOGLE_OAUTH_CLIENT_SECRET/);
  assert.doesNotMatch(`${oauthStart}\n${oauthCallback}`, /response_type:\s*["']token/);
});

test("server upload is app-authenticated, one-use and least privilege", () => {
  assert.match(oauthShared, /supabase\.auth\.getUser\(\)/);
  assert.match(oauthShared, /https:\/\/www\.googleapis\.com\/auth\/drive\.file/);
  assert.match(serverUpload, /MAX_WORKBOOK_BYTES = 8 \* 1024 \* 1024/);
  assert.match(serverUpload, /upload\/drive\/v3\/files\?uploadType=multipart&fields=id/);
  assert.match(serverUpload, /clearGoogleToken\(request, response\)/);
  assert.match(oauthCallback, /httpOnly: true/);
  assert.match(nextConfig, /Cross-Origin-Opener-Policy/);
  assert.match(nextConfig, /same-origin-allow-popups/);
});

test("UAT Google OAuth and application entry use one canonical host", () => {
  assert.match(canonicalOrigin, /NEXT_PUBLIC_CANONICAL_APP_ORIGIN/);
  assert.match(canonicalOrigin, /GOOGLE_OAUTH_REDIRECT_ORIGIN/);
  assert.doesNotMatch(canonicalOrigin, /planer-git-codex-uat-consolidated-fixes/);
  assert.match(oauthShared, /configuredCanonicalAppOrigin\(\)/);
  assert.match(oauthStart, /canonicalOAuthStartUrl\(request\)/);
  assert.match(appPage, /window\.location\.replace\(destination\)/);
});

test("the deployment template lists every canonical-host and Google OAuth setting", () => {
  for (const name of [
    "NEXT_PUBLIC_CANONICAL_APP_ORIGIN",
    "GOOGLE_OAUTH_REDIRECT_ORIGIN",
    "NEXT_PUBLIC_GOOGLE_CLIENT_ID",
    "GOOGLE_OAUTH_CLIENT_ID",
    "GOOGLE_OAUTH_CLIENT_SECRET",
  ]) {
    assert.match(envExample, new RegExp(`^${name}=`, "m"), `${name} must be documented for UAT deployment`);
  }
  assert.match(envExample, /^NEXT_PUBLIC_CANONICAL_APP_ORIGIN=https:\/\/uat\.szafunek\.pl$/m);
  assert.match(envExample, /^GOOGLE_OAUTH_REDIRECT_ORIGIN=https:\/\/uat\.szafunek\.pl$/m);
  assert.doesNotMatch(envExample, /bdybebzvzapihjdauehg/);
});
