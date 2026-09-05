export type MemoryCard = { id: string; pairId: number; catNumber: number };

export function shuffleItems<T>(items: readonly T[], random: () => number = Math.random): T[] {
  const result = [...items];
  for (let index = result.length - 1; index > 0; index -= 1) {
    const target = Math.floor(random() * (index + 1));
    [result[index], result[target]] = [result[target], result[index]];
  }
  return result;
}

export function createMemoryDeck(random: () => number = Math.random): MemoryCard[] {
  return shuffleItems(
    Array.from({ length: 6 }, (_, pairId) => [0, 1].map(copy => ({
      id: `${pairId + 1}-${copy}`,
      pairId: pairId + 1,
      catNumber: pairId + 1,
    }))).flat(),
    random,
  );
}

export type TicCell = "X" | "CAT" | null;
const TIC_LINES = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8],
  [0, 3, 6], [1, 4, 7], [2, 5, 8],
  [0, 4, 8], [2, 4, 6],
] as const;

export function ticWinner(board: readonly TicCell[]): TicCell | "DRAW" {
  for (const [a, b, c] of TIC_LINES) {
    if (board[a] && board[a] === board[b] && board[a] === board[c]) return board[a];
  }
  return board.every(Boolean) ? "DRAW" : null;
}

function completingMove(board: readonly TicCell[], player: Exclude<TicCell, null>) {
  for (const line of TIC_LINES) {
    const values = line.map(index => board[index]);
    if (values.filter(value => value === player).length === 2 && values.includes(null)) {
      return line[values.indexOf(null)];
    }
  }
  return -1;
}

export function chooseCatMove(board: readonly TicCell[], random: () => number = Math.random) {
  const win = completingMove(board, "CAT");
  if (win >= 0) return win;
  const block = completingMove(board, "X");
  if (block >= 0) return block;
  if (!board[4]) return 4;
  const corners = shuffleItems([0, 2, 6, 8].filter(index => !board[index]), random);
  if (corners.length) return corners[0];
  const open = board.map((value, index) => value ? -1 : index).filter(index => index >= 0);
  return open.length ? open[Math.floor(random() * open.length)] : -1;
}

export type MoveDirection = "up" | "down" | "left" | "right";
export type Grid2048 = number[][];

export function empty2048(): Grid2048 {
  return Array.from({ length: 4 }, () => Array(4).fill(0));
}

export function add2048Tile(grid: Grid2048, random: () => number = Math.random): Grid2048 {
  const open: Array<[number, number]> = [];
  grid.forEach((row, rowIndex) => row.forEach((value, columnIndex) => {
    if (!value) open.push([rowIndex, columnIndex]);
  }));
  if (!open.length) return grid.map(row => [...row]);
  const [row, column] = open[Math.floor(random() * open.length)];
  const next = grid.map(values => [...values]);
  next[row][column] = random() < 0.9 ? 2 : 4;
  return next;
}

export function create2048(random: () => number = Math.random): Grid2048 {
  return add2048Tile(add2048Tile(empty2048(), random), random);
}

function compress2048(row: readonly number[]) {
  const values = row.filter(Boolean);
  const output: number[] = [];
  let gained = 0;
  for (let index = 0; index < values.length; index += 1) {
    if (values[index] === values[index + 1]) {
      const value = values[index] * 2;
      output.push(value);
      gained += value;
      index += 1;
    } else output.push(values[index]);
  }
  while (output.length < 4) output.push(0);
  return { row: output, gained };
}

function transpose(grid: Grid2048): Grid2048 {
  return grid[0].map((_, column) => grid.map(row => row[column]));
}

export function move2048(grid: Grid2048, direction: MoveDirection) {
  let working = grid.map(row => [...row]);
  if (direction === "up" || direction === "down") working = transpose(working);
  if (direction === "right" || direction === "down") working = working.map(row => [...row].reverse());
  let gained = 0;
  working = working.map(row => {
    const merged = compress2048(row);
    gained += merged.gained;
    return merged.row;
  });
  if (direction === "right" || direction === "down") working = working.map(row => [...row].reverse());
  if (direction === "up" || direction === "down") working = transpose(working);
  const moved = working.some((row, rowIndex) => row.some((value, columnIndex) => value !== grid[rowIndex][columnIndex]));
  return { grid: working, gained, moved };
}

export function canMove2048(grid: Grid2048) {
  if (grid.some(row => row.some(value => value === 0))) return true;
  return (["up", "down", "left", "right"] as MoveDirection[]).some(direction => move2048(grid, direction).moved);
}

export type Point = { x: number; y: number };
export type SnakeDirection = "up" | "down" | "left" | "right";

export function randomSnakeFood(snake: readonly Point[], random: () => number = Math.random, size = 16): Point {
  const open: Point[] = [];
  for (let y = 0; y < size; y += 1) for (let x = 0; x < size; x += 1) {
    if (!snake.some(point => point.x === x && point.y === y)) open.push({ x, y });
  }
  return open[Math.floor(random() * open.length)] ?? { x: 0, y: 0 };
}

