import type { Metadata } from "next";
import { AppAuthProvider } from "@/components/AppAuthProvider";
import "./globals.css";
import "./complete.css";
import "./alpha11.css";
import "./alpha12.css";

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
