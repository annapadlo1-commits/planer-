import { readdir, readFile, writeFile } from "node:fs/promises";
import { extname, join, relative } from "node:path";

const roots = ["app", "components", "lib"];
const extensions = new Set([".css", ".ts", ".tsx"]);
const write = process.argv.includes("--write");

function hsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const lightness = (max + min) / 2;
  if (max === min) return { hue: 0, saturation: 0, lightness };
  const delta = max - min;
  const saturation = lightness > .5 ? delta / (2 - max - min) : delta / (max + min);
  let hue = max === r ? (g - b) / delta + (g < b ? 6 : 0) : max === g ? (b - r) / delta + 2 : (r - g) / delta + 4;
  hue *= 60;
  return { hue, saturation, lightness };
}

function legacyPurple(r, g, b) {
  const color = hsl(r, g, b);
  return color.hue >= 245 && color.hue <= 325 && color.saturation >= .18;
}

function replacement(lightness) {
  if (lightness < .28) return "#33443B";
  if (lightness < .48) return "#55665A";
  if (lightness < .66) return "#879681";
  if (lightness < .82) return "#A6B3A0";
  if (lightness < .93) return "#C4D2C4";
  return "#F2EDE4";
}

function rewrite(source) {
  let changed = source.replace(/#[0-9a-fA-F]{6}\b/g, value => {
    const r = Number.parseInt(value.slice(1, 3), 16), g = Number.parseInt(value.slice(3, 5), 16), b = Number.parseInt(value.slice(5, 7), 16);
    return legacyPurple(r, g, b) ? replacement(hsl(r, g, b).lightness) : value;
  });
  changed = changed.replace(/rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(\s*,\s*(?:0|1|0?\.\d+))?\s*\)/g, (value, rText, gText, bText, alpha = "") => {
    const r = Number(rText), g = Number(gText), b = Number(bText);
    if (!legacyPurple(r, g, b)) return value;
    const hex = replacement(hsl(r, g, b).lightness);
    const nr = Number.parseInt(hex.slice(1, 3), 16), ng = Number.parseInt(hex.slice(3, 5), 16), nb = Number.parseInt(hex.slice(5, 7), 16);
    return alpha ? `rgba(${nr},${ng},${nb}${alpha})` : `rgb(${nr},${ng},${nb})`;
  });
  changed = changed
    .replaceAll("shift.color??DEFAULT_SHIFT_MARKER_COLOR", "uiSafeColor(shift.color,DEFAULT_SHIFT_MARKER_COLOR)")
    .replaceAll("role.color??DEFAULT_ROLE_COLOR", "uiSafeColor(role.color,DEFAULT_ROLE_COLOR)")
    .replaceAll("item.color ?? DEFAULT_ROLE_COLOR", "uiSafeColor(item.color,DEFAULT_ROLE_COLOR)")
    .replaceAll("scenario.color ?? DEFAULT_SCENARIO_COLOR", "uiSafeColor(scenario.color,DEFAULT_SCENARIO_COLOR)")
    .replaceAll("String(item?.color ?? DEFAULT_SHIFT_MARKER_COLOR)", "uiSafeColor(String(item?.color ?? \"\"),DEFAULT_SHIFT_MARKER_COLOR)");
  return changed;
}

async function files(path) {
  const entries = await readdir(path, { withFileTypes: true });
  const result = [];
  for (const entry of entries) {
    const target = join(path, entry.name);
    if (entry.isDirectory()) result.push(...await files(target));
    else if (extensions.has(extname(entry.name))) result.push(target);
  }
  return result;
}

const findings = [];
for (const root of roots) {
  for (const file of await files(root)) {
    const source = await readFile(file, "utf8");
    const rewritten = rewrite(source);
    if (rewritten === source) continue;
    findings.push(relative(process.cwd(), file));
    if (write) await writeFile(file, rewritten, "utf8");
  }
}

if (findings.length) {
  if (!write) {
    console.error(`Pozostałości starego fioletowego UI: ${findings.join(", ")}`);
    process.exitCode = 1;
  } else {
    console.log(`Zastąpiono stare kolory w ${findings.length} plikach.`);
  }
} else {
  console.log("Brak literalnych fioletowych/liliowych kolorów UI.");
}
