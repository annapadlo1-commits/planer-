"use client";

import { AlertTriangle, Cat, Check, X } from "lucide-react";
import dynamic from "next/dynamic";

const MemoryGame=dynamic(()=>import("@/components/games/MemoryGame").then(module=>module.MemoryGame),{
  ssr:false,
  loading:()=> <div className="cat-game-loading" role="status"><Cat/><strong>Rozkładam karty…</strong></div>,
});

export default function GeneratorMemoryExperience({ status, onClose, onViewSchedule }: {
  status: string;
  onClose: () => void;
  onViewSchedule: () => void;
}) {
  const ready = status === "READY";
  const failed = ["FAILED", "STALE_INPUT", "CANCELLED"].includes(status);
  return <section className="generator-memory-experience" aria-label="Memory podczas generowania">
    <header><span><small>GENERATOR PRACUJE NIEZALEŻNIE</small><h3>MEMORY Z KOTAMI</h3></span><button type="button" className="icon-button" aria-label="Zamknij Memory" onClick={onClose}><X/></button></header>
    {ready && <div className="generator-game-state ready" role="status"><Check/><span><strong>GRAFIK GOTOWY ✓</strong><small>Możesz przejść do wyniku teraz albo spokojnie dokończyć Memory.</small></span><button type="button" className="primary-button" onClick={onViewSchedule}>ZOBACZ GRAFIK</button></div>}
    {failed && <div className="generator-game-state failed" role="status"><AlertTriangle/><span><strong>Generator zakończył pracę bez gotowego grafiku</strong><small>Memory pozostaje otwarte. Szczegóły i dotychczasowy komunikat błędu są w panelu generatora.</small></span></div>}
    {!ready && !failed && <div className="generator-game-state running"><span className="generator-game-dot"/><span><strong>Jeszcze mielę grafik…</strong><small>Gra nie zatrzymuje ani nie resetuje obliczeń.</small></span></div>}
    <MemoryGame compact/>
  </section>;
}
