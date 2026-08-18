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

export const metadata: Metadata = {
  title: {
    default: "GRAFIK PRO",
    template: "%s • GRAFIK PRO",
  },
  description: "Planowanie zespołu, budżetu i operacji",
  applicationName: "GRAFIK PRO",
  manifest: "/manifest.webmanifest",
  appleWebApp: {
    capable: true,
    statusBarStyle: "black-translucent",
    title: "GRAFIK PRO",
  },
  formatDetection: {
    telephone: false,
  },
  icons: {
    icon: [
      { url: "/icons/grafik-pro-192.png", sizes: "192x192", type: "image/png" },
      { url: "/icons/grafik-pro-512.png", sizes: "512x512", type: "image/png" },
    ],
    apple: [{ url: "/icons/apple-touch-icon.png", sizes: "180x180", type: "image/png" }],
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#33203f",
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
