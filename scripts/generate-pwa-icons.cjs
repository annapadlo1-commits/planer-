const sharp = require("sharp");

const source = "public/icons/grafik-pro.svg";
const outputs = [
  ["public/icons/grafik-pro-192.png", 192],
  ["public/icons/grafik-pro-512.png", 512],
  ["public/icons/apple-touch-icon.png", 180],
];

Promise.all([
  ...outputs.map(([path, size]) => sharp(source).resize(size, size).png().toFile(path)),
  sharp(source).resize(512, 512).flatten({ background: "#7457e8" }).png().toFile("public/icons/grafik-pro-maskable-512.png"),
]).then(() => console.log(`Wygenerowano ${outputs.length + 1} ikony PWA.`));
