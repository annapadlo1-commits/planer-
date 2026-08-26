import { NextResponse, type NextRequest } from "next/server";
import {
  GOOGLE_DRIVE_FILE_ID_COOKIE,
  GOOGLE_DRIVE_TOKEN_COOKIE,
  authenticatedAppUser,
  secureCookie,
} from "../oauth-shared";

export const runtime = "nodejs";
const MAX_WORKBOOK_BYTES = 8 * 1024 * 1024;
const GOOGLE_SHEET_MIME = "application/vnd.google-apps.spreadsheet";
const XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

type GoogleDriveFileMetadata = {
  id?: string;
  name?: string;
  mimeType?: string;
  size?: string;
  capabilities?: { canDownload?: boolean };
};

function clearImportCookies(request: NextRequest, response: NextResponse) {
  const options = {
    httpOnly: true,
    secure: secureCookie(request),
    sameSite: "lax" as const,
    maxAge: 0,
    path: "/api/google-drive/import",
  };
  response.cookies.set(GOOGLE_DRIVE_TOKEN_COOKIE, "", options);
  response.cookies.set(GOOGLE_DRIVE_FILE_ID_COOKIE, "", options);
  return response;
}

function jsonError(request: NextRequest, error: string, status: number) {
  return clearImportCookies(request, NextResponse.json(
    { error },
    { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } },
  ));
}

function safeWorkbookName(value: string | undefined) {
  const base = (value || "szafunek-z-dysku-google")
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, "-")
    .slice(0, 155)
    .replace(/\.+$/u, "") || "szafunek-z-dysku-google";
  return base.toLocaleLowerCase("pl-PL").endsWith(".xlsx") ? base : `${base}.xlsx`;
}

export async function POST(request: NextRequest) {
  if (!await authenticatedAppUser()) return jsonError(request, "Sesja SZAFUNEK wygasła.", 401);
  const token = request.cookies.get(GOOGLE_DRIVE_TOKEN_COOKIE)?.value;
  const fileId = request.cookies.get(GOOGLE_DRIVE_FILE_ID_COOKIE)?.value;
  if (!token || !fileId) return jsonError(request, "Wybór pliku z Dysku Google wygasł. Wybierz plik ponownie.", 401);

  const authorization = { Authorization: `Bearer ${token}` };
  try {
  const metadataResponse = await fetch(
    `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?fields=id,name,mimeType,size,capabilities(canDownload)&supportsAllDrives=true`,
    { headers: authorization, cache: "no-store" },
  );
  const metadata = await metadataResponse.json().catch(() => null) as GoogleDriveFileMetadata | null;
  if (!metadataResponse.ok || !metadata?.id) {
    return jsonError(request, `Google nie udostępnił informacji o wybranym pliku (${metadataResponse.status}).`, metadataResponse.status === 401 ? 401 : 502);
  }
  if (metadata.capabilities?.canDownload === false) {
    return jsonError(request, "Wybranego pliku nie można pobrać. Sprawdź uprawnienia na Dysku Google.", 403);
  }
  if (metadata.mimeType !== GOOGLE_SHEET_MIME && metadata.mimeType !== XLSX_MIME) {
    return jsonError(request, "Wybierz Arkusz Google albo plik Microsoft Excel (.xlsx).", 415);
  }
  if (metadata.size && Number(metadata.size) > MAX_WORKBOOK_BYTES) {
    return jsonError(request, "Plik przekracza bezpieczny limit 8 MB.", 413);
  }

  const downloadUrl = metadata.mimeType === GOOGLE_SHEET_MIME
    ? `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}/export?mimeType=${encodeURIComponent(XLSX_MIME)}`
    : `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?alt=media&supportsAllDrives=true`;
  const downloadResponse = await fetch(downloadUrl, { headers: authorization, cache: "no-store" });
  if (!downloadResponse.ok) {
    return jsonError(request, `Google nie pobrał wybranego pliku (${downloadResponse.status}).`, downloadResponse.status === 401 ? 401 : 502);
  }
  const workbook = await downloadResponse.arrayBuffer();
  if (!workbook.byteLength || workbook.byteLength > MAX_WORKBOOK_BYTES) {
    return jsonError(request, "Plik jest pusty albo przekracza bezpieczny limit 8 MB.", 413);
  }

  const fileName = safeWorkbookName(metadata.name);
  return clearImportCookies(request, new NextResponse(workbook, {
    status: 200,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": XLSX_MIME,
      "X-Content-Type-Options": "nosniff",
      "X-Grafik-Pro-File-Name": encodeURIComponent(fileName),
    },
  }));
  } catch {
    return jsonError(request, "Nie udało się bezpiecznie pobrać pliku z Dysku Google. Spróbuj ponownie.", 502);
  }
}
