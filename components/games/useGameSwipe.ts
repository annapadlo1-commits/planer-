"use client";

import { useRef } from "react";
import type { PointerEventHandler } from "react";
import type { MoveDirection } from "@/lib/cat-games";

export function useGameSwipe(onSwipe: (direction: MoveDirection) => void) {
  const start = useRef<{ x: number; y: number } | null>(null);
  const onPointerDown: PointerEventHandler<HTMLElement> = event => {
    start.current = { x: event.clientX, y: event.clientY };
    event.currentTarget.setPointerCapture?.(event.pointerId);
  };
  const onPointerUp: PointerEventHandler<HTMLElement> = event => {
    if (!start.current) return;
    const dx = event.clientX - start.current.x;
    const dy = event.clientY - start.current.y;
    start.current = null;
    if (Math.max(Math.abs(dx), Math.abs(dy)) < 24) return;
    onSwipe(Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"));
  };
  return {
    onPointerDown,
    onPointerUp,
    onPointerCancel: () => { start.current = null; },
  };
}
