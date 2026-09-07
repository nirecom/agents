"use strict";
// Argument surface for bin/resume-session-detect. Kept apart from the CLI so
// the no-arg contract (hooks/session-start.js reads that JSON) and the new
// --from / --list modes cannot drift into one tangled parser.

const USAGE =
  "Usage: resume-session-detect [--from <session-id>] [--list [query]] [--limit <n>] [--help] [--version]\n";

function parseResumeArgs(argv) {
  const args = Array.isArray(argv) ? argv : [];
  const out = { mode: "detect", from: null, query: "", limit: null, usage: USAGE };
  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if (a === "--help" || a === "-h") return Object.assign(out, { mode: "help" });
    if (a === "--version") return Object.assign(out, { mode: "version" });
    if (a === "--from") {
      const v = args[i + 1];
      if (typeof v !== "string" || v.length === 0 || v.charAt(0) === "-") {
        return Object.assign(out, { mode: "error", error: "--from requires a session id" });
      }
      out.mode = "from";
      out.from = v;
      i += 1;
      continue;
    }
    if (a === "--list") {
      out.mode = "list";
      const v = args[i + 1];
      if (typeof v === "string" && v.length > 0 && v.charAt(0) !== "-") {
        out.query = v;
        i += 1;
      }
      continue;
    }
    if (a === "--limit") {
      const v = Number(args[i + 1]);
      if (!Number.isInteger(v) || v <= 0) {
        return Object.assign(out, { mode: "error", error: "--limit requires a positive integer" });
      }
      out.limit = v;
      i += 1;
      continue;
    }
    return Object.assign(out, { mode: "error", error: `Unknown flag: ${a}` });
  }
  return out;
}

module.exports = { USAGE, parseResumeArgs };
