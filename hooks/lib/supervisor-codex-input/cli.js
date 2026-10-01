"use strict";

// CLI for hooks/lib/supervisor-codex-input.js. Success: --out written, stdout
// CURSOR_STATUS / CURSOR_NEXT, exit 0. Bad args or unreadable transcript: one
// stderr line, exit 1, --out untouched. Read-only on supervisor state.

const fs = require("fs");
const { toWindowsPath } = require("../branch-diff");
const { assemble } = require("./assemble");
const { SESSION_ID_RE } = require("../supervisor-state-writer/shared");

const VALUE_FLAGS = new Set(["--mode", "--sid", "--wsid", "--transcript", "--artifact", "--state-snapshot", "--plan-scope", "--out"]);
const PATH_FLAGS = new Set(["--transcript", "--artifact", "--state-snapshot", "--out"]);

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (!VALUE_FLAGS.has(flag) || i + 1 >= argv.length) throw new Error(`unknown flag or missing value: ${flag}`);
    const v = argv[++i];
    args[flag.slice(2)] = PATH_FLAGS.has(flag) ? toWindowsPath(v) : v;
  }
  if (args.mode !== "alert" && args.mode !== "audit") throw new Error("--mode must be alert or audit");
  for (const k of ["sid", "wsid", "transcript", "out"]) {
    if (!args[k]) throw new Error(`--${k} is required`);
  }
  // Both ids are joined into plans-dir paths; the UNAVAILABLE sentinel already fits the charset.
  for (const k of ["sid", "wsid"]) {
    if (!SESSION_ID_RE.test(args[k])) throw new Error(`--${k} must match ${SESSION_ID_RE}`);
  }
  if (args["plan-scope"] && args["plan-scope"] !== "intent" && args["plan-scope"] !== "all") {
    throw new Error("--plan-scope must be intent or all");
  }
  return args;
}

function main(argv) {
  let args;
  let result;
  try {
    args = parseArgs(argv);
    if (!fs.existsSync(args.transcript)) throw new Error(`transcript not found: ${args.transcript}`);
    result = assemble({
      mode: args.mode, sid: args.sid, wsid: args.wsid, transcript: args.transcript,
      artifact: args.artifact, stateSnapshot: args["state-snapshot"], planScope: args["plan-scope"] || "all",
    });
    fs.writeFileSync(args.out, result.text);
  } catch (e) {
    process.stderr.write(`supervisor-codex-input: ${String(e && e.message ? e.message : e).split("\n")[0]}\n`);
    return 1;
  }
  process.stdout.write(`CURSOR_STATUS: ${result.status}\nCURSOR_NEXT: ${JSON.stringify(result.next)}\n`);
  return 0;
}

module.exports = { main, parseArgs };
