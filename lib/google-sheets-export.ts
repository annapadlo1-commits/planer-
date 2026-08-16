const GOOGLE_CLIENT_ID = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID ??
  "371272025154-p2am6470as5adbdp7di90tnbsq61iotp.apps.googleusercontent.com";
const DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file";
const GIS_SCRIPT_URL = "https://accounts.google.com/gsi/client";
const GIS_LOAD_TIMEOUT_MS = 8_000;
const GOOGLE_DRIVE_AUTH_STATUS = "googleDriveAuth";

export type GoogleSheetsExportErrorCode =
  | "GIS_BLOCKED"
  | "GIS_TIMEOUT"
  | "GOOGLE_LOGIN_CANCELLED"
  | "GOOGLE_POPUP_BLOCKED"
  | "GOOGLE_AUTH_REQUIRED"
  | "GOOGLE_UPLOAD_FAILED";

export class GoogleSheetsExportError extends Error {
  constructor(public readonly code: GoogleSheetsExportErrorCode, message: string) {
    super(message);
    this.name = "GoogleSheetsExportError";
  }
}

export function isGoogleSheetsExportError(error: unknown): error is GoogleSheetsExportError {
  return error instanceof GoogleSheetsExportError;
}

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

function googleIdentityError(code: "GIS_BLOCKED" | "GIS_TIMEOUT") {
  return new GoogleSheetsExportError(
    code,
    code === "GIS_TIMEOUT"
      ? "Logowanie Google nie uruchomiło się w ciągu 8 sekund. Możesz kontynuować przez bezpieczne przekierowanie."
      : "Przeglądarka zablokowała moduł logowania Google. Możesz kontynuować przez bezpieczne przekierowanie albo zezwolić na accounts.google.com.",
  );
}

export function preloadGoogleIdentityServices() {
  if (window.google?.accounts.oauth2) return Promise.resolve();
  if (gisPromise) return gisPromise;

  const pending = new Promise<void>((resolve, reject) => {
    const previous = document.querySelector<HTMLScriptElement>(`script[src="${GIS_SCRIPT_URL}"]`);
    if (previous?.dataset.grafikProGoogleState === "error") previous.remove();
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${GIS_SCRIPT_URL}"]`);
    const script = existing ?? document.createElement("script");
    script.dataset.grafikProGoogleState = "loading";
    let settled = false;

    const cleanup = () => {
      window.clearTimeout(timeout);
      script.removeEventListener("load", loaded);
      script.removeEventListener("error", blocked);
    };
    const finish = (action: () => void) => {
      if (settled) return;
      settled = true;
      cleanup();
      action();
    };
    const loaded = () => finish(() => {
      if (window.google?.accounts.oauth2) {
        script.dataset.grafikProGoogleState = "ready";
        resolve();
      } else {
        script.dataset.grafikProGoogleState = "error";
        reject(googleIdentityError("GIS_BLOCKED"));
      }
    });
    const blocked = () => finish(() => {
      script.dataset.grafikProGoogleState = "error";
      reject(googleIdentityError("GIS_BLOCKED"));
    });
    const timeout = window.setTimeout(() => finish(() => {
      script.dataset.grafikProGoogleState = "error";
      reject(googleIdentityError("GIS_TIMEOUT"));
    }), GIS_LOAD_TIMEOUT_MS);

    script.addEventListener("load", loaded, { once: true });
    script.addEventListener("error", blocked, { once: true });
    if (!existing) {
      script.src = GIS_SCRIPT_URL;
      script.async = true;
      script.defer = true;
      document.head.appendChild(script);
    }
  });

  gisPromise = pending.catch(error => {
    gisPromise = null;
    throw error;
  });
  return gisPromise;
}

export async function authorizeGoogleDriveFile() {
  await preloadGoogleIdentityServices();
  return new Promise<string>((resolve, reject) => {
    const client = window.google!.accounts.oauth2.initTokenClient({
      client_id: GOOGLE_CLIENT_ID,
      scope: DRIVE_FILE_SCOPE,
      callback: response => response.access_token
        ? resolve(response.access_token)
        : reject(new GoogleSheetsExportError(
          "GOOGLE_LOGIN_CANCELLED",
          response.error_description || "Logowanie Google zostało anulowane.",
        )),
      error_callback: error => reject(new GoogleSheetsExportError(
        error.type === "popup_failed_to_open" ? "GOOGLE_POPUP_BLOCKED" : "GOOGLE_LOGIN_CANCELLED",
        error.type === "popup_failed_to_open"
          ? "Przeglądarka zablokowała okno logowania Google. Użyj bezpiecznego przekierowania."
          : "Logowanie Google zostało zamknięte przed udzieleniem zgody.",
      )),
    });
    client.requestAccessToken({ prompt: "consent" });
  });
}

