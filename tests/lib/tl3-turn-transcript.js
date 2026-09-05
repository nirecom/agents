"use strict";
// Shared transcript reader for the TL3 hook-seam tests (tests/TL3-hook-*.sh).
// A `claude -p` turn leaves evidence in two shapes and neither carries both halves:
// `--output-format json` gives the final result record, the session `.jsonl` gives
// the tool_use / tool_result records. Callers pass every file they found.
// Modes:
//   --is-error <file>                                 -> true | false | unreadable
//   --probe --needle <t> [--marker <t>] <file...>     -> key=value lines
// `attempted` answers "was it tried"; `marker` attributes a refusal to THIS guard;
// `permission_denial` attributes one to the permission system — the only shape an
// allow-only hook leaves when it declines. Both separate a deny from a crash.

const fs = require("fs");

// Tool names whose input carries a shell command. Matched exactly: `BashOutput`
// reads a background stream and would otherwise pass a substring test.
const COMMAND_TOOLS = new Set(["Bash", "runCommands", "runInTerminal"]);

// A tool call refused by the PERMISSION system, as distinct from one that ran and
// failed, crashed, or was denied by a named guard. An allow-only hook (it never
// denies) is attributable only through this shape: when it declines to allow, the
// call falls through to the prompt, which a non-interactive session refuses.
// Several spellings are current across CLI versions; each is an independent
// alternative, isolated one per row by the D-ALT table in the unit test.
// P2 deliberately excludes a bare "Permission denied": that is the OS message a
// script prints on a mode bit, and matching it would classify an ordinary
// execution failure as a refusal by the permission system.
const PERMISSION_DENIAL_PATTERNS = [
  /requested permissions? to use/i,
  /permission[^\n]{0,80}(?:not been granted|not granted|was denied|is required)/i,
  /tool use was rejected/i,
  /(?:doesn't|does not) want to proceed with this tool use/i,
  /(?:requires|needs) (?:approval|permission)/i,
];

function die(msg) {
  console.error(msg);
  process.exit(2);
}

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (_e) {
    return null;
  }
}

// One JSON document, or a JSONL stream. A truncated final line is skipped rather
// than discarding the whole file: a killed CLI still leaves usable evidence.
function parseRecords(text) {
  const out = [];
  if (typeof text !== "string" || text.trim() === "") return out;
  try {
    out.push(JSON.parse(text));
    return out;
  } catch (_e) {
    /* not a single document — read it as JSONL below */
  }
  for (const line of text.split("\n")) {
    const s = line.trim();
    if (s === "" || (s[0] !== "{" && s[0] !== "[")) continue;
    try {
      out.push(JSON.parse(s));
    } catch (_e) {
      /* a partial record is not evidence */
    }
  }
  return out;
}

// The nesting depth of a transcript record is a CLI implementation detail, so the
// blocks are found by walking rather than by a fixed path. `seen` also terminates
// the walk on any self-referential structure.
function walk(node, visit, seen) {
  if (node === null || typeof node !== "object") return;
  if (seen.has(node)) return;
  seen.add(node);
  visit(node);
  if (Array.isArray(node)) {
    for (const v of node) walk(v, visit, seen);
    return;
  }
  for (const k of Object.keys(node)) walk(node[k], visit, seen);
}

function collectBlocks(records) {
  const uses = [];
  const results = [];
  const seen = new WeakSet();
  for (const rec of records) {
    walk(rec, (n) => {
      if (n.type === "tool_use") uses.push(n);
      else if (n.type === "tool_result") results.push(n);
    }, seen);
  }
  return { uses, results };
}

function commandTextOf(use) {
  const input = use && use.input;
  if (!input || typeof input !== "object") return "";
  const parts = [];
  if (typeof input.command === "string") parts.push(input.command);
  if (Array.isArray(input.commands)) {
    for (const c of input.commands) if (typeof c === "string") parts.push(c);
  }
  return parts.join("\n");
}

// A tool_result's payload is a plain string in some versions and a content-block
// array in others; both spellings must yield the same searchable text.
function resultTextOf(res) {
  const content = res && res.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((b) => (b && typeof b.text === "string" ? b.text : "")).join("\n");
  }
  if (content && typeof content === "object") return JSON.stringify(content);
  return "";
}

function isCommandTool(name) {
  return typeof name === "string" && COMMAND_TOOLS.has(name);
}

// True only for the permission system's own refusal wording. A guard's named deny,
// a non-zero exit, a crash, and a timeout all read as false here — that separation
// is the whole point of the key.
function isPermissionDenialText(text) {
  return PERMISSION_DENIAL_PATTERNS.some((re) => re.test(text));
}

function probe(files, needle, marker) {
  const records = [];
  for (const f of files) records.push(...parseRecords(readText(f)));
  const { uses, results } = collectBlocks(records);
  const attempts = uses.filter((u) => isCommandTool(u.name) && commandTextOf(u).indexOf(needle) !== -1);
  const ids = new Set(attempts.map((a) => a.id).filter((id) => typeof id === "string"));
  const linked = results.filter((r) => ids.has(r.tool_use_id));

  // `unknown` is deliberate: with no result block linked to the attempt the outcome
  // is unobserved, and reporting `false` would let a missing transcript read as a
  // successfully executed tool call.
  let resultError = "unknown";
  if (linked.length > 0) resultError = String(linked.some((r) => r.is_error === true));
  let markerSeen = "unknown";
  if (marker !== null && linked.length > 0) {
    markerSeen = String(linked.some((r) => resultTextOf(r).indexOf(marker) !== -1));
  }
  // The refusal wording alone is not enough: a SUCCESSFUL result may quote it (a
  // script that echoes a permission message, a listing of the hook's own source).
  // Only an error result can be the permission system declining to run the call.
  let permissionDenial = "unknown";
  if (linked.length > 0) {
    permissionDenial = String(linked.some(
      (r) => r.is_error === true && isPermissionDenialText(resultTextOf(r)),
    ));
  }

  return [
    "records=" + records.length,
    "uses=" + uses.length,
    "attempts=" + attempts.length,
    "attempted=" + String(attempts.length > 0),
    "result_error=" + resultError,
    "permission_denial=" + permissionDenial,
    "marker=" + markerSeen,
  ].join("\n");
}

// Faithful to the shape `--output-format json` emits: one result object, or an
// array whose LAST element is the result.
function isErrorOf(file) {
  const text = readText(file);
  if (text === null) return "unreadable";
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (_e) {
    return "unreadable";
  }
  const rec = Array.isArray(doc) ? doc[doc.length - 1] : doc;
  return String(Boolean(rec && rec.is_error));
}

function main(argv) {
  const mode = argv[0];
  if (mode === "--is-error") return isErrorOf(argv[1]);
  if (mode === "--probe") {
    let needle = null;
    let marker = null;
    const files = [];
    for (let i = 1; i < argv.length; i += 1) {
      if (argv[i] === "--needle") { needle = argv[i + 1]; i += 1; continue; }
      if (argv[i] === "--marker") { marker = argv[i + 1]; i += 1; continue; }
      files.push(argv[i]);
    }
    if (typeof needle !== "string" || needle === "") die("--probe requires a non-empty --needle");
    return probe(files, needle, marker);
  }
  die("BAD_MODE:" + String(mode));
  return "";
}

if (require.main === module) {
  console.log(main(process.argv.slice(2)));
}

module.exports = {
  parseRecords,
  collectBlocks,
  commandTextOf,
  resultTextOf,
  isPermissionDenialText,
  probe,
  isErrorOf,
};
