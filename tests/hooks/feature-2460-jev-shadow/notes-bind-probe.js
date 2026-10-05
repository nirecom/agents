#!/usr/bin/env node
"use strict";
// Notes-session binding probe for d-adapter.sh (#2460 C12): the cwd's WORKTREE_NOTES Session-ID
// is used only when readState(notes sid) exists and its session_worktree path-equals the hook cwd,
// or the latest worktree entered event's own string cwd (path_source not fallback-process-cwd) path-equals it
// (start-context cwd never binds). Prints one "<row>\t<value>" line per row. Usage: node notes-bind-probe.js <repo> <plans-dir>
// Each row's value is "<notesSessionId>|<notes plan read>|<hook plan read>" unless noted.
const fs = require("fs");
const os = require("os");
const path = require("path");

const [repo, plansDir] = process.argv.slice(2);
const emit = (row, v) => process.stdout.write(row + "\t" + (typeof v === "string" ? v : JSON.stringify(v)) + "\n");
const safe = (row, fn) => { try { emit(row, fn()); } catch (e) { emit(row, "THREW:" + e.message); } };
let A;
try {
  A = require(path.join(repo, "bin", "workflow", "lib", "jev-complexity-adapter.js"));
} catch (e) {
  emit("load", "LOAD-FAIL:" + e.code);
  process.exit(0);
}
emit("load", typeof A.notesSessionId === "function" ? "ok" : "NOT-EXPORTED");
const io = require(path.join(repo, "hooks", "workflow-state", "state-io.js"));

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "jev2460-nb-"));
process.on("exit", () => { try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort */ } });
const WIN = process.platform === "win32";

function plan(id, mark) {
  for (const n of ["intent", "outline"]) fs.writeFileSync(path.join(plansDir, id + "-" + n + ".md"), "# " + n + "\n" + mark + "-" + n + "\n");
}
// notesDir(name, sid): a fresh dir whose WORKTREE_NOTES.md names <sid>; the notes sid has a plan.
function notesDir(name, sid) {
  const d = path.join(ROOT, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, "WORKTREE_NOTES.md"), "# Worktree Notes\n\nSession-ID: " + sid + "\n");
  plan(sid, "NB-NOTES-MARK-" + sid);
  return d;
}
const seed = (sid) => io.markStep(sid, "workflow_init", "complete");
function viaWorktree(sid, p) { seed(sid); io.recordSessionWorktree(sid, p); }
// viaCwd: session_start_context.cwd only (every main-checkout session has this) — never binds.
function viaCwd(sid, p) {
  seed(sid);
  io.updateTopLevel(sid, (rec) => { rec.session_start_context = Object.assign({}, rec.session_start_context, { cwd: p }); });
}
// viaEntered: a real worktree "entered" event (the EnterWorktree PostToolUse shape); projected as state.cwd.
function worktreeEvent(transition, p, source) {
  return { kind: "worktree", transition, git_branch: "feature/jev2460-nb", cwd: p, worktree_path: p,
    path_source: source, provenance: "observed", origin: "jev2460-notes-bind-probe" };
}
function viaEntered(sid, p) { seed(sid); io.appendEvents(sid, [worktreeEvent("entered", p, "tool_input")]); }
function viaExited(sid, p) { io.appendEvents(sid, [worktreeEvent("exited", p, "prior-entry")]); }
// probe(sid, cwd): notesSessionId, then whether buildRequest read the notes plan or the hook plan.
function probe(sid, cwd) {
  const hook = "nb-hook-" + sid;
  plan(hook, "NB-HOOK-MARK-" + sid);
  const s = String(A.buildRequest({ toolInput: { prompt: "p" }, sessionId: hook, stage: "outline", cwd }).state);
  return [String(A.notesSessionId(cwd)), s.includes("NB-NOTES-MARK-" + sid + "-intent"), s.includes("NB-HOOK-MARK-" + sid + "-intent")].join("|");
}
const posixForm = (d) => { const m = /^([A-Za-z]):[\\/](.*)$/.exec(d); return m ? "/" + m[1].toLowerCase() + "/" + m[2].replace(/\\/g, "/") : null; };

