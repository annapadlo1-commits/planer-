"use client";

import { RotateCcw, Shuffle } from "lucide-react";
import { useState } from "react";
import type { CSSProperties } from "react";
import { movePuzzle, shufflePuzzle, SOLVED_PUZZLE } from "@/lib/cat-games";

function tileStyle(value: number): CSSProperties {
  const index = value - 1;
  return {
    backgroundImage: "url(/brand/szafunek-lockup-transparent.png)",
    backgroundSize: "300% 300%",
    backgroundPosition: `${(index % 3) / 2 * 100}% ${Math.floor(index / 3) / 2 * 100}%`,
  };
}

export function PuzzleGame() {
  const [board, setBoard] = useState(() => shufflePuzzle());
  const [moves, setMoves] = useState(0);
  const complete = moves > 0 && board.every((value, index) => value === SOLVED_PUZZLE[index]);
  const move = (index: number) => {
    const next = movePuzzle(board, index);
    if (next.every((value, position) => value === board[position])) return;
    setBoard(next);
    setMoves(value => value + 1);
  };
  const reset = () => { setBoard(shufflePuzzle()); setMoves(0); };
  return <section className="cat-puzzle-game" aria-label="Puzzle z logo kota SZAFUNKU">
    <header className="cat-game-status"><span><b>{moves} {moves === 1 ? "RUCH" : "RUCHÓW"}</b><small>Ułóż kota i napis SZAFUNEK</small></span><button type="button" className="secondary-button" onClick={reset}><Shuffle/> Wymieszaj</button></header>
    <div className="cat-puzzle-board">{board.map((value, index) => value ? <button type="button" key={value} style={tileStyle(value)} onClick={() => move(index)} aria-label={`Kafelek ${value}`}><small>{value}</small></button> : <span className="puzzle-empty" key="empty" aria-label="Puste pole"/>)}</div>
    {complete && <div className="cat-game-finish" role="status"><strong>OBRAZEK UŁOŻONY.</strong><b>{moves} RUCHÓW</b><button type="button" className="primary-button" onClick={reset}><RotateCcw/> UŁÓŻ JESZCZE RAZ</button></div>}
  </section>;
}
