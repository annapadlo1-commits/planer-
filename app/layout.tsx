import type { Metadata, Viewport } from "next";
import { AppAuthProvider } from "@/components/AppAuthProvider";
import { PwaInstall } from "@/components/PwaInstall";
import "./globals.css";
import "./complete.css";
import "./uat-overhaul.css";
import "./alpha11.css";
import "./alpha12.css";
import "./solver-v2.css";
import "./role-composite.css";
import "./matrix-v2.css";
import "./alpha16.css";
import "./standby-manager.css";
import "./product-journey.css";
import "./recovery-center.css";
import "./next-batch.css";
import "./desktop-compact.css";
import "./brand-streetart.css";
import "./personal-workspace.css";
import "./cat-games.css";
import "./mobile-hardening.css";

export const metadata: Metadata = {
  title: {
    default: "SZAFUNEK",
    template: "%s • SZAFUNEK",
  },
  description: "Planowanie zespołu, budżetu i operacji",
  applicationName: "SZAFUNEK",
  manifest: "/manifest.webmanifest",
  appleWebApp: {
    capable: true,
    statusBarStyle: "black-translucent",
    title: "SZAFUNEK",
  },
  formatDetection: {
    telephone: false,
  },
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "any" },
      { url: "/icons/favicon-16.png", sizes: "16x16", type: "image/png" },
      { url: "/icons/favicon-32.png", sizes: "32x32", type: "image/png" },
    ],
    apple: [{ url: "/icons/apple-touch-icon.png", sizes: "180x180", type: "image/png" }],
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#1F2A27",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="pl">
      <body>
        <AppAuthProvider>{children}</AppAuthProvider>
        <PwaInstall />
      </body>
    </html>
  );
}