safe("bound-session-worktree", () => { const d = notesDir("sw", "nb-sw"); viaWorktree("nb-sw", d); return probe("nb-sw", d); });
// state.cwd projected only from session_start_context.cwd (no entered event): never binds (C12).
safe("unbound-start-context-cwd", () => {
  const d = notesDir("cw", "nb-cw");
  viaCwd("nb-cw", d);
  const s = io.readState("nb-cw");
  return [String(s.cwd) === d, s.worktree_entered_at === null, probe("nb-cw", d)].join("|");
});
safe("bound-entered-cwd", () => {
  const d = notesDir("en", "nb-en");
  viaEntered("nb-en", d);
  const s = io.readState("nb-en");
  return [s.worktree_entered_at !== null, String(s.cwd) === d, probe("nb-en", d)].join("|");
});
// A later exit does not revoke the binding: worktree_entered_at and state.cwd stay set.
safe("bound-entered-then-exited", () => {
  const d = notesDir("ex", "nb-ex");
  viaEntered("nb-ex", d);
  viaExited("nb-ex", d);
  const s = io.readState("nb-ex");
  return [s.worktree_entered_at !== null, s.worktree_exited_at !== null, String(s.cwd) === d, probe("nb-ex", d)].join("|");
});
// The start context names d, the entered event names another dir: state.cwd is the other dir, no bind.
safe("unbound-entered-other", () => {
  const d = notesDir("eo", "nb-eo");
  const other = path.join(ROOT, "eo-elsewhere");
  fs.mkdirSync(other, { recursive: true });
  viaCwd("nb-eo", d);
  io.appendEvents("nb-eo", [worktreeEvent("entered", other, "tool_input")]);
  return [String(io.readState("nb-eo").cwd) === other, probe("nb-eo", d)].join("|");
});
// session_worktree equals the cwd while state.cwd (an entered event) names another dir: binds (OR).
safe("bound-session-worktree-cwd-elsewhere", () => {
  const d = notesDir("or", "nb-or");
  const other = path.join(ROOT, "or-elsewhere");
  fs.mkdirSync(other, { recursive: true });
  viaWorktree("nb-or", d);
  io.appendEvents("nb-or", [worktreeEvent("entered", other, "tool_input")]);
  return [String(io.readState("nb-or").cwd) === other, probe("nb-or", d)].join("|");
});
// C12: sessions A and B both started on the same main checkout d (start-context cwd only); d's
// notes name A; a dispatch from B must not adopt A. Value: "<notesSessionId>|<A plan read>|<B plan read>".
safe("main-checkout-shared-cwd", () => {
  const d = notesDir("mc", "nb-mA");
  viaCwd("nb-mA", d);
  viaCwd("nb-mB", d);
  plan("nb-mB", "NB-MAIN-B-MARK");
  const s = String(A.buildRequest({ toolInput: { prompt: "p" }, sessionId: "nb-mB", stage: "outline", cwd: d }).state);
  return [String(A.notesSessionId(d)), s.includes("NB-NOTES-MARK-nb-mA-intent"), s.includes("NB-MAIN-B-MARK-intent")].join("|");
});
// A non-string state.cwd, from an entered event or from the start context, never binds or throws.
safe("non-string-state-cwd", () => {
  const d1 = notesDir("nc1", "nb-nc1");
  seed("nb-nc1");
  io.appendEvents("nb-nc1", [worktreeEvent("entered", 42, "tool_input")]);
  const s1 = io.readState("nb-nc1");
  const d2 = notesDir("nc2", "nb-nc2");
  seed("nb-nc2");
  io.updateTopLevel("nb-nc2", (rec) => { rec.session_start_context = Object.assign({}, rec.session_start_context, { cwd: 42 }); });
  const s2 = io.readState("nb-nc2");
  return [typeof s1.cwd, s1.worktree_entered_at !== null, probe("nb-nc1", d1), typeof s2.cwd, probe("nb-nc2", d2)].join("|");
});
// The state exists but its cwd is the fixture project ($CLAUDE_PROJECT_DIR), no session_worktree.
safe("unbound-default-state", () => { const d = notesDir("ud", "nb-ud"); seed("nb-ud"); return probe("nb-ud", d); });
safe("unbound-other-worktree", () => {
  const d = notesDir("ow", "nb-ow");
  const other = path.join(ROOT, "ow-elsewhere");
  fs.mkdirSync(other, { recursive: true });
  viaWorktree("nb-ow", other);
  io.appendEvents("nb-ow", [worktreeEvent("entered", other, "tool_input")]);
  return probe("nb-ow", d);
});
safe("no-state", () => { const d = notesDir("ns", "nb-ns"); return [String(io.readState("nb-ns")), probe("nb-ns", d)].join("|"); });
// Prefix is not equality: bound to <d> with cwd <d>-x, and bound to <d>-x with cwd <d>.
safe("prefix-not-equal", () => {
  const short = notesDir("pf", "nb-pf1");
  const long = notesDir("pf-x", "nb-pf2");
  viaWorktree("nb-pf1", short);
  viaWorktree("nb-pf2", long);
  fs.writeFileSync(path.join(long, "WORKTREE_NOTES.md"), "Session-ID: nb-pf1\n");
  fs.writeFileSync(path.join(short, "WORKTREE_NOTES.md"), "Session-ID: nb-pf2\n");
  const child = notesDir(path.join("pf", "child"), "nb-pf1");
  return [probe("nb-pf1", long), probe("nb-pf2", short), probe("nb-pf1", child)].join(",");
});
safe("norm-trailing-sep", () => {
  const d = notesDir("ts", "nb-ts");
  viaWorktree("nb-ts", d + path.sep);
  const d2 = notesDir("ts2", "nb-ts2");
  viaWorktree("nb-ts2", d2);
  return [probe("nb-ts", d), probe("nb-ts2", d2 + path.sep)].join(",");
});
// win32: separators, drive-letter/path case and the /c/ form all compare equal.
safe("norm-win32", () => {
  if (!WIN) return "SKIP-NOT-WIN32";
  const variants = {
    fwd: (d) => d.replace(/\\/g, "/"),
    upper: (d) => d.toUpperCase(),
    lower: (d) => d.toLowerCase(),
    backslash: (d) => d + "\\",
    posix: (d) => posixForm(d),
  };
  return Object.keys(variants).map((k) => {
    const sid = "nb-w-" + k;
    const d = notesDir("w-" + k, sid);
    viaWorktree(sid, variants[k](d));
    return k + "=" + String(A.notesSessionId(d));
  }).concat((() => {
    const sid = "nb-w-cwdposix";
    const d = notesDir("w-cwdposix", sid);
    viaWorktree(sid, d);
    return ["cwdposix=" + String(A.notesSessionId(posixForm(d)))];
  })()).join(",");
});
// POSIX: the comparison is case-sensitive.
safe("norm-posix-case", () => {
  if (WIN) return "SKIP-WIN32";
  const d = notesDir("pc", "nb-pc");
  viaWorktree("nb-pc", d.toUpperCase());
  return probe("nb-pc", d);
});
// A non-string session_worktree (and cwd projected from the fixture project) never binds or throws.
safe("non-string-binding", () => {
  const d = notesDir("nn", "nb-nn");
  seed("nb-nn");
  io.updateTopLevel("nb-nn", (rec) => { rec.session_worktree = 42; });
  return [String(io.readState("nb-nn") && io.readState("nb-nn").session_worktree), probe("nb-nn", d)].join("|");
});
// A corrupt state file: readState gives null (or throws inside the adapter); either way null, no throw.
safe("corrupt-state", () => {
  const d = notesDir("cs", "nb-cs");
  viaWorktree("nb-cs", d);
  fs.writeFileSync(io.getStatePath("nb-cs"), "{not json");
  return probe("nb-cs", d);
});

