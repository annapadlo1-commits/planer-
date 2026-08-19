import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    id: "/",
    name: "SZAFUNEK",
    short_name: "SZAFUNEK",
    description: "Planowanie zespołu, budżetu i operacji",
    start_url: "/?source=pwa",
    scope: "/",
    display: "standalone",
    orientation: "any",
    background_color: "#f5f2ed",
    theme_color: "#33203f",
    lang: "pl",
    categories: ["business", "productivity"],
    icons: [
      {
        src: "/icons/szafunek-192.png",
        sizes: "192x192",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icons/szafunek-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icons/szafunek-maskable-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable",
      },
    ],
  };
}
