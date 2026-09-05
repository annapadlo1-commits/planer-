export type AppColor = {
  name: string;
  hex: `#${string}`;
};

export const APP_COLOR_PALETTE: readonly AppColor[] = [
  { name: "Graphite Black", hex: "#1A1A1A" },
  { name: "Charcoal", hex: "#2A2A28" },
  { name: "Warm Paper", hex: "#E8E1D6" },
  { name: "Dirty Cream", hex: "#F2EDE4" },
  { name: "Dusty Sage", hex: "#A6B3A0" },
  { name: "Muted Olive", hex: "#879681" },
  { name: "Deep Moss", hex: "#55665A" },
  { name: "Faded Mint", hex: "#C4D2C4" },
  { name: "Dusty Peach", hex: "#D9987E" },
  { name: "Terracotta", hex: "#C96F54" },
  { name: "Burnt Orange", hex: "#B85F3F" },
  { name: "Sand", hex: "#CBBFAE" },
  { name: "Taupe", hex: "#9C9184" },
  { name: "Dirty White", hex: "#F7F3EC" },
  { name: "Ink Green", hex: "#33443B" },
  { name: "Washed Red", hex: "#B85E58" },
  { name: "Sage Gray", hex: "#BBC3B7" },
  { name: "Lichen", hex: "#9AAA8F" },
  { name: "Forest Ink", hex: "#2B3A32" },
  { name: "Clay Rose", hex: "#C98274" },
  { name: "Pale Peach", hex: "#E6B39C" },
  { name: "Toasted Sand", hex: "#B8A994" },
  { name: "Smoke Taupe", hex: "#756D65" },
  { name: "Paper Gray", hex: "#D7D0C7" },
] as const;

export const APP_COLOR_LABELS = APP_COLOR_PALETTE.map(({ name, hex }) => `${name} — ${hex}`);

export const DEFAULT_ROLE_COLOR = "#55665A";
export const DEFAULT_DUTY_COLOR = "#879681";
export const DEFAULT_SCENARIO_COLOR = "#C96F54";
export const DEFAULT_SHIFT_MARKER_COLOR = "#879681";

export function uiSafeColor(value: string | null | undefined, fallback = DEFAULT_ROLE_COLOR) {
  const color = String(value ?? "").trim();
  const match = /^#([0-9a-f]{6})$/i.exec(color);
  if (!match) return fallback;
  const rgb = [0, 2, 4].map(index => Number.parseInt(match[1].slice(index, index + 2), 16) / 255);
  const maximum = Math.max(...rgb), minimum = Math.min(...rgb), delta = maximum - minimum;
  const lightness = (maximum + minimum) / 2;
  const saturation = delta === 0 ? 0 : delta / (1 - Math.abs(2 * lightness - 1));
  let hue = 0;
  if (delta !== 0) {
    if (maximum === rgb[0]) hue = 60 * (((rgb[1] - rgb[2]) / delta) % 6);
    else if (maximum === rgb[1]) hue = 60 * ((rgb[2] - rgb[0]) / delta + 2);
    else hue = 60 * ((rgb[0] - rgb[1]) / delta + 4);
    if (hue < 0) hue += 360;
  }
  return hue >= 245 && hue <= 325 && saturation >= .18 ? fallback : color.toUpperCase();
}