export function nextSnakeFrame(snake: readonly Point[], direction: SnakeDirection, food: Point, size = 16) {
  const delta: Record<SnakeDirection, Point> = {
    up: { x: 0, y: -1 }, down: { x: 0, y: 1 }, left: { x: -1, y: 0 }, right: { x: 1, y: 0 },
  };
  const head = snake[0];
  const nextHead = { x: head.x + delta[direction].x, y: head.y + delta[direction].y };
  const ate = nextHead.x === food.x && nextHead.y === food.y;
  const bodyToCheck = ate ? snake : snake.slice(0, -1);
  const collision = nextHead.x < 0 || nextHead.y < 0 || nextHead.x >= size || nextHead.y >= size
    || bodyToCheck.some(point => point.x === nextHead.x && point.y === nextHead.y);
  if (collision) return { snake: [...snake], ate: false, collision: true };
  return { snake: [nextHead, ...snake.slice(0, ate ? snake.length : snake.length - 1)], ate, collision: false };
}

export const SOLVED_PUZZLE = [1, 2, 3, 4, 5, 6, 7, 8, 0] as const;

export function movePuzzle(board: readonly number[], index: number) {
  const empty = board.indexOf(0);
  const adjacent = Math.abs(Math.floor(empty / 3) - Math.floor(index / 3)) + Math.abs((empty % 3) - (index % 3)) === 1;
  if (!adjacent) return [...board];
  const next = [...board];
  [next[empty], next[index]] = [next[index], next[empty]];
  return next;
}

export function shufflePuzzle(random: () => number = Math.random, steps = 120) {
  let board: number[] = [...SOLVED_PUZZLE];
  let previousEmpty = -1;
  for (let step = 0; step < steps; step += 1) {
    const empty = board.indexOf(0);
    const candidates = board.map((_, index) => index).filter(index => index !== previousEmpty
      && Math.abs(Math.floor(empty / 3) - Math.floor(index / 3)) + Math.abs((empty % 3) - (index % 3)) === 1);
    const selected = candidates[Math.floor(random() * candidates.length)];
    previousEmpty = empty;
    board = movePuzzle(board, selected);
  }
  return board.every((value, index) => value === SOLVED_PUZZLE[index]) ? movePuzzle(board, 7) : board;
}

export type SudokuLevel = "easy" | "medium" | "hard";
const SUDOKU: Record<SudokuLevel, string> = {
  easy: "530070000600195000098000060800060003400803001700020006060000280000419005000080079",
  medium: "000260701680070090190004500820100040004602900050003028009300074040050036703018000",
  hard: "000000907000420180000705026100904000050000040000507009920108000034059000507000000",
};
const sudokuSolutionCache = new Map<SudokuLevel, string>();

function solveSudoku(source: string) {
  const values = [...source].map(Number);
  const candidates = (index: number) => {
    const row = Math.floor(index / 9), column = index % 9;
    const used = new Set<number>();
    for (let offset = 0; offset < 9; offset += 1) {
      used.add(values[row * 9 + offset]);
      used.add(values[offset * 9 + column]);
      used.add(values[(Math.floor(row / 3) * 3 + Math.floor(offset / 3)) * 9 + Math.floor(column / 3) * 3 + (offset % 3)]);
    }
    return Array.from({ length: 9 }, (_, index) => index + 1).filter(value => !used.has(value));
  };
  const fill = (): boolean => {
    let selected = -1;
    let selectedCandidates: number[] = [];
    for (let index = 0; index < 81; index += 1) if (!values[index]) {
      const options = candidates(index);
      if (!options.length) return false;
      if (selected < 0 || options.length < selectedCandidates.length) {
        selected = index;
        selectedCandidates = options;
        if (options.length === 1) break;
      }
    }
    if (selected < 0) return true;
    for (const value of selectedCandidates) {
      values[selected] = value;
      if (fill()) return true;
    }
    values[selected] = 0;
    return false;
  };
  if (!fill()) throw new Error("SUDOKU_HAS_NO_SOLUTION");
  return values.join("");
}

export function createSudoku(level: SudokuLevel, seed = 0) {
  const puzzle = SUDOKU[level];
  const solution = sudokuSolutionCache.get(level) ?? solveSudoku(puzzle);
  sudokuSolutionCache.set(level, solution);
  const shift = ((seed % 9) + 9) % 9;
  const transform = (value: string) => value === "0" ? "" : String(((Number(value) - 1 + shift) % 9) + 1);
  return {
    puzzle: [...puzzle].map(transform),
    solution: [...solution].map(transform),
  };
}

export function sudokuConflicts(values: readonly string[]) {
  const conflicts = new Set<number>();
  const groups: number[][] = [];
  for (let index = 0; index < 9; index += 1) {
    groups.push(Array.from({ length: 9 }, (_, column) => index * 9 + column));
    groups.push(Array.from({ length: 9 }, (_, row) => row * 9 + index));
  }
  for (let boxRow = 0; boxRow < 3; boxRow += 1) for (let boxColumn = 0; boxColumn < 3; boxColumn += 1) {
    groups.push(Array.from({ length: 9 }, (_, offset) => (boxRow * 3 + Math.floor(offset / 3)) * 9 + boxColumn * 3 + (offset % 3)));
  }
  groups.forEach(group => {
    const seen = new Map<string, number>();
    group.forEach(index => {
      const value = values[index];
      if (!value) return;
      const previous = seen.get(value);
      if (previous !== undefined) { conflicts.add(previous); conflicts.add(index); }
      else seen.set(value, index);
    });
  });
  return conflicts;
}
