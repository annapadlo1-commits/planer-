"use client";

import { RotateCcw } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { add2048Tile, canMove2048, create2048, move2048, type MoveDirection } from "@/lib/cat-games";
import { useGameSwipe } from "@/components/games/useGameSwipe";

const BEST_KEY = "szafunek_2048_best";

export function Game2048() {
  const [grid, setGrid] = useState(() => create2048());
  const [score, setScore] = useState(0);
  const [best, setBest] = useState(0);
  const scoreRef = useRef(0);
  const gridRef = useRef(grid);

  useEffect(() => {
    try {
      const stored = Number(window.localStorage.getItem(BEST_KEY) || 0);
      if (Number.isFinite(stored)) setBest(stored);
    } catch {
      // Prywatny tryb przeglądarki może blokować localStorage; sama gra nadal działa.
    }
  }, []);

  const move = useCallback((direction: MoveDirection) => {
    const result = move2048(gridRef.current, direction);
    if (!result.moved) return;
    const nextScore = scoreRef.current + result.gained;
    const nextGrid = add2048Tile(result.grid);
    scoreRef.current = nextScore;
    gridRef.current = nextGrid;
    setScore(nextScore);
    setGrid(nextGrid);
    setBest(currentBest => {
      const nextBest = Math.max(currentBest, nextScore);
      try { window.localStorage.setItem(BEST_KEY, String(nextBest)); } catch { /* wynik pozostaje w pamięci bieżącej karty */ }
      return nextBest;
    });
  }, []);
  const swipe = useGameSwipe(move);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const keys: Record<string, MoveDirection> = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" };
      const direction = keys[event.key];
      if (!direction) return;
      event.preventDefault();
      move(direction);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [move]);

  const reset = () => { const next = create2048(); scoreRef.current = 0; gridRef.current = next; setGrid(next); setScore(0); };
  const gameOver = !canMove2048(grid);
  return <section className="cat-2048-game" aria-label="Gra 2048">
    <header className="cat-game-status"><span><b>WYNIK {score}</b><small>Najlepszy: {best}</small></span><button type="button" className="secondary-button" onClick={reset}><RotateCcw/> Nowa gra</button></header>
    <div className="cat-2048-board game-touch-zone" {...swipe} tabIndex={0} aria-label="Plansza 2048. Użyj strzałek albo przesuń palcem.">
      {grid.flatMap((row, rowIndex) => row.map((value, columnIndex) => <span className={value ? `tile tile-${Math.min(value, 2048)}` : "tile"} key={`${rowIndex}-${columnIndex}`}>{value || ""}</span>))}
      {gameOver && <div className="cat-game-overlay"><strong>KONIEC GRY</strong><button type="button" className="primary-button" onClick={reset}>ZAGRAJ JESZCZE RAZ</button></div>}
    </div>
    <p>Strzałki na komputerze. Na telefonie przesuń palcem po planszy.</p>
  </section>;
}
