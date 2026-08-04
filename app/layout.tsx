import type { Metadata } from "next";
import { AppAuthProvider } from "@/components/AppAuthProvider";
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

export const metadata: Metadata = {
  title: "GRAFIK PRO 3.0",
  description: "Planowanie zespołu, budżetu i operacji",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="pl">
      <body><AppAuthProvider>{children}</AppAuthProvider></body>
    </html>
  );
}
