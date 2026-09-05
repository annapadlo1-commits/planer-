"use client";

import { ChevronDown, ChevronLeft, ChevronRight, ChevronUp, Pause, Play, RotateCcw } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { nextSnakeFrame, randomSnakeFood, type MoveDirection, type Point, type SnakeDirection } from "@/lib/cat-games";
import { useGameSwipe } from "@/components/games/useGameSwipe";

const SIZE = 16;
const INITIAL_SNAKE: Point[] = [{ x: 8, y: 8 }, { x: 7, y: 8 }, { x: 6, y: 8 }];
const OPPOSITE: Record<SnakeDirection, SnakeDirection> = { up: "down", down: "up", left: "right", right: "left" };

export function SnakeGame() {
  const [snake, setSnake] = useState<Point[]>(INITIAL_SNAKE);
  const [food, setFood] = useState(() => randomSnakeFood(INITIAL_SNAKE));
  const [running, setRunning] = useState(false);
  const [gameOver, setGameOver] = useState(false);
  const direction = useRef<SnakeDirection>("right");
  const queuedDirection = useRef<SnakeDirection>("right");

  const steer = useCallback((next: MoveDirection) => {
    const value = next as SnakeDirection;
    if (OPPOSITE[direction.current] === value) return;
    queuedDirection.current = value;
    setRunning(true);
  }, []);
  const swipe = useGameSwipe(steer);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const keys: Record<string, SnakeDirection> = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" };
      if (!keys[event.key]) return;
      event.preventDefault();
      steer(keys[event.key]);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [steer]);

  useEffect(() => {
    if (!running || gameOver) return;
    const timer = window.setInterval(() => {
      direction.current = queuedDirection.current;
      setSnake(current => {
        const frame = nextSnakeFrame(current, direction.current, food, SIZE);
        if (frame.collision) { setGameOver(true); setRunning(false); return current; }
        if (frame.ate) setFood(randomSnakeFood(frame.snake));
        return frame.snake;
      });
    }, 150);
    return () => window.clearInterval(timer);
  }, [running, gameOver, food]);

  const reset = () => {
    direction.current = "right";
    queuedDirection.current = "right";
    setSnake(INITIAL_SNAKE);
    setFood(randomSnakeFood(INITIAL_SNAKE));
    setRunning(false);
    setGameOver(false);
  };
  const occupied = new Set(snake.map(point => `${point.x}-${point.y}`));
  return <section className="cat-snake-game" aria-label="Gra Snake">
    <header className="cat-game-status"><span><b>WYNIK {Math.max(0, snake.length - 3)}</b><small>{gameOver ? "Koniec gry" : running ? "Kot pędzi" : "Gotowy"}</small></span><div><button type="button" className="secondary-button" onClick={() => setRunning(value => !value)} disabled={gameOver}>{running ? <Pause/> : <Play/>}{running ? " Pauza" : " Start"}</button><button type="button" className="secondary-button" onClick={reset}><RotateCcw/> Reset</button></div></header>
    <div className="cat-snake-board game-touch-zone" {...swipe} tabIndex={0} aria-label="Plansza Snake. Użyj strzałek albo przesuń palcem.">
      {Array.from({ length: SIZE * SIZE }, (_, index) => { const x = index % SIZE, y = Math.floor(index / SIZE); const key = `${x}-${y}`; return <span className={occupied.has(key) ? index === snake[0].y * SIZE + snake[0].x ? "snake-head" : "snake-body" : food.x === x && food.y === y ? "snake-food" : ""} key={key}/>; })}
      {gameOver && <div className="cat-game-overlay"><strong>KOT WPADŁ NA ŚCIANĘ.</strong><button type="button" className="primary-button" onClick={reset}>JESZCZE RAZ</button></div>}
    </div>
    <div className="cat-snake-controls" aria-label="Sterowanie Snake"><i/><button type="button" onClick={() => steer("up")} aria-label="Góra"><ChevronUp/></button><i/><button type="button" onClick={() => steer("left")} aria-label="Lewo"><ChevronLeft/></button><button type="button" onClick={() => steer("down")} aria-label="Dół"><ChevronDown/></button><button type="button" onClick={() => steer("right")} aria-label="Prawo"><ChevronRight/></button></div>
  </section>;
}
