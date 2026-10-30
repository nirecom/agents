"use strict";
// Malformed --manifest streams for tests/bin/feature-2507-scan-outbound-node.js (#2507 D6, review
// gap C2). A broken frame carries the synthetic secret BROKEN; a well-formed frame "after.txt"
// carries AFTER. expect "golden": bash reads the stream sanely and the port must match it.
// expect "rc4": the port stops with rc 4 (Accepted Tradeoffs: a broken manifest frame stops
// scan-outbound); bash's rc is kept in the golden as a record only. Editing a row means
// regenerating golden/manifest.json (generate-golden.js).

const { SECRETS } = require("./corpus");

const RS = "\u001e";
const u = (s) => Buffer.from(s, "utf8");
const AFTER = SECRETS.aws;
const BROKEN = SECRETS.github;
const brokenBody = `g ${BROKEN}\n`;
const exact = String(u(brokenBody).length);

// One frame with every part spelled out, so a row can break exactly one of them.
function rawFrame({ lead = RS, path, sep = RS, len, body = "" }) {
  return Buffer.concat([u(`${lead}${path}${sep}${len}\n`), u(body)]);
}
const afterBody = `k ${AFTER}\n`;
const afterFrame = rawFrame({ path: "after.txt", len: String(u(afterBody).length), body: afterBody });

// Frames bash reads sanely: the golden is exact for these.
const GOLDEN_ROWS = [
  { name: "len-zero-empty-body", stdin: Buffer.concat([rawFrame({ path: "z.txt", len: "0" }), afterFrame]) },
  {
    // The broken frame is the last one: its body ends before the declared length.
    name: "body-truncated-at-eof",
    stdin: Buffer.concat([afterFrame, rawFrame({ path: "t.txt", len: String(u(brokenBody).length + 40), body: brokenBody })]),
  },
  {
    name: "sep-missing-leading-rs",
    stdin: Buffer.concat([rawFrame({ lead: "", path: "l.txt", len: exact, body: brokenBody }), afterFrame]),
  },
];

// Broken frames the port must stop on, each run followed by after.txt and alone.
const BROKEN_FRAMES = {
  "len-zero-stray-bytes": rawFrame({ path: "z.txt", len: "0", body: brokenBody }),
  "len-negative": rawFrame({ path: "n.txt", len: "-5", body: brokenBody }),
  "len-oversized": rawFrame({ path: "o.txt", len: "99999", body: brokenBody }),
  "len-not-a-number": rawFrame({ path: "x.txt", len: `${exact}x`, body: brokenBody }),
  "sep-space-instead-of-rs": rawFrame({ path: "s.txt", sep: " ", len: exact, body: brokenBody }),
  "sep-empty-path": rawFrame({ path: "", len: exact, body: brokenBody }),
};

const MANIFEST_CASES = [
  ...GOLDEN_ROWS.map((r) => ({ ...r, expect: "golden" })),
  ...Object.entries(BROKEN_FRAMES).map(([name, frame]) => ({ name, expect: "rc4", stdin: Buffer.concat([frame, afterFrame]) })),
  ...Object.entries(BROKEN_FRAMES).map(([name, frame]) => ({ name: `${name}-alone`, expect: "rc4", stdin: frame })),
];

module.exports = { MANIFEST_CASES, AFTER, BROKEN };
