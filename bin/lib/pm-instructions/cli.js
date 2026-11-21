"use strict";
// bin/pm-instructions (#3019): print the PM duties block for one session at one timing.
//   --timing <key> [--session <sid>] [--issue <ref> ... | --checkpoint <path>]
// --session defaults to CLAUDE_CODE_SESSION_ID. --checkpoint reads the /workflow-init driver checkpoint
// and uses state.issues only (never repo_map). Without either, the session's intent ## Issues is used.
// stdout: the block, empty when the session has no role or no section applies.
// Exit 0 success (empty included), 1 md / checkpoint / state failure, 2 malformed request.
// stderr carries a reason token only, never a path.

const path = require("path");
const HOOKS = path.join(__dirname, "..", "..", "..", "hooks");
const { buildInjection, TIMINGS } = require(path.join(HOOKS, "lib", "pm-instructions"));
const { SectionError } = require(path.join(HOOKS, "lib", "pm-instructions", "sections"));
const { parseIssueToken } = require(path.join(HOOKS, "lib", "parse-closes-issues"));
const { SESSION_ID_VALID_RE } = require(path.join(HOOKS, "workflow-state", "state-io"));
const { resolveSessionId } = require(path.join(HOOKS, "workflow-state", "session-id"));
const { readCheckpoint } = require("../../workflow/lib/workflow-init/checkpoint");

const TOOL = "pm-instructions";
class Exit extends Error { constructor(code, msg) { super(msg); this.code = code; } }
const fail = (code, msg) => { throw new Exit(code, msg); };

function parseArgs(argv) {
  const o = { issues: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = String(argv[i]);
    const v = argv[i + 1];
    if (!["--timing", "--session", "--issue", "--checkpoint"].includes(a)) fail(2, `unexpected argument: ${a}`);
    if (v === undefined) fail(2, `${a} needs a value`);
    i += 1;
    if (a === "--issue") {
      const ref = parseIssueToken(String(v));
      if (!ref) fail(2, "--issue takes #N or owner/repo#N");
      o.issues.push(ref);
    } else {
      o[a.slice(2)] = String(v);
    }
  }
  if (!o.timing) fail(2, "--timing <key> is required");
  if (!TIMINGS.includes(o.timing)) fail(2, `--timing must be one of: ${TIMINGS.join(" ")}`);
  if (o.issues.length > 0 && o.checkpoint !== undefined) fail(2, "--issue and --checkpoint are exclusive");
  return o;
}

// checkpointIssues(file) -> [{number}] from state.issues; exit 1 on any unreadable shape.
function checkpointIssues(file) {
  const r = readCheckpoint(file);
  if (!r.ok) fail(1, `checkpoint ${r.error}`);
  const issues = r.data && r.data.state ? r.data.state.issues : undefined;
  if (!Array.isArray(issues) || !issues.every((n) => Number.isInteger(Number(n)) && Number(n) > 0)) fail(1, "checkpoint state.issues is not an array of issue numbers");
  return issues.map((n) => ({ number: Number(n) }));
}

function run(argv) {
  const o = parseArgs(argv);
  const sid = o.session || resolveSessionId();
  if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) fail(2, "--session <sid> is required (or CLAUDE_CODE_SESSION_ID)");
  const opts = { timing: o.timing, cwd: process.cwd() };
  if (o.checkpoint !== undefined) opts.issues = checkpointIssues(o.checkpoint);
  else if (o.issues.length > 0) opts.issues = o.issues;
  try {
    return buildInjection(sid, opts);
  } catch (e) {
    if (e instanceof SectionError) fail(1, e.reason);
    fail(1, `cannot resolve the role (${e && e.name ? e.name : "Error"})`);
  }
  return null;
}

function main(argv, deps) {
  const d = deps || {};
  const out = d.out || ((s) => process.stdout.write(s));
  const err = d.err || ((s) => process.stderr.write(s));
  try {
    const text = run(argv);
    if (text) out(`${text}\n`);
    return 0;
  } catch (e) {
    err(`${TOOL}: ${e instanceof Exit ? e.message : "internal error"}\n`);
    return e instanceof Exit ? e.code : 1;
  }
}

module.exports = { main };
