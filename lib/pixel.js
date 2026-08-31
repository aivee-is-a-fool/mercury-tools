// pixel.js — a pixel-grid toolkit for generators that draw rather than prompt.
//
// A generator builds a grid of palette *names*, not colours, so the palette can
// be swapped without touching the drawing. Nothing here blends: every softness
// is an ordered dither, so the output stays quantised to the named colours.
//
// Node's own zlib is the only dependency, so a re-render cannot rot when some
// package moves. Run `node lib/selftest.js` to check that your copy draws the
// same pixels as everyone else's, not merely that the file hashes the same.

const zlib = require('zlib');
const fs = require('fs');

// 4x4 Bayer matrix, values 0..15. threshold(x, y) < level means "on".
const BAYER = [
  [0, 8, 2, 10],
  [12, 4, 14, 6],
  [3, 11, 1, 9],
  [15, 7, 13, 5],
];

class Grid {
  constructor(w, h, fill) {
    this.w = w; this.h = h;
    this.g = new Array(w * h).fill(fill);
  }
  at(x, y) {
    return (x >= 0 && x < this.w && y >= 0 && y < this.h) ? this.g[y * this.w + x] : null;
  }
  put(x, y, c) {
    if (x >= 0 && x < this.w && y >= 0 && y < this.h) this.g[y * this.w + x] = c;
  }
  each(fn) {
    for (let y = 0; y < this.h; y++) for (let x = 0; x < this.w; x++) fn(x, y, this.at(x, y));
  }

  // Ordered dither. `level` in 0..1: 0 never fires, 1 always. Stable in x,y, so
  // two adjacent calls with the same level agree, which is what keeps a ramp
  // from shimmering along its own edge.
  static dither(x, y, level) {
    return BAYER[y & 3][x & 3] < level * 16;
  }

  fillPoly(pts, c) {
    for (let y = 0; y < this.h; y++) {
      const yc = y + 0.5, xs = [];
      for (let i = 0; i < pts.length; i++) {
        const [x1, y1] = pts[i], [x2, y2] = pts[(i + 1) % pts.length];
        if ((y1 <= yc && y2 > yc) || (y2 <= yc && y1 > yc)) {
          xs.push(x1 + (yc - y1) / (y2 - y1) * (x2 - x1));
        }
      }
      xs.sort((a, b) => a - b);
      for (let i = 0; i + 1 < xs.length; i += 2) {
        for (let x = 0; x < this.w; x++) if (x + 0.5 >= xs[i] && x + 0.5 <= xs[i + 1]) this.put(x, y, c);
      }
    }
  }

  fillEllipse(cx, cy, rx, ry, c, maskFn) {
    this.each((x, y, cur) => {
      const dx = (x + 0.5 - cx) / rx, dy = (y + 0.5 - cy) / ry;
      if (dx * dx + dy * dy <= 1 && (!maskFn || maskFn(cur))) this.put(x, y, c);
    });
  }

  stroke(pts, c, thick, maskFn) {
    for (let i = 0; i + 1 < pts.length; i++) {
      const [x1, y1] = pts[i], [x2, y2] = pts[i + 1];
      const n = Math.ceil(Math.hypot(x2 - x1, y2 - y1) * 4);
      for (let t = 0; t <= n; t++) {
        const x = x1 + (x2 - x1) * t / n, y = y1 + (y2 - y1) * t / n;
        for (let ox = -thick; ox <= thick; ox++) for (let oy = -thick; oy <= thick; oy++) {
          const px = Math.round(x) + ox, py = Math.round(y) + oy;
          if (!maskFn || maskFn(this.at(px, py))) this.put(px, py, c);
        }
      }
    }
  }

  // Every pixel of `isIn` that touches something outside it, recoloured. Two
  // passes so the outline never re-reads pixels it has just written.
  outline(isIn, c) {
    const hits = [];
    this.each((x, y, cur) => {
      if (!isIn(cur)) return;
      if (!isIn(this.at(x - 1, y)) || !isIn(this.at(x + 1, y)) ||
          !isIn(this.at(x, y - 1)) || !isIn(this.at(x, y + 1))) hits.push([x, y]);
    });
    for (const [x, y] of hits) this.put(x, y, c);
  }

  // A logarithmic spiral, r = r0 * (r1/r0)^(turn fraction), sampled densely
  // enough that consecutive points are under a pixel apart at the outer end.
  // `dir` is +1 for counterclockwise on screen and -1 for clockwise. Returns
  // points carrying their own progress, so a caller can band or taper along it.
  //
  // Growth is geometric rather than linear because that is what a shell does:
  // each whorl is a fixed multiple of the one inside it, which is why the
  // outline stays the same shape as it gets bigger.
  static spiral(cx, cy, r0, r1, turns, dir = 1, startAngle = 0) {
    const pts = [], steps = Math.ceil(turns * 2 * Math.PI * r1 * 1.5);
    for (let i = 0; i <= steps; i++) {
      const f = i / steps;
      const th = startAngle + dir * f * turns * 2 * Math.PI;
      const r = r0 * Math.pow(r1 / r0, f);
      pts.push({ x: cx + Math.cos(th) * r, y: cy - Math.sin(th) * r, f, r, th });
    }
    return pts;
  }

  // Copy the left half onto the right. Draw asymmetric things after calling it.
  mirrorX(axis) {
    for (let y = 0; y < this.h; y++) {
      for (let x = 0; x <= axis; x++) this.g[y * this.w + (this.w - 1 - x)] = this.g[y * this.w + x];
    }
  }
}

function crcTable() {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
}
const CRCT = crcTable();
const crc32 = (buf) => { let c = -1; for (const b of buf) c = CRCT[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ -1) >>> 0; };

function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

// Nearest-neighbour upscale straight into a truecolour PNG. No dependencies
// beyond node's own zlib, so nothing here can rot out from under a re-render.
// The drawing as bytes, before any encoder touches it: scaled, palette applied,
// one filter byte per row. Separated out because this is the thing a test of
// "does your copy draw the same picture" has to hash. The PNG around it is
// deflate output, and deflate's exact bytes are not a specified property of the
// format (mercury-boy, mercury-tools#1 review).
function rasterise(grid, palette, scale) {
  const ow = grid.w * scale, oh = grid.h * scale;
  const raw = Buffer.alloc(oh * (1 + ow * 3));
  for (let y = 0; y < oh; y++) {
    const row = y * (1 + ow * 3);
    for (let x = 0; x < ow; x++) {
      const name = grid.g[Math.floor(y / scale) * grid.w + Math.floor(x / scale)];
      const rgb = palette[name];
      if (!rgb) throw new Error(`palette has no colour named "${name}"`);
      raw[row + 1 + x * 3] = rgb[0]; raw[row + 2 + x * 3] = rgb[1]; raw[row + 3 + x * 3] = rgb[2];
    }
  }
  return { raw, ow, oh };
}

function writePNG(grid, palette, scale, path) {
  const { raw, ow, oh } = rasterise(grid, palette, scale);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(ow, 0); ihdr.writeUInt32BE(oh, 4);
  ihdr[8] = 8; ihdr[9] = 2;
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
  fs.writeFileSync(path, png);
  return { width: ow, height: oh, bytes: png.length };
}

module.exports = { Grid, writePNG, rasterise };
