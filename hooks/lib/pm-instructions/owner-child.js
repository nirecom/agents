"use strict";
// owner-child.js <issue-ref>... <ms> (#3019, #2942): run `bin/pm-state owner --issue <ref>... --timeout-ms <ms>`
// once for every ref, under a deadline that kills the whole process tree, so a slow forge call never
// outlives the hook. The last argument is the deadline. Exit 124 on timeout.

const path = require("path");
const { run } = require("../../../bin/lib/session-sync/proc");

const PM_STATE_BIN = path.join(__dirname, "..", "..", "..", "bin", "pm-state");

async function main(argv) {
  const refs = argv.slice(0, -1).map(String);
  if (refs.length === 0) return 1;
  const last = Number(argv[argv.length - 1]);
  const ms = last > 0 ? Math.floor(last) : 1;
  const issueArgs = refs.flatMap((ref) => ["--issue", ref]);
  const r = await run(process.execPath, [PM_STATE_BIN, "owner", ...issueArgs, "--timeout-ms", String(ms)], { deadlineMs: ms });
  if (r.timedOut) return 124;
  process.stdout.write(r.stdout);
  return r.code === 0 ? 0 : 1;
}

main(process.argv.slice(2)).then((code) => { process.exitCode = code; }, () => { process.exitCode = 1; });