function workbookUploadBody(bytes: ArrayBuffer | Uint8Array, fileName: string) {
  const boundary = `grafik_pro_${crypto.randomUUID()}`;
  const name = fileName.replace(/\.xlsx$/i, "");
  const metadata = JSON.stringify({ name, mimeType: "application/vnd.google-apps.spreadsheet" });
  const workbookBytes = bytes instanceof ArrayBuffer ? bytes : Uint8Array.from(bytes);
  return {
    boundary,
    body: new Blob([
      `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n`,
      `--${boundary}\r\nContent-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\r\n\r\n`,
      workbookBytes,
      `\r\n--${boundary}--`,
    ]),
  };
}

export async function uploadWorkbookToGoogleSheets(bytes: ArrayBuffer | Uint8Array, fileName: string, token: string) {
  const { boundary, body } = workbookUploadBody(bytes, fileName);
  const response = await fetch("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": `multipart/related; boundary=${boundary}` },
    body,
  });
  if (!response.ok) {
    const details = await response.text();
    throw new GoogleSheetsExportError(
      "GOOGLE_UPLOAD_FAILED",
      `Google nie utworzył arkusza (${response.status}). ${details.slice(0, 180)}`,
    );
  }
  const result = await response.json() as { id?: string };
  if (!result.id) throw new GoogleSheetsExportError(
    "GOOGLE_UPLOAD_FAILED",
    "Google nie zwrócił identyfikatora utworzonego arkusza.",
  );
  return `https://docs.google.com/spreadsheets/d/${encodeURIComponent(result.id)}/edit`;
}

export function googleDriveRedirectStatus() {
  if (typeof window === "undefined") return null;
  return new URL(window.location.href).searchParams.get(GOOGLE_DRIVE_AUTH_STATUS);
}

export function googleDriveRedirectMessage(status: string | null) {
  if (status === "configuration_error") return "Połączenie z Google wymaga dokończenia konfiguracji OAuth na UAT. Administrator musi dodać sekret klienta i dozwolony adres powrotu.";
  if (status === "app_auth_required") return "Sesja GRAFIK.PRO wygasła. Zaloguj się ponownie do aplikacji i ponów połączenie z Google.";
  if (status === "denied") return "Logowanie Google zostało anulowane przed udzieleniem zgody.";
  if (status === "state_error") return "Kontrola bezpieczeństwa logowania Google nie powiodła się. Rozpocznij połączenie ponownie z tego ekranu.";
  if (status === "token_error") return "Google nie potwierdził połączenia konta. Rozpocznij logowanie ponownie.";
  return null;
}

export function beginGoogleDriveRedirectAuthorization() {
  const returnTo = `${window.location.pathname}${window.location.search}${window.location.hash}`;
  window.location.assign(`/api/google-drive/oauth/start?returnTo=${encodeURIComponent(returnTo)}`);
}

export function clearGoogleDriveRedirectStatus() {
  const url = new URL(window.location.href);
  url.searchParams.delete(GOOGLE_DRIVE_AUTH_STATUS);
  window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
}

export async function uploadWorkbookToGoogleSheetsViaServer(bytes: ArrayBuffer | Uint8Array, fileName: string) {
  const workbookBytes = bytes instanceof ArrayBuffer ? bytes : Uint8Array.from(bytes);
  const response = await fetch("/api/google-drive/upload", {
    method: "POST",
    headers: {
      "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "X-Grafik-Pro-File-Name": encodeURIComponent(fileName),
    },
    body: workbookBytes,
  });
  const payload = await response.json().catch(() => null) as { url?: string; error?: string } | null;
  if (response.status === 401) throw new GoogleSheetsExportError(
    "GOOGLE_AUTH_REQUIRED",
    "Połączenie z Google wygasło. Połącz konto ponownie przez bezpieczne przekierowanie.",
  );
  if (!response.ok || !payload?.url) throw new GoogleSheetsExportError(
    "GOOGLE_UPLOAD_FAILED",
    payload?.error || `Google nie utworzył arkusza (${response.status}).`,
  );
  clearGoogleDriveRedirectStatus();
  return payload.url;
}
