#!/usr/bin/env node
"use strict";
// step-durations — per-session workflow step durations, with user-wait time excluded. Read-only.
// Usage: node bin/step-durations.js [--since YYYY-MM-DD] [--until YYYY-MM-DD | --days N]
//                                   [--format md|csv] [--out <path>] [--session <sid-prefix>]
//   no period option : every session on disk
//   --since / --until: sessions whose first segment starts in [since 00:00, until 24:00) local time
//   --days N         : sessions starting within the last N days (exclusive with --since / --until)
//   --format         : md (default) or csv (one table, kind=session|segment); --out defaults to stdout
// Segments come from <state root>/<sid>.json events while the state file exists, and are
// estimated from the transcript (<CLAUDE_TRANSCRIPT_BASE_DIR or ~/.claude/projects>) once it is gone.
// Exit 0 = report written, 1 = runtime error, 2 = usage error.
const fs = require("fs");
const os = require("os");
const path = require("path");
const { listStateRoots } = require("../hooks/workflow-state/state-io/state-root");
const { toWindowsPath } = require("../hooks/lib/branch-diff");
const { collectSessions } = require("./step-durations/sources");
const { renderMarkdown, renderCsv } = require("./step-durations/render");

const DAY = 86400000;
const USAGE = "Usage: step-durations.js [--since YYYY-MM-DD] [--until YYYY-MM-DD | --days N] [--format md|csv] [--out <path>] [--session <sid-prefix>]";

function parseDate(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || "");
  if (!m) return null;
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return d.getMonth() === Number(m[2]) - 1 ? d.getTime() : null;
}

// Returns the options, or a string describing the usage error.
function parseArgs(argv, now) {
  const o = { format: "md", out: null, session: "", since: null, until: null, days: null };
  const valued = { "--since": "since", "--until": "until", "--days": "days", "--format": "format", "--out": "out", "--session": "session" };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--help" || argv[i] === "-h") return { help: true };
    const key = valued[argv[i]];
    if (!key) return `unknown argument: ${argv[i]}`;
    if (i + 1 >= argv.length) return `${argv[i]} requires a value`;
    o[key] = argv[++i];
  }
  if (o.format !== "md" && o.format !== "csv") return `--format must be md or csv: ${o.format}`;
  if (o.days !== null && (o.since !== null || o.until !== null)) return "--days cannot be combined with --since / --until";
  let from = -Infinity;
  let to = Infinity;
  if (o.days !== null) {
    if (!/^[1-9]\d*$/.test(o.days)) return `--days must be a positive integer: ${o.days}`;
    from = now - Number(o.days) * DAY;
  }
  if (o.since !== null) {
    from = parseDate(o.since);
    if (from === null) return `--since must be YYYY-MM-DD: ${o.since}`;
  }
  if (o.until !== null) {
    const u = parseDate(o.until);
    if (u === null) return `--until must be YYYY-MM-DD: ${o.until}`;
    to = new Date(u).setDate(new Date(u).getDate() + 1);
  }
  if (from >= to) return "--since must not be after --until";
  return Object.assign(o, { from, to });
}

async function main() {
  const opts = parseArgs(process.argv.slice(2), Date.now());
  if (typeof opts === "string") {
    process.stderr.write(`step-durations: ${opts}\n${USAGE}\n`);
    return 2;
  }
  if (opts.help) {
    process.stdout.write(USAGE + "\n");
    return 0;
  }
  const rows = await collectSessions({
    transcriptBase: toWindowsPath(process.env.CLAUDE_TRANSCRIPT_BASE_DIR || path.join(os.homedir(), ".claude", "projects")),
    stateDirs: listStateRoots().map(toWindowsPath),
    sessionPrefix: opts.session,
    from: opts.from,
    to: opts.to,
  });
  const text = opts.format === "csv" ? renderCsv(rows) : renderMarkdown(rows);
  if (opts.out === null) {
    process.stdout.write(text);
  } else {
    fs.writeFileSync(toWindowsPath(opts.out), text);
    process.stderr.write(`step-durations: sessions=${rows.length} out=${opts.out}\n`);
  }
  return 0;
}

if (require.main === module) {
  main().then((code) => { process.exitCode = code; }, (e) => {
    process.stderr.write(`step-durations: ${e && e.stack ? e.stack : e}\n`);
    process.exitCode = 1;
  });
}

module.exports = { parseArgs };
