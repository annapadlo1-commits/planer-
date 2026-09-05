import { NextResponse, type NextRequest } from "next/server";
import {
  GOOGLE_DRIVE_TOKEN_COOKIE,
  authenticatedAppUser,
  secureCookie,
} from "../oauth-shared";

export const runtime = "nodejs";
const MAX_WORKBOOK_BYTES = 8 * 1024 * 1024;

function jsonError(error: string, status: number) {
  return NextResponse.json({ error }, { status, headers: { "Cache-Control": "no-store" } });
}

function clearGoogleToken(request: NextRequest, response: NextResponse) {
  response.cookies.set(GOOGLE_DRIVE_TOKEN_COOKIE, "", {
    httpOnly: true, secure: secureCookie(request), sameSite: "lax", maxAge: 0,
    path: "/api/google-drive/upload",
  });
}

export async function POST(request: NextRequest) {
  if (!await authenticatedAppUser()) return jsonError("Sesja SZAFUNEK wygasła.", 401);
  const token = request.cookies.get(GOOGLE_DRIVE_TOKEN_COOKIE)?.value;
  if (!token) return jsonError("Połączenie z Google wygasło.", 401);

  const encodedName = request.headers.get("x-grafik-pro-file-name") ?? "szafunek.xlsx";
  let fileName = "szafunek.xlsx";
  try { fileName = decodeURIComponent(encodedName); } catch { return jsonError("Nieprawidłowa nazwa pliku.", 400); }
  fileName = fileName.replace(/[\\/:*?"<>|\u0000-\u001f]/g, "-").slice(0, 160);
  if (!fileName.toLocaleLowerCase("pl-PL").endsWith(".xlsx")) return jsonError("Wymagany jest plik XLSX.", 400);

  const workbook = await request.arrayBuffer();
  if (!workbook.byteLength || workbook.byteLength > MAX_WORKBOOK_BYTES) {
    return jsonError("Plik jest pusty albo przekracza bezpieczny limit 8 MB.", 413);
  }

  const boundary = `grafik_pro_${crypto.randomUUID()}`;
  const metadata = JSON.stringify({
    name: fileName.replace(/\.xlsx$/i, ""),
    mimeType: "application/vnd.google-apps.spreadsheet",
  });
  const body = new Blob([
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n`,
    `--${boundary}\r\nContent-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\r\n\r\n`,
    workbook,
    `\r\n--${boundary}--`,
  ]);
  const googleResponse = await fetch("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": `multipart/related; boundary=${boundary}`,
    },
    body,
    cache: "no-store",
  });
  const result = await googleResponse.json().catch(() => null) as { id?: string } | null;
  if (!googleResponse.ok || !result?.id) {
    const response = jsonError(`Google nie utworzył arkusza (${googleResponse.status}).`, googleResponse.status === 401 ? 401 : 502);
    if (googleResponse.status === 401) clearGoogleToken(request, response);
    return response;
  }

  const response = NextResponse.json({
    url: `https://docs.google.com/spreadsheets/d/${encodeURIComponent(result.id)}/edit`,
  }, { headers: { "Cache-Control": "no-store" } });
  clearGoogleToken(request, response);
  return response;
}
