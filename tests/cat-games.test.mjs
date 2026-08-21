import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import ts from "typescript";

async function loadGames() {
  const source = await readFile(new URL("../lib/cat-games.ts", import.meta.url), "utf8");
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(output).toString("base64")}`);
}

test("Memory creates exactly six shuffled pairs", async () => {
  const { createMemoryDeck } = await loadGames();
  let value = 0;
  const deck = createMemoryDeck(() => (value = (value + 0.37) % 1));
  assert.equal(deck.length, 12);
  assert.equal(new Set(deck.map(card => card.id)).size, 12);
  for (let pair = 1; pair <= 6; pair += 1) assert.equal(deck.filter(card => card.pairId === pair).length, 2);
});

test("the cat in tic-tac-toe wins first and otherwise blocks the employee", async () => {
  const { chooseCatMove, ticWinner } = await loadGames();
  assert.equal(chooseCatMove(["CAT", "CAT", null, "X", "X", null, null, null, null]), 2);
  assert.equal(chooseCatMove(["X", "X", null, "CAT", null, null, null, null, null]), 2);
  assert.equal(ticWinner(["X", "X", "X", null, "CAT", null, null, null, "CAT"]), "X");
  assert.equal(ticWinner(["X", "CAT", "X", "X", "CAT", "CAT", "CAT", "X", "X"]), "DRAW");
});

test("2048 merges each tile once and detects terminal boards", async () => {
  const { move2048, canMove2048 } = await loadGames();
  const moved = move2048([
    [2, 2, 2, 2], [0, 2, 0, 2], [4, 0, 4, 4], [0, 0, 0, 0],
  ], "left");
  assert.deepEqual(moved.grid[0], [4, 4, 0, 0]);
  assert.deepEqual(moved.grid[1], [4, 0, 0, 0]);
  assert.deepEqual(moved.grid[2], [8, 4, 0, 0]);
  assert.equal(moved.gained, 20);
  assert.equal(canMove2048([[2,4,2,4],[4,2,4,2],[2,4,2,4],[4,2,4,2]]), false);
});

test("Snake grows on food and reports wall or body collision", async () => {
  const { nextSnakeFrame } = await loadGames();
  const snake = [{ x: 2, y: 2 }, { x: 1, y: 2 }, { x: 0, y: 2 }];
  const ate = nextSnakeFrame(snake, "right", { x: 3, y: 2 }, 5);
  assert.equal(ate.ate, true);
  assert.equal(ate.snake.length, 4);
  assert.equal(nextSnakeFrame([{ x: 0, y: 0 }], "left", { x: 4, y: 4 }, 5).collision, true);
});

test("sliding puzzle stays solvable and only moves a tile next to the empty cell", async () => {
  const { movePuzzle, shufflePuzzle, SOLVED_PUZZLE } = await loadGames();
  assert.deepEqual(movePuzzle(SOLVED_PUZZLE, 0), [...SOLVED_PUZZLE]);
  assert.deepEqual(movePuzzle(SOLVED_PUZZLE, 7), [1,2,3,4,5,6,7,0,8]);
  const shuffled = shufflePuzzle(() => 0.2, 20);
  assert.deepEqual([...shuffled].sort((a,b) => a-b), [0,1,2,3,4,5,6,7,8]);
  assert.notDeepEqual(shuffled, [...SOLVED_PUZZLE]);
});

test("all Sudoku levels keep fixed clues consistent and conflict detection covers rows", async () => {
  const { createSudoku, sudokuConflicts } = await loadGames();
  for (const level of ["easy", "medium", "hard"]) {
    const game = createSudoku(level, 4);
    assert.equal(game.puzzle.length, 81);
    assert.equal(game.solution.length, 81);
    game.puzzle.forEach((value, index) => { if (value) assert.equal(value, game.solution[index], `${level} clue ${index}`); });
  }
  const values = Array(81).fill("");
  values[0] = values[1] = "7";
  assert.deepEqual([...sudokuConflicts(values)].sort((a,b) => a-b), [0, 1]);
});
