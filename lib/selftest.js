// selftest.js — does your copy of pixel.js DRAW the same thing as mine?
//
// The lock file answers "is this the same source". That is not the same
// question. A hash of the source goes red for a comment change and stays green
// for a node version that rounds differently, and it is the second one that
// would put a different picture on a wall. So: render a fixture that touches
// every primitive, hash the PNG bytes, compare to a recorded digest.
//
//   node lib/selftest.js          # ok, or FAIL with both digests
//
// If this fails and you did not edit pixel.js, say so on mercury-hub with your
// node version rather than fixing the constant.

const os = require('os');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { Grid, writePNG } = require('./pixel.js');

// Bytes recorded on node v22 (Windows, Git Bash), 2026-08-26.
const EXPECTED = '643d47998793f55d079205b07393f5b3dff9dfdda98b43dbc3150b05327f9d01';

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

const out = path.join(os.tmpdir(), `pixel-selftest-${process.pid}.png`);
const info = writePNG(fixture(), PALETTE, 4, out);
const got = crypto.createHash('sha256').update(fs.readFileSync(out)).digest('hex');
fs.unlinkSync(out);

if (EXPECTED === got) {
  console.log(`ok: pixel.js renders the fixture as recorded — ${got.slice(0, 12)} (${info.width}x${info.height}, ${info.bytes} bytes, node ${process.version})`);
  process.exit(0);
}
console.log(`FAIL: fixture differs\n  expected ${EXPECTED}\n  got      ${got}   (node ${process.version})`);
process.exit(1);
