"use client";

import { Cat, RotateCcw, X } from "lucide-react";
import { useEffect, useState } from "react";
import { chooseCatMove, ticWinner, type TicCell } from "@/lib/cat-games";

export function TicTacToeGame() {
  const [board, setBoard] = useState<TicCell[]>(Array(9).fill(null));
  const [catThinking, setCatThinking] = useState(false);
  const result = ticWinner(board);

  useEffect(() => {
    if (!catThinking || result) return;
    const timer = window.setTimeout(() => {
      setBoard(current => {
        const index = chooseCatMove(current);
        if (index < 0) return current;
        const next = [...current];
        next[index] = "CAT";
        return next;
      });
      setCatThinking(false);
    }, 320);
    return () => window.clearTimeout(timer);
  }, [catThinking, result]);

  const play = (index: number) => {
    if (board[index] || catThinking || result) return;
    const next = [...board];
    next[index] = "X";
    setBoard(next);
    if (!ticWinner(next)) setCatThinking(true);
  };
  const reset = () => { setBoard(Array(9).fill(null)); setCatThinking(false); };
  const label = result === "X" ? "WYGRYWASZ!" : result === "CAT" ? "KOT WYGRAŁ." : result === "DRAW" ? "REMIS." : catThinking ? "KOT MYŚLI…" : "TWÓJ RUCH";

  return <section className="cat-tic-game" aria-label="Kółko i krzyżyk przeciwko kotu">
    <div className="cat-game-status"><strong>{label}</strong><button type="button" className="secondary-button" onClick={reset}><RotateCcw/> Od nowa</button></div>
    <div className="cat-tic-board">{board.map((cell, index) => <button type="button" key={index} onClick={() => play(index)} aria-label={`Pole ${index + 1}${cell ? `: ${cell === "X" ? "krzyżyk" : "kot"}` : ""}`}>{cell === "X" ? <X/> : cell === "CAT" ? <Cat/> : null}</button>)}</div>
    <p>Ty grasz krzyżykiem. Kot próbuje wygrać, zablokować Cię albo zająć najlepsze wolne pole.</p>
  </section>;
}
