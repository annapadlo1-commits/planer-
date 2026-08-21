"use client";

import dynamic from "next/dynamic";
import { Blocks, Cat, ChevronLeft, CircleDot, Grid3X3, Hash, Puzzle, Sparkles } from "lucide-react";
import { useState } from "react";

const MemoryGame = dynamic(() => import("@/components/games/MemoryGame").then(module => module.MemoryGame), { ssr: false, loading: GameLoading });
const TicTacToeGame = dynamic(() => import("@/components/games/TicTacToeGame").then(module => module.TicTacToeGame), { ssr: false, loading: GameLoading });
const Game2048 = dynamic(() => import("@/components/games/Game2048").then(module => module.Game2048), { ssr: false, loading: GameLoading });
const SnakeGame = dynamic(() => import("@/components/games/SnakeGame").then(module => module.SnakeGame), { ssr: false, loading: GameLoading });
const PuzzleGame = dynamic(() => import("@/components/games/PuzzleGame").then(module => module.PuzzleGame), { ssr: false, loading: GameLoading });
const SudokuGame = dynamic(() => import("@/components/games/SudokuGame").then(module => module.SudokuGame), { ssr: false, loading: GameLoading });

type GameKey = "memory" | "tic" | "2048" | "snake" | "puzzle" | "sudoku";
const GAMES: Array<{ key: GameKey; name: string; detail: string; icon: typeof Cat }> = [
  { key: "memory", name: "MEMORY", detail: "Znajdź 6 par kotów", icon: Cat },
  { key: "tic", name: "KÓŁKO I KRZYŻYK", detail: "Ty kontra kot", icon: CircleDot },
  { key: "2048", name: "2048", detail: "Łącz liczby", icon: Hash },
  { key: "snake", name: "SNAKE", detail: "Nakarm kota", icon: Blocks },
  { key: "puzzle", name: "PUZZLE", detail: "Ułóż obrazek 3×3", icon: Puzzle },
  { key: "sudoku", name: "SUDOKU", detail: "Łatwy, średni lub trudny", icon: Grid3X3 },
];

function GameLoading() {
  return <div className="cat-game-loading" role="status"><Cat/><strong>Ładuję grę…</strong></div>;
}

export default function CatGameHub() {
  const [active, setActive] = useState<GameKey | null>(null);
  const selected = GAMES.find(game => game.key === active);
  return <section className="cat-game-hub" aria-label="PYKNIJ SE — gry pracownika">
    <header><span className="cat-game-hub-mark"><Cat/></span><span><small>KĄCIK KOTA</small><h3>PYKNIJ SE</h3><p>Sześć małych gier na chwilę przerwy. Wyniki zostają tylko w tej przeglądarce.</p></span><Sparkles/></header>
    {!active ? <div className="cat-game-tiles">{GAMES.map(game => { const Icon = game.icon; return <button type="button" key={game.key} onClick={() => setActive(game.key)}><span><Icon/></span><b>{game.name}</b><small>{game.detail}</small></button>; })}</div> : <div className="cat-game-stage">
      <header><button type="button" className="secondary-button" onClick={() => setActive(null)}><ChevronLeft/> Wróć do gier</button><span><small>PYKNIJ SE</small><h4>{selected?.name}</h4></span></header>
      {active === "memory" && <MemoryGame/>}
      {active === "tic" && <TicTacToeGame/>}
      {active === "2048" && <Game2048/>}
      {active === "snake" && <SnakeGame/>}
      {active === "puzzle" && <PuzzleGame/>}
      {active === "sudoku" && <SudokuGame/>}
    </div>}
  </section>;
}
