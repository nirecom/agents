"use strict";
// tests/lib/command-guard/record-hit.js — one hit file per refused command (#2590).
// hits/<pid>-<rand>.hit holds stub= / test_id= / target= / argv= lines; tests/lib/command-guard.sh
// (command_guard_hits) and the run-all hit report read them. The test id comes from
// ROOT_DECOY_TEST_ID, which the launcher sets per test.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const oneLine = (s) => String(s).replace(/[\r\n]/g, " ");

function recordHit(guardDir, tool, target, args, reason) {
  const lines = [
    `stub=${oneLine(tool)}`,
    `test_id=${oneLine(process.env.ROOT_DECOY_TEST_ID || "")}`,
    `target=${oneLine(target).replace(/\\/g, "/")}`,
    `argv=${oneLine(args.join(" ")).slice(0, 200)}`,
  ];
  try {
    const hits = path.join(guardDir, "hits");
    fs.mkdirSync(hits, { recursive: true });
    fs.writeFileSync(path.join(hits, `${process.pid}-${crypto.randomBytes(4).toString("hex")}.hit`), `${lines.join("\n")}\n`);
  } catch (_) {}
  try {
    fs.writeSync(2, `command guard: refused ${tool} (${reason}): ${oneLine(target)}\n`);
  } catch (_) {}
}

module.exports = { recordHit };
