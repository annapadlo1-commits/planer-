"use client";

import { Cat, RotateCcw } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { createMemoryDeck } from "@/lib/cat-games";

function catFace(catNumber: number): CSSProperties {
  const index = Math.max(0, Math.min(24, catNumber - 1));
  const column = index % 5;
  const row = Math.floor(index / 5);
  return {
    backgroundImage: "url(/profile-cats/cats-01-25-v3.png)",
    backgroundSize: "500% 500%",
    backgroundPosition: `${column / 4 * 100}% ${row / 4 * 100}%`,
  };
}

export function MemoryGame({ compact = false }: { compact?: boolean }) {
  const [deck, setDeck] = useState(() => createMemoryDeck());
  const [open, setOpen] = useState<string[]>([]);
  const [matched, setMatched] = useState<number[]>([]);
  const [moves, setMoves] = useState(0);
  const [startedAt, setStartedAt] = useState<number | null>(null);
  const [seconds, setSeconds] = useState(0);
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const complete = matched.length === 6;
  useEffect(() => {
    if (!startedAt || complete) return;
    const timer = window.setInterval(() => setSeconds(Math.floor((Date.now() - startedAt) / 1000)), 1000);
    return () => window.clearInterval(timer);
  }, [startedAt, complete]);

  useEffect(() => () => { if (closeTimer.current) clearTimeout(closeTimer.current); }, []);

  const reset = () => {
    if (closeTimer.current) clearTimeout(closeTimer.current);
    setDeck(createMemoryDeck());
    setOpen([]);
    setMatched([]);
    setMoves(0);
    setStartedAt(null);
    setSeconds(0);
  };

  const reveal = (id: string) => {
    const card = deck.find(item => item.id === id);
    if (!card || open.length >= 2 || open.includes(id) || matched.includes(card.pairId) || complete) return;
    if (!startedAt) setStartedAt(Date.now());
    const next = [...open, id];
    setOpen(next);
    if (next.length !== 2) return;
    setMoves(value => value + 1);
    const [first, second] = deck.filter(item => next.includes(item.id));
    if (first?.pairId === second?.pairId) {
      setMatched(current => [...current, first.pairId]);
      setOpen([]);
    } else {
      closeTimer.current = setTimeout(() => setOpen([]), 650);
    }
  };

  return <section className={`cat-memory-game ${compact ? "compact" : ""}`} aria-label="Memory z kotami SZAFUNKU">
    <header className="cat-game-status"><span><b>{moves} {moves === 1 ? "RUCH" : "RUCHÓW"}</b><small>{seconds} s</small></span><button type="button" className="secondary-button" onClick={reset}><RotateCcw/> Od nowa</button></header>
    <div className="cat-memory-board">
      {deck.map(card => {
        const visible = open.includes(card.id) || matched.includes(card.pairId);
        return <button type="button" key={card.id} className={`${visible ? "open" : ""} ${matched.includes(card.pairId) ? "matched" : ""}`} aria-label={visible ? `Kot ${card.catNumber}` : "Zakryta karta"} aria-pressed={visible} onClick={() => reveal(card.id)}>
          <span className="cat-memory-back"><Cat/></span><span className="cat-memory-face" style={catFace(card.catNumber)}/>
        </button>;
      })}
    </div>
    {complete && <div className="cat-game-finish" role="status"><Cat/><strong>KOTY ODNALEZIONE.</strong><b>{moves} RUCHÓW • {seconds} s</b><button type="button" className="primary-button" onClick={reset}>ZAGRAJ JESZCZE RAZ</button></div>}
  </section>;
}
