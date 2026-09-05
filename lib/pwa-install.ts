export const PWA_INSTALL_SHOWN_AT_KEY = "szafunek_pwa_install_prompt_shown_at";
export const PWA_INSTALL_DISMISSED_UNTIL_KEY = "szafunek_pwa_install_prompt_dismissed_until";
export const PWA_INSTALL_AUTO_COOLDOWN_MS = 30 * 24 * 60 * 60 * 1_000;
export const PWA_INSTALL_DISMISS_COOLDOWN_MS = 90 * 24 * 60 * 60 * 1_000;

type TimestampStorage = Pick<Storage, "getItem" | "setItem">;

function readTimestamp(storage: TimestampStorage, key: string) {
  const value = Number(storage.getItem(key));
  return Number.isFinite(value) && value > 0 ? value : null;
}

export function isIosSafariUserAgent(userAgent: string, maxTouchPoints = 0) {
  const iosDevice = /iphone|ipad|ipod/i.test(userAgent)
    || (/macintosh/i.test(userAgent) && maxTouchPoints > 1);
  const safariEngine = /safari/i.test(userAgent) && /webkit/i.test(userAgent);
  const alternateBrowser = /crios|fxios|edgios|opios|duckduckgo|gsa/i.test(userAgent);
  return iosDevice && safariEngine && !alternateBrowser;
}

export function shouldAutomaticallyOfferInstall(
  storage: TimestampStorage,
  now = Date.now(),
) {
  try {
    const dismissedUntil = readTimestamp(storage, PWA_INSTALL_DISMISSED_UNTIL_KEY);
    if (dismissedUntil !== null && dismissedUntil > now) return false;

    const shownAt = readTimestamp(storage, PWA_INSTALL_SHOWN_AT_KEY);
    return shownAt === null || now - shownAt >= PWA_INSTALL_AUTO_COOLDOWN_MS;
  } catch {
    return false;
  }
}

export function rememberInstallSuggestionShown(storage: TimestampStorage, now = Date.now()) {
  try {
    storage.setItem(PWA_INSTALL_SHOWN_AT_KEY, String(now));
    return true;
  } catch {
    return false;
  }
}

export function rememberInstallSuggestionDismissed(storage: TimestampStorage, now = Date.now()) {
  try {
    storage.setItem(PWA_INSTALL_SHOWN_AT_KEY, String(now));
    storage.setItem(PWA_INSTALL_DISMISSED_UNTIL_KEY, String(now + PWA_INSTALL_DISMISS_COOLDOWN_MS));
    return true;
  } catch {
    return false;
  }
}
