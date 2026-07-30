import type { Metadata } from "next";
import { AppAuthProvider } from "@/components/AppAuthProvider";
import "./globals.css";

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
