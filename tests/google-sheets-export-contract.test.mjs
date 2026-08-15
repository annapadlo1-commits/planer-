import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const integration = await readFile(new URL("../lib/google-sheets-export.ts", import.meta.url), "utf8");
const editor = await readFile(new URL("../components/MatrixV2Editor.tsx", import.meta.url), "utf8");

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
  assert.match(editor, /Pobierz plik Excel/);
  assert.match(editor, /Pobierz prosty plik Excel/);
});
