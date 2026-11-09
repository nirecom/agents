"use strict";
// Test-only CLI for tests/hooks/TL3-hook-askuser-jev-answer.sh (#2764): seeds the workflow state of
// one fixture made by fx_new (tests/hooks/feature-2460-jev-shadow/_lib.sh) with a SEED of
// ./fixture.js, so the TL3 run and the TL2 cases read the same seeded steps.
// Usage: node tl3-seed.js <fx-root> <seed-name> <session-id>

const fs = require("node:fs");
const path = require("node:path");
const X = require("./fixture");

const [fx, seed, sid] = process.argv.slice(2);
if (!fx || !X.SEED[seed] || !sid) {
  process.stderr.write("usage: tl3-seed.js <fx-root> <seed-name> <session-id>\n");
  process.exit(2);
}
const sub = (s) => path.join(fx, s);
fs.mkdirSync(sub("claude-config"), { recursive: true });
const sc = {
  dir: fx, wf: sub("wf"), plans: sub("plans"), state: sub("state"), cfg: sub("cfg"), claudeCfg: sub("claude-config"),
  cwd: sub("cwd"), proj: sub("proj"), io: sub("io"), transcripts: sub("transcripts"),
};
X.SEED[seed](sc, sid);
