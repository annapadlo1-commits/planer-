import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = relative => readFile(new URL(`../${relative}`, import.meta.url), "utf8");

test("B4F-148–154 expose six isolated games only in the employee profile", async () => {
  const [profile, hub] = await Promise.all([read("components/PersonalWorkspace.tsx"), read("components/games/CatGameHub.tsx")]);
  assert.match(profile, /dynamic\(\(\)=>import\("@\/components\/games\/CatGameHub"\)/);
  assert.match(profile, /!management&&<LazyCatGameHub\/>/);
  for (const file of ["MemoryGame", "TicTacToeGame", "Game2048", "SnakeGame", "PuzzleGame", "SudokuGame"]) {
    assert.match(hub, new RegExp(`dynamic\\(\\(\\) => import\\(\"@/components/games/${file}\"\\)`));
  }
  for (const label of ["MEMORY", "KÓŁKO I KRZYŻYK", "2048", "SNAKE", "PUZZLE", "SUDOKU"]) assert.match(hub, new RegExp(label));
});

test("B4F-155 shows the generator prompt once and reuses the same Memory implementation", async () => {
  const [solver, hub, experience] = await Promise.all([
    read("components/SolverV2Panel.tsx"), read("components/games/CatGameHub.tsx"), read("components/games/GeneratorMemoryExperience.tsx"),
  ]);
  assert.match(solver, /szafunek_memory_generator_prompt_seen/);
  assert.ok(solver.indexOf("localStorage.setItem(GENERATOR_MEMORY_PROMPT_KEY") < solver.indexOf("setMemoryPromptOpen(true)"));
  assert.match(solver, /pss, zagramy\?/);
  assert.match(solver, /NIE, PATRZĘ JAK MIELISZ/);
  assert.match(solver, /run&&memoryGameOpen&&<LazyGeneratorMemoryExperience/);
  assert.match(experience, /GRAFIK GOTOWY ✓/);
  assert.match(experience, /MemoryGame compact/);
  assert.match(hub, /import\("@\/components\/games\/MemoryGame"\)/);
  assert.match(experience, /import\("@\/components\/games\/MemoryGame"\)/);
});

test("B4F-156 keeps game runtime local, dependency-free and mobile-safe", async () => {
  const files = [
    "lib/cat-games.ts", "components/games/CatGameHub.tsx", "components/games/MemoryGame.tsx",
    "components/games/TicTacToeGame.tsx", "components/games/Game2048.tsx", "components/games/SnakeGame.tsx",
    "components/games/PuzzleGame.tsx", "components/games/SudokuGame.tsx", "components/games/GeneratorMemoryExperience.tsx",
  ];
  const source = (await Promise.all(files.map(read))).join("\n");
  assert.doesNotMatch(source, /createSupabase|\.rpc\(|supabase|WebSocket|fetch\(/i);
  assert.doesNotMatch(source, /from "(?!@\/|react|lucide-react|next\/dynamic)[^"]+"/);
  const css = await read("app/cat-games.css");
  assert.match(css, /touch-action:none/);
  assert.match(css, /@media\(max-width:480px\)/);
  assert.match(css, /prefers-reduced-motion/);
});
