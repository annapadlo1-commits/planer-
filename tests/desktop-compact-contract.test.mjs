import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("desktop uses native compact dimensions without zooming or changing mobile",async()=>{
  const [layout,styles]=await Promise.all([
    readFile(new URL("../app/layout.tsx",import.meta.url),"utf8"),
    readFile(new URL("../app/desktop-compact.css",import.meta.url),"utf8"),
  ]);
  assert.match(layout,/import "\.\/desktop-compact\.css"/);
  assert.match(styles,/@media \(min-width:1101px\) and \(pointer:fine\)/);
  assert.match(styles,/\.product-shell \.workspace/);
  assert.match(styles,/\.leader-studio/);
  assert.doesNotMatch(styles,/\bzoom\s*:/i);
  assert.doesNotMatch(styles,/transform\s*:\s*scale/i);
  assert.doesNotMatch(styles,/@media\s*\(max-width/i);
});
