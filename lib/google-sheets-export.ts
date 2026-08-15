const GOOGLE_CLIENT_ID = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID ??
  "371272025154-p2am6470as5adbdp7di90tnbsq61iotp.apps.googleusercontent.com";
const DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file";
const GIS_SCRIPT_URL = "https://accounts.google.com/gsi/client";

type TokenResponse = { access_token?: string; error?: string; error_description?: string };
type TokenClient = { requestAccessToken: (options?: { prompt?: string }) => void };

declare global {
  interface Window {
    google?: { accounts: { oauth2: { initTokenClient: (options: {
      client_id: string;
      scope: string;
      callback: (response: TokenResponse) => void;
      error_callback?: (error: { type?: string }) => void;
    }) => TokenClient } } };
  }
}

let gisPromise: Promise<void> | null = null;

function loadGoogleIdentityServices() {
  if (window.google?.accounts.oauth2) return Promise.resolve();
  if (gisPromise) return gisPromise;
  gisPromise = new Promise<void>((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${GIS_SCRIPT_URL}"]`);
    const script = existing ?? document.createElement("script");
    const loaded = () => window.google?.accounts.oauth2
      ? resolve()
      : reject(new Error("Nie udało się uruchomić logowania Google."));
    script.addEventListener("load", loaded, { once: true });
    script.addEventListener("error", () => reject(new Error("Nie udało się połączyć z Google.")), { once: true });
    if (!existing) {
      script.src = GIS_SCRIPT_URL;
      script.async = true;
      script.defer = true;
      document.head.appendChild(script);
    }
  });
  return gisPromise;
}

async function requestDriveFileToken() {
  await loadGoogleIdentityServices();
  return new Promise<string>((resolve, reject) => {
    const client = window.google!.accounts.oauth2.initTokenClient({
      client_id: GOOGLE_CLIENT_ID,
      scope: DRIVE_FILE_SCOPE,
      callback: response => response.access_token
        ? resolve(response.access_token)
        : reject(new Error(response.error_description || "Logowanie Google zostało anulowane.")),
      error_callback: () => reject(new Error("Logowanie Google zostało anulowane lub zablokowane.")),
    });
    client.requestAccessToken({ prompt: "consent" });
  });
}

export function prepareGoogleSheetsWindow() {
  const target = window.open("", "_blank");
  if (!target) throw new Error("Przeglądarka zablokowała nowe okno. Zezwól na wyskakujące okna i spróbuj ponownie.");
  target.document.title = "GRAFIK PRO — Google Sheets";
  target.document.body.textContent = "Logowanie do Google i przygotowanie arkusza…";
  return target;
}

export async function openWorkbookInGoogleSheets(bytes: ArrayBuffer | Uint8Array, fileName: string, target = prepareGoogleSheetsWindow()) {
  try {
    const token = await requestDriveFileToken();
    const boundary = `grafik_pro_${crypto.randomUUID()}`;
    const name = fileName.replace(/\.xlsx$/i, "");
    const metadata = JSON.stringify({ name, mimeType: "application/vnd.google-apps.spreadsheet" });
    const workbookBytes = bytes instanceof ArrayBuffer ? bytes : Uint8Array.from(bytes);
    const body = new Blob([
      `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n`,
      `--${boundary}\r\nContent-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\r\n\r\n`,
      workbookBytes,
      `\r\n--${boundary}--`,
    ]);
    const response = await fetch("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": `multipart/related; boundary=${boundary}` },
      body,
    });
    if (!response.ok) {
      const details = await response.text();
      throw new Error(`Google nie utworzył arkusza (${response.status}). ${details.slice(0, 180)}`);
    }
    const result = await response.json() as { id?: string };
    if (!result.id) throw new Error("Google nie zwrócił identyfikatora utworzonego arkusza.");
    target.opener = null;
    target.location.replace(`https://docs.google.com/spreadsheets/d/${encodeURIComponent(result.id)}/edit`);
  } catch (error) {
    target.close();
    throw error;
  }
}
