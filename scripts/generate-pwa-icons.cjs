const sharp = require("sharp");

const source = "public/icons/szafunek.svg";
const outputs = [
  ["public/icons/szafunek-192.png", 192],
  ["public/icons/szafunek-512.png", 512],
  ["public/icons/apple-touch-icon.png", 180],
];

Promise.all([
  ...outputs.map(([path, size]) => sharp(source).resize(size, size).png().toFile(path)),
  sharp(source).resize(512, 512).flatten({ background: "#7457e8" }).png().toFile("public/icons/szafunek-maskable-512.png"),
]).then(() => console.log(`Wygenerowano ${outputs.length + 1} ikony PWA.`));
