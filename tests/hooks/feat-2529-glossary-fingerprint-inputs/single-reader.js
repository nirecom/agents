"use strict";
// T7-5: scope.js is the single reader of the four inputs. Statically, the CLI, the accept
// handler, the commit-gate checker and record.js never read glossary files, artifacts or
// intent.md themselves (no fs.readFileSync, no git cat-file, no listMainGlossaryFiles).
// record.js reading the state store is the one allowed exception.

const fs = require("node:fs");
const path = require("node:path");
const F = require("../../lib/glossary-check-fixture");

const CONSUMERS = ["bin/check-glossary-drift", "hooks/workflow-mark/glossary-accept-handler.js",
  "hooks/workflow-gate/glossary-record-checker.js", "hooks/workflow-state/glossary-check/record.js"];
const FORBIDDEN = [["fs.readFileSync", /\breadFileSync\s*\(/], ["git cat-file", /cat-file/],
  ["listMainGlossaryFiles", /\blistMainGlossaryFiles\b/]];

// A readFileSync line in record.js that reads the workflow state store is allowed.
const stateRead = (rel, line) => rel.endsWith("record.js") && /state/i.test(line);

function run() {
  for (const rel of CONSUMERS) {
    const file = path.join(F.ROOT, rel);
    if (!F.check(`${rel} exists`, fs.existsSync(file), "missing")) continue;
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
    for (const [name, re] of FORBIDDEN) {
      const hits = lines.map((l, i) => [i + 1, l]).filter(([, l]) => re.test(l) && !stateRead(rel, l));
      F.check(`${rel} does not call ${name}`, hits.length === 0, JSON.stringify(hits.slice(0, 3)));
    }
  }
}

module.exports = { run };
