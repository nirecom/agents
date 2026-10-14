"use strict";
// Probe for tests/bin/feature-2460-jev-judge.sh (#2460): calls the two-stage library
// surface in-process. Usage: node judge-probe.js <repo-root> <cmd> [args...]
// A module the suite targets that does not exist yet prints MODULE_MISSING:<rel> and
// exits 3, so a case fails on that one line instead of on a stack trace.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const [root, cmd, ...args] = process.argv.slice(2);

function load(rel) {
  try {
    return require(path.join(root, rel));
  } catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND" && String(e.message).includes(path.basename(rel))) {
      process.stdout.write("MODULE_MISSING:" + rel);
      process.exit(3);
    }
    throw e;
  }
}

const GATE = "hooks/lib/jev/two-stage/gate.js";
const DET = "hooks/workflow-state/complexity-routing/deterministic-signals.js";
const ROUTING = "hooks/workflow-state/complexity-routing.js";
const NORMALIZER = "bin/workflow/normalize-judge-signals";
const CONTROL = "hooks/workflow-state/state-io/control-dir.js";

const sortObj = (o) => Object.fromEntries(Object.keys(o || {}).sort().map((k) => [k, o[k]]));
const sortArr = (a) => (Array.isArray(a) ? a.slice().sort() : a);
const out = (v) => process.stdout.write(typeof v === "string" ? v : JSON.stringify(v));

const CMDS = {
  // gate <items-json> <policy-json> -> {adopted, delegated, unjudged, short_circuited, result}, keys sorted.
  gate() {
    const { applyGate } = load(GATE);
    const r = applyGate(JSON.parse(args[0]), JSON.parse(args[1]));
    out({ adopted: sortObj(r.adopted), delegated: sortArr(r.delegated), unjudged: sortArr(r.unjudged),
      short_circuited: r.short_circuited, result: r.result });
  },
  // det-norm <raw> <repo-root> -> the normalized repo-relative path, or "null".
  "det-norm"() {
    const { normalizeWorkPath } = load(DET);
    out(String(normalizeWorkPath(args[0], args[1])));
  },
  // det-parse <file|-> <repo-root> -> {status, paths}. "-" passes null (no source file).
  "det-parse"() {
    const { parseWriteCodeFiles } = load(DET);
    const bytes = args[0] === "-" ? null : fs.readFileSync(args[0]);
    const r = parseWriteCodeFiles(bytes, args[1]);
    out({ status: r.status, paths: r.paths });
  },
  // det-compute <file> <repo-root> -> computeDeterministic(parseWriteCodeFiles(...)).
  "det-compute"() {
    const { parseWriteCodeFiles, computeDeterministic } = load(DET);
    const list = parseWriteCodeFiles(fs.readFileSync(args[0]), args[1]);
    out(sortObj(computeDeterministic(list)));
  },
  "det-consts"() {
    const m = load(DET);
    out({ threshold: m.S1B_FILE_THRESHOLD, name: m.WRITE_CODE_FILES_NAME, rules: Boolean(m.S4_PATH_RULES) });
  },
  "routing-consts"() {
    const m = load(ROUTING);
    out({ signal_ids: m.SIGNAL_IDS, judged: m.JUDGED_SIGNAL_IDS || null,
      deterministic: m.DETERMINISTIC_SIGNAL_IDS || null, undecidable: m.UNDECIDABLE_SIGNAL || null });
  },
  // normalize <raw-file> -> normalize(raw) from the unchanged normalizer.
  normalize() {
    const { normalize } = load(NORMALIZER);
    out(normalize(fs.readFileSync(args[0], "utf8")));
  },
  // control-path <sid> <name> -> the session control-dir path for <name>.
  "control-path"() {
    const { controlPath } = load(CONTROL);
    out(controlPath(args[0], args[1]).replace(/\\/g, "/"));
  },
  // sha <file> -> sha256 hex, or "absent".
  sha() {
    out(fs.existsSync(args[0]) ? crypto.createHash("sha256").update(fs.readFileSync(args[0])).digest("hex") : "absent");
  },
  // json-get <file> <dotted-key> -> JSON of the value, or "absent".
  "json-get"() {
    if (!fs.existsSync(args[0])) return out("absent");
    let v = JSON.parse(fs.readFileSync(args[0], "utf8"));
    for (const k of args[1].split(".")) v = v === null || v === undefined ? undefined : v[k];
    return out(v === undefined ? "undefined" : JSON.stringify(v));
  },
  // json-set <file> <dotted-key> <json-value|__delete__>: tamper with a ticket in place.
  "json-set"() {
    const doc = JSON.parse(fs.readFileSync(args[0], "utf8"));
    const keys = args[1].split(".");
    let o = doc;
    for (const k of keys.slice(0, -1)) o = o[k];
    const last = keys[keys.length - 1];
    if (args[2] === "__delete__") delete o[last];
    else o[last] = JSON.parse(args[2]);
    fs.writeFileSync(args[0], JSON.stringify(doc));
    out("ok");
  },
  // log-q <log> <ticket> <expr>: evaluate <expr> over recs (all records of <ticket>) and r (the decision one).
  "log-q"() {
    const lines = fs.existsSync(args[0]) ? fs.readFileSync(args[0], "utf8").split("\n").filter(Boolean) : [];
    const all = lines.map((l) => { try { return JSON.parse(l); } catch (_e) { return null; } }).filter(Boolean);
    const recs = all.filter((x) => x.ticket === args[1]);
    const r = recs.find((x) => x.record_type === "decision") || null;
    // eslint-disable-next-line no-new-func
    const v = new Function("recs", "r", "all", "return (" + args[2] + ");")(recs, r, all);
    out(typeof v === "string" ? v : JSON.stringify(v));
  },
};

if (!Object.prototype.hasOwnProperty.call(CMDS, cmd)) {
  process.stderr.write("judge-probe: unknown cmd\n");
  process.exit(2);
}
CMDS[cmd]();
