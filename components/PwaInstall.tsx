"use client";

import { Download, Share2, X } from "lucide-react";
import { useEffect, useState } from "react";

type InstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed"; platform: string }>;
};

function isStandalone() {
  if (typeof window === "undefined") return false;
  return window.matchMedia("(display-mode: standalone)").matches
    || ("standalone" in window.navigator && Boolean((window.navigator as Navigator & { standalone?: boolean }).standalone));
}

export function PwaInstall() {
  const [installPrompt, setInstallPrompt] = useState<InstallPromptEvent | null>(null);
  const [showIosHelp, setShowIosHelp] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  const [installed, setInstalled] = useState(false);
  const [isIos, setIsIos] = useState(false);

  useEffect(() => {
    setInstalled(isStandalone());
    setIsIos(/iphone|ipad|ipod/i.test(window.navigator.userAgent));

    if ("serviceWorker" in navigator) {
      const register = () => void navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(() => undefined);
      if (document.readyState === "complete") register();
      else window.addEventListener("load", register, { once: true });
    }

    const onBeforeInstall = (event: Event) => {
      event.preventDefault();
      setInstallPrompt(event as InstallPromptEvent);
    };
    const onInstalled = () => {
      setInstalled(true);
      setInstallPrompt(null);
      setShowIosHelp(false);
    };
    window.addEventListener("beforeinstallprompt", onBeforeInstall);
    window.addEventListener("appinstalled", onInstalled);
    return () => {
      window.removeEventListener("beforeinstallprompt", onBeforeInstall);
      window.removeEventListener("appinstalled", onInstalled);
    };
  }, []);

  if (installed || dismissed || (!installPrompt && !isIos)) return null;

  const install = async () => {
    if (!installPrompt) {
      setShowIosHelp(true);
      return;
    }
    await installPrompt.prompt();
    const choice = await installPrompt.userChoice;
    if (choice.outcome === "accepted") setInstallPrompt(null);
  };

  return (
    <aside className="pwa-install" aria-label="Instalacja aplikacji SZAFUNEK">
      <div className="pwa-install-mark" aria-hidden="true"><img src="/brand/cat-symbol-exact.png" alt="" /></div>
      <span>
        <strong>Zainstaluj SZAFUNEK</strong>
        <small>{isIos ? "Dodaj aplikację do ekranu początkowego." : "Uruchamiaj jak aplikację — bez sklepu i bez opłat."}</small>
      </span>
      <button className="pwa-install-action" type="button" onClick={() => void install()}>
        {isIos ? <Share2 size={17} /> : <Download size={17} />}
        {isIos ? "Jak dodać" : "Zainstaluj"}
      </button>
      <button className="pwa-install-close" type="button" aria-label="Ukryj propozycję instalacji" onClick={() => setDismissed(true)}>
        <X size={17} />
      </button>
      {showIosHelp && (
        <div className="pwa-ios-help" role="status">
          W Safari wybierz <strong>Udostępnij</strong>, a następnie <strong>Do ekranu początkowego</strong>.
        </div>
      )}
    </aside>
  );
}
