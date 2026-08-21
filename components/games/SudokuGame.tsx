"use client";

import { Check, Eraser, RefreshCw } from "lucide-react";
import { useMemo, useState } from "react";
import { createSudoku, sudokuConflicts, type SudokuLevel } from "@/lib/cat-games";

const LEVEL_LABELS: Record<SudokuLevel, string> = { easy: "ŁATWY", medium: "ŚREDNI", hard: "TRUDNY" };

export function SudokuGame() {
  const [level, setLevel] = useState<SudokuLevel>("easy");
  const [seed, setSeed] = useState(0);
  const game = useMemo(() => createSudoku(level, seed), [level, seed]);
  const [values, setValues] = useState(() => [...game.puzzle]);
  const [checked, setChecked] = useState(false);
  const conflicts = sudokuConflicts(values);
  const solved = values.every((value, index) => value === game.solution[index]);

  const load = (nextLevel: SudokuLevel, nextSeed: number) => {
    const next = createSudoku(nextLevel, nextSeed);
    setLevel(nextLevel);
    setSeed(nextSeed);
    setValues([...next.puzzle]);
    setChecked(false);
  };
  const reset = () => { setValues([...game.puzzle]); setChecked(false); };
  const update = (index: number, input: string) => {
    if (game.puzzle[index]) return;
    const value = input.replace(/[^1-9]/g, "").slice(-1);
    setValues(current => current.map((item, position) => position === index ? value : item));
    setChecked(false);
  };

  return <section className="cat-sudoku-game" aria-label="Sudoku">
    <header className="cat-game-status"><div className="cat-sudoku-levels">{(Object.keys(LEVEL_LABELS) as SudokuLevel[]).map(item => <button type="button" key={item} className={level === item ? "active" : ""} onClick={() => load(item, seed + 1)}>{LEVEL_LABELS[item]}</button>)}</div><button type="button" className="secondary-button" onClick={() => load(level, seed + 1)}><RefreshCw/> Nowa plansza</button></header>
    <div className="cat-sudoku-board">{values.map((value, index) => {
      const wrong = checked && value && value !== game.solution[index];
      return <input key={index} aria-label={`Sudoku wiersz ${Math.floor(index / 9) + 1}, kolumna ${(index % 9) + 1}`} inputMode="numeric" pattern="[1-9]*" maxLength={1} readOnly={Boolean(game.puzzle[index])} className={`${game.puzzle[index] ? "fixed" : ""} ${conflicts.has(index) || wrong ? "conflict" : ""}`} value={value} onChange={event => update(index, event.target.value)}/>;
    })}</div>
    <div className="cat-sudoku-actions"><button type="button" className="secondary-button" onClick={reset}><Eraser/> Reset</button><button type="button" className="primary-button" onClick={() => setChecked(true)}><Check/> Sprawdź rozwiązanie</button></div>
    {checked && <p className={solved ? "cat-sudoku-success" : "cat-sudoku-hint"} role="status">{solved ? "SUDOKU ROZWIĄZANE ✓" : conflicts.size ? "Niektóre cyfry powtarzają się w wierszu, kolumnie albo kwadracie." : "Jeszcze nie gotowe — popraw zaznaczone pola albo uzupełnij puste."}</p>}
  </section>;
}