// dropLatestEnteredKey(sid, key): hand-edit the state file so the latest worktree entered event lacks <key>
// (the shape appendEvents refuses but older / migrated files carry); seq stays contiguous.
function dropLatestEnteredKey(sid, key) {
  const f = io.getStatePath(sid);
  const raw = JSON.parse(fs.readFileSync(f, "utf8"));
  const entered = raw.events.filter((e) => e && e.kind === "worktree" && e.transition === "entered");
  delete entered[entered.length - 1][key];
  fs.writeFileSync(f, JSON.stringify(raw));
}
// The binding must come from the latest entered event's own cwd: a null or absent event cwd lets
// state.cwd fall back to the start-context cwd, which never binds (C12). Value: "<entered_at set>|<state.cwd equal>|<probe>".
const enteredRow = (sid, d) => { const s = io.readState(sid); return [s.worktree_entered_at !== null, String(s.cwd) === d, probe(sid, d)].join("|"); };
safe("unbound-entered-null-cwd", () => {
  const d = notesDir("enl", "nb-enl");
  viaCwd("nb-enl", d);
  io.appendEvents("nb-enl", [worktreeEvent("entered", null, "migration-unknown")]);
  return enteredRow("nb-enl", d);
});
safe("unbound-entered-missing-cwd", () => {
  const d = notesDir("enm", "nb-enm");
  viaCwd("nb-enm", d);
  io.appendEvents("nb-enm", [worktreeEvent("entered", null, "migration-unknown")]);
  dropLatestEnteredKey("nb-enm", "cwd");
  return enteredRow("nb-enm", d);
});
// A fallback-process-cwd path is the hook process's own cwd (a guess), never evidence of entry.
safe("unbound-entered-fallback-process-cwd", () => {
  const d = notesDir("efb", "nb-efb");
  seed("nb-efb");
  io.appendEvents("nb-efb", [worktreeEvent("entered", d, "fallback-process-cwd")]);
  return enteredRow("nb-efb", d);
});
// An older entered event with no path_source key still binds through its own matching cwd.
safe("bound-entered-no-path-source", () => {
  const d = notesDir("enp", "nb-enp");
  viaEntered("nb-enp", d);
  dropLatestEnteredKey("nb-enp", "path_source");
  return enteredRow("nb-enp", d);
});
// The latest entered event decides: an earlier matching entry is superseded by a later one elsewhere.
safe("unbound-latest-entered-other", () => {
  const d = notesDir("elo", "nb-elo");
  const other = path.join(ROOT, "elo-elsewhere");
  fs.mkdirSync(other, { recursive: true });
  viaEntered("nb-elo", d);
  io.appendEvents("nb-elo", [worktreeEvent("entered", other, "tool_input")]);
  return enteredRow("nb-elo", d);
});
// ... and by a later entered event whose cwd key is absent (state.cwd keeps the earlier path).
safe("unbound-latest-entered-missing-cwd", () => {
  const d = notesDir("elm", "nb-elm");
  viaEntered("nb-elm", d);
  io.appendEvents("nb-elm", [worktreeEvent("entered", null, "migration-unknown")]);
  dropLatestEnteredKey("nb-elm", "cwd");
  return enteredRow("nb-elm", d);
});
