"use client";

import { Download, RefreshCw, Share2, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import {
  isIosSafariUserAgent,
  rememberInstallSuggestionDismissed,
  rememberInstallSuggestionShown,
  shouldAutomaticallyOfferInstall,
} from "@/lib/pwa-install";

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
  const [showInstallOffer, setShowInstallOffer] = useState(false);
  const [installed, setInstalled] = useState(false);
  const [isIosSafari, setIsIosSafari] = useState(false);
  const [waitingWorker, setWaitingWorker] = useState<ServiceWorker | null>(null);
  const [updateHidden, setUpdateHidden] = useState(false);
  const [applyingUpdate, setApplyingUpdate] = useState(false);
  const reloadRequested = useRef(false);

  useEffect(() => {
    const standalone = isStandalone();
    const iosSafari = isIosSafariUserAgent(window.navigator.userAgent, window.navigator.maxTouchPoints);
    const canOffer = shouldAutomaticallyOfferInstall(window.localStorage);
    setInstalled(standalone);
    setIsIosSafari(iosSafari);

    let iosTimer: number | undefined;
    if (!standalone && iosSafari && canOffer) {
      iosTimer = window.setTimeout(() => {
        rememberInstallSuggestionShown(window.localStorage);
        setShowInstallOffer(true);
      }, 12_000);
    }

    const onBeforeInstall = (event: Event) => {
      event.preventDefault();
      setInstallPrompt(event as InstallPromptEvent);
      if (!standalone && canOffer) {
        rememberInstallSuggestionShown(window.localStorage);
        setShowInstallOffer(true);
      }
    };
    const onInstalled = () => {
      setInstalled(true);
      setInstallPrompt(null);
      setShowIosHelp(false);
      setShowInstallOffer(false);
    };
    window.addEventListener("beforeinstallprompt", onBeforeInstall);
    window.addEventListener("appinstalled", onInstalled);
    return () => {
      if (iosTimer !== undefined) window.clearTimeout(iosTimer);
      window.removeEventListener("beforeinstallprompt", onBeforeInstall);
      window.removeEventListener("appinstalled", onInstalled);
    };
  }, []);

  useEffect(() => {
    if (process.env.NODE_ENV !== "production" || !("serviceWorker" in navigator)) return;

    const buildId = encodeURIComponent(process.env.NEXT_PUBLIC_APP_BUILD_ID || "local");
    let disposed = false;
    let registration: ServiceWorkerRegistration | null = null;
    let installingWorker: ServiceWorker | null = null;

    const showWaitingUpdate = (worker: ServiceWorker | null) => {
      if (!disposed && worker && navigator.serviceWorker.controller) {
        setWaitingWorker(worker);
        setUpdateHidden(false);
      }
    };
    const onInstallingStateChange = () => {
      if (installingWorker?.state === "installed") showWaitingUpdate(registration?.waiting || installingWorker);
    };
    const onUpdateFound = () => {
      if (installingWorker) installingWorker.removeEventListener("statechange", onInstallingStateChange);
      installingWorker = registration?.installing || null;
      installingWorker?.addEventListener("statechange", onInstallingStateChange);
    };
    const onControllerChange = () => {
      if (reloadRequested.current) window.location.reload();
    };
    const onVisibilityChange = () => {
      if (document.visibilityState === "visible") void registration?.update().catch(() => undefined);
    };

    navigator.serviceWorker.addEventListener("controllerchange", onControllerChange);
    document.addEventListener("visibilitychange", onVisibilityChange);

    const register = async () => {
      try {
        registration = await navigator.serviceWorker.register(`/sw.js?v=${buildId}`, {
          scope: "/",
          updateViaCache: "none",
        });
        if (disposed) return;
        showWaitingUpdate(registration.waiting);
        registration.addEventListener("updatefound", onUpdateFound);
        onUpdateFound();
        await registration.update();
      } catch {
        // Brak service workera nie może blokować logowania ani pracy w aplikacji.
      }
    };

    if (document.readyState === "complete") void register();
    else window.addEventListener("load", register, { once: true });

    return () => {
      disposed = true;
      window.removeEventListener("load", register);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      navigator.serviceWorker.removeEventListener("controllerchange", onControllerChange);
      registration?.removeEventListener("updatefound", onUpdateFound);
      installingWorker?.removeEventListener("statechange", onInstallingStateChange);
    };
  }, []);

  const dismissInstall = () => {
    rememberInstallSuggestionDismissed(window.localStorage);
    setShowInstallOffer(false);
    setShowIosHelp(false);
  };

  const install = async () => {
    if (!installPrompt) {
      setShowIosHelp(true);
      return;
    }
    await installPrompt.prompt();
    const choice = await installPrompt.userChoice;
    setInstallPrompt(null);
    if (choice.outcome === "accepted") {
      setShowInstallOffer(false);
    } else {
      dismissInstall();
    }
  };

  const applyUpdate = () => {
    if (!waitingWorker) return;
    reloadRequested.current = true;
    setApplyingUpdate(true);
    waitingWorker.postMessage({ type: "SKIP_WAITING" });
  };

  if (waitingWorker && !updateHidden) {
    return (
      <aside className="pwa-install pwa-update" aria-label="Aktualizacja aplikacji SZAFUNEK" role="status">
        <div className="pwa-install-mark" aria-hidden="true"><img src="/icons/szafunek-192.png" alt="" /></div>
        <span className="pwa-install-copy">
          <strong>Nowa wersja SZAFUNKU jest gotowa</strong>
          <small>Odśwież po zapisaniu bieżącej pracy.</small>
        </span>
        <button className="pwa-install-action" type="button" onClick={applyUpdate} disabled={applyingUpdate}>
          <RefreshCw size={17} />
          {applyingUpdate ? "Aktualizuję…" : "Odśwież aplikację"}
        </button>
        <button className="pwa-install-close" type="button" aria-label="Przypomnij o aktualizacji później" onClick={() => setUpdateHidden(true)}>
          <X size={17} />
        </button>
      </aside>
    );
  }

  if (installed || !showInstallOffer || (!installPrompt && !isIosSafari)) return null;

  return (
    <aside className="pwa-install" aria-label="Instalacja aplikacji SZAFUNEK">
      <div className="pwa-install-mark" aria-hidden="true"><img src="/icons/szafunek-192.png" alt="" /></div>
      <span className="pwa-install-copy">
        <strong>Zainstaluj SZAFUNEK</strong>
        <small>{isIosSafari ? "Dodaj aplikację do ekranu początkowego." : "Uruchamiaj jak aplikację — bez sklepu i bez opłat."}</small>
      </span>
      <button className="pwa-install-action" type="button" onClick={() => void install()}>
        {isIosSafari ? <Share2 size={17} /> : <Download size={17} />}
        {isIosSafari ? "Jak dodać" : "Zainstaluj"}
      </button>
      <button className="pwa-install-close" type="button" aria-label="Ukryj propozycję instalacji" onClick={dismissInstall}>
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
