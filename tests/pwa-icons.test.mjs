import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { inflateSync } from "node:zlib";

function decodePng(relativePath) {
  const bytes = readFileSync(new URL(`../${relativePath}`, import.meta.url));
  assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  let offset = 8;
  let width;
  let height;
  let bitDepth;
  let colorType;
  let interlace;
  const idat = [];
  while (offset < bytes.length) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.subarray(offset + 4, offset + 8).toString("ascii");
    const data = bytes.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === "IDAT") idat.push(data);
    offset += length + 12;
    if (type === "IEND") break;
  }
  assert.equal(bitDepth, 8);
  assert.ok(colorType === 2 || colorType === 6, `unsupported PNG color type ${colorType}`);
  assert.equal(interlace, 0);

  const channels = colorType === 6 ? 4 : 3;
  const stride = width * channels;
  const raw = inflateSync(Buffer.concat(idat));
  const pixels = Buffer.alloc(width * height * channels);
  const paeth = (a, b, c) => {
    const p = a + b - c;
    const pa = Math.abs(p - a);
    const pb = Math.abs(p - b);
    const pc = Math.abs(p - c);
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
  };
  for (let y = 0; y < height; y += 1) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x += 1) {
      const source = raw[y * (stride + 1) + 1 + x];
      const left = x >= channels ? pixels[y * stride + x - channels] : 0;
      const up = y > 0 ? pixels[(y - 1) * stride + x] : 0;
      const upLeft = y > 0 && x >= channels ? pixels[(y - 1) * stride + x - channels] : 0;
      const value = filter === 0 ? source
        : filter === 1 ? source + left
          : filter === 2 ? source + up
            : filter === 3 ? source + Math.floor((left + up) / 2)
              : source + paeth(left, up, upLeft);
      pixels[y * stride + x] = value & 255;
    }
  }
  return { bytes, width, height, channels, pixels };
}

function pixel(image, x, y) {
  const offset = (y * image.width + x) * image.channels;
  return [
    image.pixels[offset],
    image.pixels[offset + 1],
    image.pixels[offset + 2],
    image.channels === 4 ? image.pixels[offset + 3] : 255,
  ];
}

test("PWA and Apple icons have exact dimensions and fully opaque canvases", () => {
  for (const [path, size] of [
    ["public/icons/szafunek-192.png", 192],
    ["public/icons/szafunek-512.png", 512],
    ["public/icons/szafunek-maskable-512.png", 512],
    ["public/icons/apple-touch-icon.png", 180],
  ]) {
    const image = decodePng(path);
    assert.equal(image.width, size, path);
    assert.equal(image.height, size, path);
    if (image.channels === 4) {
      for (let i = 3; i < image.pixels.length; i += 4) assert.equal(image.pixels[i], 255, `${path} contains transparency`);
    }
  }
});

test("maskable icon is a distinct full-bleed asset with a protected foreground", () => {
  const normal = decodePng("public/icons/szafunek-512.png");
  const maskable = decodePng("public/icons/szafunek-maskable-512.png");
  const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
  assert.notEqual(hash(normal.bytes), hash(maskable.bytes));

  const background = pixel(maskable, 0, 0).slice(0, 3);
  assert.deepEqual(background, [246, 244, 239]);
  let minX = maskable.width;
  let minY = maskable.height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < maskable.height; y += 1) {
    for (let x = 0; x < maskable.width; x += 1) {
      const rgb = pixel(maskable, x, y);
      const different = rgb.slice(0, 3).some((value, index) => Math.abs(value - background[index]) > 12);
      if (different) {
        minX = Math.min(minX, x);
        minY = Math.min(minY, y);
        maxX = Math.max(maxX, x);
        maxY = Math.max(maxY, y);
      }
    }
  }
  assert.ok(minX >= 48 && minY >= 48, `foreground starts too close to edge: ${minX},${minY}`);
  assert.ok(maxX <= 463 && maxY <= 463, `foreground ends too close to edge: ${maxX},${maxY}`);
});

test("favicon contains 16, 32, 48 and 64 pixel PNG entries", () => {
  const bytes = readFileSync(new URL("../public/favicon.ico", import.meta.url));
  assert.equal(bytes.readUInt16LE(0), 0);
  assert.equal(bytes.readUInt16LE(2), 1);
  const count = bytes.readUInt16LE(4);
  const sizes = [];
  for (let index = 0; index < count; index += 1) {
    const offset = 6 + index * 16;
    sizes.push(bytes[offset] || 256);
    const imageOffset = bytes.readUInt32LE(offset + 12);
    assert.equal(bytes.subarray(imageOffset, imageOffset + 8).toString("hex"), "89504e470d0a1a0a");
  }
  assert.deepEqual(sizes, [16, 32, 48, 64]);
});
