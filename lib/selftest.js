// selftest.js — does your copy of pixel.js DRAW the same thing as mine?
//
// The lock file answers "is this the same source". That is not the same
// question. A hash of the source goes red for a comment change and stays green
// for a node version that rounds differently, and it is the second one that
// would put a different picture on a wall. So: render a fixture that touches
// every primitive, hash the RASTER, compare to a recorded digest.
//
// The raster and not the PNG. The first version of this file hashed the encoded
// file, which ends in zlib.deflateSync(raw, { level: 9 }), so the constant was a
// fact about zlib's output rather than about the drawing: a zlib change would
// have told someone with a pixel-identical picture that their copy draws
// differently. mercury-boy demonstrated it in the #1 review, same pixels at
// level 6 and level 9, two encoded digests. Deflate's exact bytes are not a
// specified property of PNG; only their decompressibility is. The raster is what
// the format does promise, so the raster is what is recorded here.
//
// A consequence worth knowing: this no longer notices the encoder at all. The
// PNG is still written for eyeballing, and its byte count may move with zlib
// while this test stays green, which is correct.
//
//   node lib/selftest.js          # ok, or FAIL with both digests
//
// If this fails and you did not edit pixel.js, say so on mercury-hub with your
// node version rather than fixing the constant.

const os = require('os');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { Grid, writePNG, rasterise } = require('./pixel.js');

// Raster recorded on node v22 (Windows, Git Bash), 2026-08-27: a digest of
// the scaled, palette-applied pixel buffer, not of the PNG file.
const EXPECTED = '58a606dbf737d2b02b4e1d5896da55fcf9237cfbb84caf0317052688b84c9441';

const PALETTE = {
  bg: [18, 20, 30], ink: [10, 10, 14], shell: [198, 154, 96],
  band: [120, 82, 48], glow: [232, 214, 170],
};

function fixture() {
  const g = new Grid(32, 32, 'bg');

  // filled polygon, even-odd scanline
  g.fillPoly([[4, 26], [16, 6], [28, 26]], 'band');

  // filled ellipse, with a mask so it only lands on what is already drawn
  g.fillEllipse(16, 20, 9, 6, 'shell', (cur) => cur === 'band');

  // logarithmic spiral, sampled, tapering by its own progress
  for (const p of Grid.spiral(16, 20, 1.5, 7, 1.75, -1)) {
    g.put(Math.round(p.x), Math.round(p.y), p.f > 0.6 ? 'glow' : 'band');
  }

  // masked polyline stroke
  g.stroke([[6, 8], [12, 12], [20, 10]], 'glow', 0, (cur) => cur === 'bg');

  // ordered dither: a ramp that must stay quantised
  g.each((x, y, cur) => {
    if (cur === 'bg' && Grid.dither(x, y, y / 32)) g.put(x, y, 'ink');
  });

  // adjacency outline, then the half-authoring mirror
  g.outline((c) => c === 'shell', 'ink');
  g.mirrorX(15);
  return g;
}

const g = fixture();
const got = crypto.createHash('sha256').update(rasterise(g, PALETTE, 4).raw).digest('hex');

// Still written, so a human can look at the thing the digest is about.
const out = path.join(os.tmpdir(), `pixel-selftest-${process.pid}.png`);
const info = writePNG(g, PALETTE, 4, out);
fs.unlinkSync(out);

if (EXPECTED === got) {
  console.log(`ok: pixel.js draws the fixture as recorded, raster ${got.slice(0, 12)} (${info.width}x${info.height}, node ${process.version})`);
  process.exit(0);
}
console.log(`FAIL: the fixture draws differently
  expected raster ${EXPECTED}
  got             ${got}   (node ${process.version})`);
console.log('If you did not edit pixel.js, report this on mercury-hub with your node version.');
process.exit(1);
