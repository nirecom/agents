"use strict";
// tests/fixtures/quote-spans-probe/deep-recursion.js
// Split out of tests/fixtures/quote-spans-probe.js per rules/coding/file-split.md.
// Entrypoint-private: nothing but the probe requires this.
//
// One op family lives here: deeply NESTED (not merely long) input, which the
// span renderers walk with mutual recursion (renderSpan <-> renderList), one
// JS stack frame per nesting level.
//
//   deepsafe   <depth> <fn> — the transform's outcome class on nested input
//   deeprender <depth> <fn> — the transform's literal output (shallow exactness)
//
// The input is built HERE from a depth number rather than passed on argv: at
// the depths that matter the string is ~60 KB, well past the Windows 32 KB
// command-line limit, so a bash-side fixture could not reach the module at all.
//
// handle() returns the output line, or null when `op` belongs elsewhere.

const path = require("path");

const AGENTS_DIR = path.resolve(__dirname, "..", "..", "..");
const STRIP_PATH = path.join(AGENTS_DIR, "hooks", "lib", "strip-quoted-args.js");

// The marker is a WRITE, so "did the transform lose it?" and "is the surviving
// text on the danger side?" are the same question.
const MARKER = "rm -f README.md";

// echo "$($(...$(rm -f README.md)...))" — balanced, so the scanner has no
// excuse to fail closed on it; the nesting alone is the stress.
//
// Unbalanced nesting ('$('.repeat(n)) does NOT exercise this path: the scan
// fails first and every renderer returns early, which is why the unbalanced
// row below is the control rather than the pin.
function buildNested(depth, balanced) {
  const open = "$(".repeat(depth);
  return balanced === false
    ? 'echo "' + open + MARKER
    : 'echo "' + open + MARKER + ")".repeat(depth) + '"';
}

// fn name -> { call, kind }. `kind: "scan"` has no rendered output.
function transforms(api) {
  let strip = null;
  try { strip = require(STRIP_PATH); } catch (e) { strip = null; }
  return {
    scan: { kind: "scan", call: (s) => api.scanSpans(s) },
    blank: { kind: "render", call: (s) => api.blankQuoteSpans(s) },
    unwrap: { kind: "render", call: (s) => api.unwrapCmdSubstInDq(s) },
    fold: { kind: "render", call: (s) => api.foldNewlinesInSpans(s, ["dq"]) },
    // The two consumer-facing wrappers. stripQuotedArgs has no try/catch of its
    // own, so whatever escapes blankQuoteSpans escapes all the way into
    // hooks/enforce-worktree.js.
    strip: { kind: "string", call: (s) => strip.stripQuotedArgs(s) },
    stripdq: { kind: "string", call: (s) => strip.stripDqPreservingCmdSubst(s) },
  };
}

// "safe" means BOTH halves of the contract hold: nothing escaped as an
// exception, AND the surviving text is on the danger side — either the
// transform fail-closed (ok:false / output identical to the input, so a later
// reader still sees the write) or it rendered the write out into the open.
// "hidden" is the one outcome that must never occur: a clean, confident result
// that dropped the write.
function outcome(entry, input) {
  let r;
  try {
    r = entry.call(input);
  } catch (e) {
    return "threw:" + (e && e.constructor ? e.constructor.name : "Error");
  }
  if (entry.kind === "scan") return "safe";
  if (entry.kind === "string") {
    if (typeof r !== "string") return "hidden";
    return r.indexOf(MARKER) === -1 ? "hidden" : "safe";
  }
  if (r === null || typeof r !== "object") return "hidden";
  if (r.ok === false) return "safe";
  return typeof r.out === "string" && r.out.indexOf(MARKER) !== -1 ? "safe" : "hidden";
}

function handle(op, ctx) {
  const { api, str, a1, a2 } = ctx;
  if (op !== "deepsafe" && op !== "deeprender") return null;

  const depth = Number(str);
  if (!Number.isInteger(depth) || depth < 1) return "ERROR: bad depth " + str;
  const entry = transforms(api)[a1];
  if (entry === undefined) return "ERROR: no transform " + a1;
  const input = buildNested(depth, a2 !== "unbalanced");

  if (op === "deepsafe") return outcome(entry, input);

  // deeprender — literal output, for pinning that a "safe" verdict is still
  // backed by a real transform rather than by a bail-out.
  try {
    const r = entry.call(input);
    return JSON.stringify(entry.kind === "string" ? r : r.out);
  } catch (e) {
    return "threw:" + (e && e.constructor ? e.constructor.name : "Error");
  }
}

module.exports = { handle, buildNested, MARKER };
