#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/state-handoff-record/legacy-handoff-md.js, bin/lib/resume-session/upstream-view.js, bin/resume-session-detect
// Tags: TL2, session, resume, handoff, state-handoff-record, input-validation, path-traversal, security, symlink, regression-2576, regression-2302, regression-2652, scope:issue-specific, pwsh-not-required
// #2576/#2652: `--from` shows the session-upstream's state handoff records (and, during the
// migration, its pre-#2652 <sid>.control/handoff.md) through the state handoff reader, not an
// artifact. #2302: an id failing SESSION_ID_VALID_RE resolves nothing — unknown-session, exit 3.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2576-"));
process.on("exit", () => {
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const ROOT = path.resolve(__dirname, "..", "..");
const mod = (rel) => require(path.join(ROOT, rel));
const fx = require("../lib/state-handoff-record-fixture");
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const PLANS_DIR = process.env.WORKFLOW_PLANS_DIR;
const HOME = fs.mkdtempSync(path.join(SCRATCH, "home-"));
const TBASE = fs.mkdtempSync(path.join(SCRATCH, "transcripts-"));
const CLI = path.join(ROOT, "bin", "resume-session-detect");

let passed = 0;
let failed = 0;
let skipped = 0;
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
const slash = (p) => String(p).replace(/\\/g, "/");

// Every child runs from a neutral cwd with no inherited session id and an empty transcript base.
function spawnNode(args, extraEnv) {
  const env = Object.assign({}, process.env, { HOME, USERPROFILE: HOME, CLAUDE_TRANSCRIPT_BASE_DIR: TBASE }, extraEnv || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  if (extraEnv && extraEnv.CLAUDE_CODE_SESSION_ID) env.CLAUDE_CODE_SESSION_ID = extraEnv.CLAUDE_CODE_SESSION_ID;
  return spawnSync(process.execPath, args, { cwd: HOME, env, encoding: "utf8", timeout: 60000 });
}
function parseOut(run) {
  try { return JSON.parse(run.stdout); } catch (e) { throw new Error(`stdout is not one JSON record (${e.message}): ${show(run.stdout)} stderr=${show(run.stderr)}`); }
}
function fromView(up, heir) {
  const run = spawnNode([CLI, "--from", up], heir ? { CLAUDE_CODE_SESSION_ID: heir } : null);
  return { run, d: parseOut(run) };
}

// A session-upstream with a live state file and an intent artifact. clarify_intent is left
// pending: completing it needs a glossary-check record, which this view does not depend on.
function seedActive(sid) {
  fx.makeState(sid, "/fixture/f2576/repo");
  fs.writeFileSync(path.join(PLANS_DIR, `${sid}-intent.md`), "**Title:** handoff donor\n");
}
function seedHeir(sid) {
  const io = mod("hooks/workflow-state/state-io");
  io.writeState(sid, io.createInitialState(sid, { cwd: "/fixture/f2576/repo", git_branch: "feature/donor" }));
}

caseBegin("from-renders-state-handoff-record", "bin/lib/resume-session/upstream-view.js");
{
  const up = "f2576-t23d-donor";
  const heir = "f2576-t23d-heir";
  const marker = "F2576-T23D-RECORD-MARKER";
  seedActive(up);
  seedHeir(heir);
  fx.pushEvents(up, [fx.record({ cls: "A", at_step: "-", record_key: "t23d", summary: marker, origin: "procedure-point", provenance: "declared" })]);
  let d = null;
  check("T23d: --from exits 0 and answers on one JSON record", () => {
    const r = fromView(up, heir);
    d = r.d;
    eq(r.run.status, 0, "--from exit (stderr " + show(r.run.stderr) + ")");
  });
  check("T23d: handoff_rendered carries the state handoff record's summary", () => {
    if (!d) return "no record";
    eq(typeof d.handoff_rendered === "string" && d.handoff_rendered.indexOf(marker) !== -1, true, "marker in " + show(d.handoff_rendered));
  });
  check("T23d: artifacts has no handoff kind", () => {
    if (!d) return "no record";
    eq(Object.prototype.hasOwnProperty.call(d.artifacts || {}, "handoff"), false, "artifacts.handoff present (" + show(d.artifacts) + ")");
  });
}
caseEnd();

caseBegin("from-legacy-handoff-only-is-artifacts-only", "bin/lib/resume-session/upstream-view.js");
{
  const up = "f2576-t23f-donor";
  const marker = "F2576-T23F-LEGACY-MARKER";
  // No state file and no plan artifact: the legacy handoff.md is all the session-upstream left.
  fx.writeLegacyHandoff(up, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "t23f", summary: marker }]);
  check("T23f: fixture anchor — only the control-dir handoff.md exists", () => {
    eq(fs.existsSync(fx.legacyHandoffPath(up)), true, "control-dir handoff exists");
    eq(fs.existsSync(path.join(STATE_DIR, `${up}.json`)), false, "state file exists");
    eq(fs.existsSync(path.join(PLANS_DIR, `${up}-intent.md`)), false, "intent exists");
  });
  check("T23f: a legacy-handoff-only session is artifacts-only with state_expired, and its entry is rendered", () => {
    const { run, d } = fromView(up);
    eq(run.status, 0, "--from exit");
    eq(d.availability, "artifacts-only", "availability");
    eq(d.inherit_result && d.inherit_result.reason, "state_expired", "inherit_result.reason");
    eq(typeof d.handoff_rendered === "string" && d.handoff_rendered.indexOf(marker) !== -1, true, "marker in " + show(d.handoff_rendered));
  });
}
caseEnd();

caseBegin("from-state-and-legacy-in-time-order", "bin/lib/resume-session/upstream-view.js");
{
  const up = "f2576-both-donor";
  seedActive(up);
  fx.writeLegacyHandoff(up, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "old-legacy", summary: "F2576-BOTH-LEGACY-FIRST" }]);
  fx.pushEvents(up, [fx.record({ at: fx.isoAt(2), cls: "A", at_step: "-", record_key: "new-state", summary: "F2576-BOTH-STATE-SECOND" })]);
  check("B1: both the legacy entry and the state record are rendered, older first", () => {
    const { d } = fromView(up);
    const text = String(d.handoff_rendered);
    const a = text.indexOf("F2576-BOTH-LEGACY-FIRST");
    const b = text.indexOf("F2576-BOTH-STATE-SECOND");
    eq([a !== -1, b !== -1, a < b], [true, true, true], "legacy then state in " + show(text));
  });
}
caseEnd();

caseBegin("from-nothing-is-none", "bin/lib/resume-session/upstream-view.js");
{
  check("N1: a session with no state, no plan artifact and no handoff is none with no rendered handoff", () => {
    const v = mod("bin/lib/resume-session/upstream-view").buildUpstreamView({ heirSid: null, upstreamSid: "f2576-nothing-at-all" });
    eq(v.availability, "none", "availability");
    eq(v.handoff_rendered, null, "handoff_rendered");
  });
}
caseEnd();

caseBegin("from-reads-the-reader-once", "bin/lib/resume-session/upstream-view.js");
{
  const up = "f2576-once-donor";
  seedActive(up);
  fx.pushEvents(up, [fx.record({ cls: "A", at_step: "-", record_key: "once", summary: "F2576-ONCE" })]);
  check("O1: one buildUpstreamView calls readStateHandoff exactly once, for the session upstream", () => {
    const barrelPath = require.resolve(path.join(ROOT, "hooks", "lib", "state-handoff-record"));
    const barrel = require(barrelPath);
    const real = barrel.readStateHandoff;
    const calls = [];
    barrel.readStateHandoff = (sid) => {
      calls.push(sid);
      return real(sid);
    };
    const viewPath = require.resolve(path.join(ROOT, "bin", "lib", "resume-session", "upstream-view"));
    delete require.cache[viewPath];
    try {
      require(viewPath).buildUpstreamView({ heirSid: null, upstreamSid: up });
    } finally {
      barrel.readStateHandoff = real;
      delete require.cache[viewPath];
    }
    eq(calls, [up], "readStateHandoff calls");
  });
}
caseEnd();

caseBegin("from-invalid-sid-is-unknown-session", "bin/lib/resume-session/upstream-view.js");
{
  // Plant a real file at the exact path each malformed id would join to, so a
  // refusal can only come from validation, never from the file being absent.
  const parent = path.dirname(PLANS_DIR);
  const planted = [
    path.join(parent, "x-intent.md"),
    path.join(PLANS_DIR, "a", "b-intent.md"),
    path.join(PLANS_DIR, "a.b-intent.md"),
    path.join(PLANS_DIR, "..-intent.md"),
    path.join(PLANS_DIR, "-intent.md"),
  ];
  for (const p of planted) {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, "**Title:** F2576-PLANTED-OUTSIDE-BODY\n");
  }
  const leaks = [slash(STATE_DIR), slash(PLANS_DIR), slash(parent)];
  const leaked = (text) => {
    const s = slash(text).replace(/\/\//g, "/");
    const hit = leaks.find((p) => s.indexOf(p) !== -1);
    if (hit) return "path disclosed: " + hit;
    if (/-intent\.md|F2576-PLANTED-OUTSIDE-BODY/.test(text)) return "planted artifact disclosed";
    return null;
  };
  for (const bad of ["../x", "a/b", "a.b", ".."]) {
    check(`I1: --from ${show(bad)} exits 3 as unknown-session and discloses no path`, () => {
      const run = spawnNode([CLI, "--from", bad]);
      const d = parseOut(run);
      eq(run.status, 3, "--from exit");
      eq(d.availability, "none", "availability");
      eq(d.reason, "unknown-session", "reason");
      const why = leaked((run.stdout || "") + (run.stderr || ""));
      if (why) return why;
      return undefined;
    });
  }
  const view = mod("bin/lib/resume-session/upstream-view");
  for (const bad of ["", "../x", "a/b", "a.b", ".."]) {
    check(`I2: buildUpstreamView with upstreamSid ${show(bad)} is unknown-session with no artifact`, () => {
      const v = view.buildUpstreamView({ heirSid: null, upstreamSid: bad });
      eq(v && v.availability, "none", "availability");
      eq(v && v.reason, "unknown-session", "reason");
      const arts = (v && v.artifacts) || {};
      for (const k of Object.keys(arts)) if (arts[k] !== null) return `artifact ${k} resolved: ${show(arts[k])}`;
      const why = leaked(JSON.stringify(v));
      if (why) return why;
      return undefined;
    });
  }
}
caseEnd();

caseBegin("upstream-view-entry-validation", "bin/lib/resume-session/upstream-view.js");
{
  // Seed, at the exact path each malformed id would join to, every store a lookup reads:
  // state file, handoff (control dir and plans dir), session-progress.md and a transcript.
  // Any of them surfacing in the view means a lookup ran past the entry check.
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TBASE;
  const view = mod("bin/lib/resume-session/upstream-view");
  const SENT = "F2576-C3-LEAK";
  const plant = (p, body) => {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, body);
  };
  for (const bad of ["../x", "a/b", "a.b", "", ".."]) {
    plant(path.join(STATE_DIR, `${bad}.json`), JSON.stringify({
      version: 5, session_id: `${SENT}-state`, created_at: "2026-01-01T00:00:00.000Z",
      session_start_context: { cwd: `/${SENT}-state-cwd`, git_branch: `${SENT}-branch` }, events: [],
    }));
    plant(path.join(STATE_DIR, `${bad}.control`, "handoff.md"), `# Handoff\n\n- ${SENT}-handoff-control\n`);
    plant(path.join(PLANS_DIR, `${bad}-handoff.md`), `# Handoff\n\n- ${SENT}-handoff-plans\n`);
    plant(path.join(PLANS_DIR, `${bad}-session-progress.md`), `## Current state\n\n${SENT}-progress\n`);
    plant(path.join(TBASE, "c3-proj", `${bad}.jsonl`), `{"type":"user","message":"${SENT}-transcript"}\n`);
  }
  const leaks = [slash(STATE_DIR), slash(PLANS_DIR), slash(TBASE), slash(path.dirname(PLANS_DIR))];
  for (const bad of ["../x", "a/b", "a.b", "", ".."]) {
    check(`I3: buildUpstreamView(${show(bad)}) is the unknown-session NONE view and resolves no seeded store`, () => {
      const v = view.buildUpstreamView({ heirSid: null, upstreamSid: bad });
      eq(v && v.type, "upstream", "type");
      eq(v && v.availability, "none", "availability");
      eq(v && v.reason, "unknown-session", "reason");
      eq(v && v.handoff_rendered, null, "handoff_rendered");
      eq(Object.prototype.hasOwnProperty.call(v, "progress_file"), false, "progress_file present");
      eq(Object.prototype.hasOwnProperty.call(v, "inherit_result"), false, "inherit_result present");
      const arts = v.artifacts || {};
      for (const k of Object.keys(arts)) if (arts[k] !== null) return `artifact ${k} resolved: ${show(arts[k])}`;
      const tail = v.transcript_tail || {};
      eq(tail.available === true, false, "transcript_tail.available");
      eq(tail.path == null, true, "transcript_tail.path is empty (" + show(tail.path) + ")");
      const text = slash(JSON.stringify(v)).replace(/\/\//g, "/");
      if (text.indexOf(SENT) !== -1) return "seeded content disclosed: " + text;
      const hit = leaks.find((p) => text.indexOf(p) !== -1);
      if (hit) return "path disclosed: " + hit;
      return undefined;
    });
  }
}
caseEnd();

// artifactsFor is module-private, so each kind's resolver is probed through buildUpstreamView.
caseBegin("artifacts-for-per-kind-resolution", "bin/lib/resume-session/upstream-view.js");
{
  const view = mod("bin/lib/resume-session/upstream-view");
  const plant = (p, body) => {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, body);
  };
  const targetsOf = (sid) => ({
    intent: path.join(PLANS_DIR, `${sid}-intent.md`),
    outline: path.join(PLANS_DIR, `${sid}-outline.md`),
    detail: path.join(PLANS_DIR, `${sid}-detail.md`),
  });
  check("A0: ARTIFACT_KINDS is exactly intent/outline/detail (handoff is no artifact kind)", () => {
    eq(view.ARTIFACT_KINDS, ["intent", "outline", "detail"], "ARTIFACT_KINDS");
  });
  for (const bad of ["../x", "a/b", "a.b", "", ".."]) {
    const t = targetsOf(bad);
    for (const k of Object.keys(t)) plant(t[k], "**Title:** F2576-A1-PLANTED\n");
    check(`A1: buildUpstreamView(${show(bad)}) resolves every kind to null without throwing, traversal targets planted`, () => {
      const v = view.buildUpstreamView({ heirSid: null, upstreamSid: bad });
      const arts = (v && v.artifacts) || {};
      for (const k of Object.keys(arts)) if (arts[k] != null) return `artifact ${k} resolved: ${show(arts[k])}`;
      eq(v.availability, "none", "availability");
      return undefined;
    });
  }
  check("A2: a valid sid with intent/outline/detail and a legacy handoff.md resolves exactly the three plan kinds", () => {
    const sid = "f2576-a2-all-kinds";
    const t = targetsOf(sid);
    for (const k of Object.keys(t)) plant(t[k], "**Title:** F2576-A2\n");
    fx.writeLegacyHandoff(sid, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "a2", summary: "F2576-A2-LEGACY" }]);
    const v = view.buildUpstreamView({ heirSid: null, upstreamSid: sid });
    eq(v.availability, "artifacts-only", "availability");
    eq(Object.keys(v.artifacts).sort(), ["detail", "intent", "outline"], "artifact kinds");
    for (const k of Object.keys(t)) {
      const got = v.artifacts[k];
      eq(typeof got === "string" ? path.resolve(got) : got, path.resolve(t[k]), `artifacts.${k}`);
    }
  });
}
caseEnd();

caseBegin("handoff-directory-is-not-a-handoff", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const view = mod("bin/lib/resume-session/upstream-view");
  const sid = "f2576-c2-handoff-dir";
  const dirAsHandoff = fx.legacyHandoffPath(sid);
  fs.mkdirSync(dirAsHandoff, { recursive: true });
  check("D0: fixture anchor — handoff.md is a directory and no state file exists", () => {
    eq(fs.statSync(dirAsHandoff).isDirectory(), true, "handoff.md is a directory");
    eq(fs.existsSync(path.join(STATE_DIR, `${sid}.json`)), false, "state file exists");
  });
  check("D1: the state handoff reader returns no entry for a directory named handoff.md", () => {
    eq(mod("hooks/lib/state-handoff-record").readStateHandoff(sid).entries, [], "entries");
  });
  check("D3: buildUpstreamView does not report the directory as a handoff", () => {
    const v = view.buildUpstreamView({ heirSid: null, upstreamSid: sid });
    eq(v.availability, "none", "availability");
    eq(v.handoff_rendered, null, "handoff_rendered");
  });
}
caseEnd();

// A handoff.md symlink would let the control dir disclose any file it points at, so only
// a regular file (lstat) counts. The regular-file positive control is T23f.
caseBegin("handoff-symlink-is-not-a-handoff", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
{
  const view = mod("bin/lib/resume-session/upstream-view");
  const sid = "f2576-s-handoff-symlink";
  const marker = "F2576-S-SYMLINK-TARGET-MARKER";
  const target = path.join(SCRATCH, "outside-control", "secret.md");
  const link = fx.legacyHandoffPath(sid);
  // The target is a well-formed legacy handoff.md, so following the link WOULD render the marker.
  const donorSid = "f2576-s-symlink-target-src";
  const donorFile = fx.writeLegacyHandoff(donorSid, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "s-symlink", summary: marker }]);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, fs.readFileSync(donorFile, "utf8"));
  fs.rmSync(path.dirname(donorFile), { recursive: true, force: true });
  fs.mkdirSync(path.dirname(link), { recursive: true });
  let linked = false;
  try {
    fs.symlinkSync(target, link, "file");
    linked = true;
  } catch (e) {
    if (!e || (e.code !== "EPERM" && e.code !== "EACCES")) throw e;
    skipped += 4;
    const msg = `SKIP: S0-S3 handoff-symlink cases — symlink creation refused (${e.code}); enable Windows developer mode to run them\n`;
    process.stdout.write(msg);
    process.stderr.write(msg);
  }
  if (linked) {
    check("S0: fixture anchor — handoff.md is a symlink to a well-formed handoff outside the control dir carrying the marker", () => {
      eq(fs.lstatSync(link).isSymbolicLink(), true, "handoff.md is a symlink");
      eq(fs.existsSync(path.dirname(donorFile)), false, "scratch donor control dir removed");
      eq(fs.readFileSync(link, "utf8").indexOf(marker) !== -1, true, "marker readable through the link");
      eq(slash(path.relative(path.dirname(link), target)).startsWith(".."), true, "target is outside the control dir");
      eq(fs.existsSync(path.join(STATE_DIR, `${sid}.json`)), false, "state file exists");
    });
    check("S1: the state handoff reader does not follow a symlinked handoff.md", () => {
      const out = mod("hooks/lib/state-handoff-record").readStateHandoff(sid);
      eq(out.entries, [], "entries");
      eq(JSON.stringify(out).indexOf(marker) === -1, true, "target marker absent");
    });
    check("S2: buildUpstreamView reports no handoff and discloses nothing of the link target", () => {
      const v = view.buildUpstreamView({ heirSid: null, upstreamSid: sid });
      eq(JSON.stringify(v).indexOf(marker) === -1, true, "target marker absent from the view");
      eq(v.availability, "none", "availability");
      eq(v.handoff_rendered == null, true, "handoff_rendered is null (" + show(v.handoff_rendered) + ")");
    });
    check("S3: --from on the real CLI reports no handoff and discloses neither the marker nor the target path", () => {
      const run = spawnNode([CLI, "--from", sid]);
      const d = parseOut(run);
      const out = (run.stdout || "") + (run.stderr || "");
      const flat = slash(out).replace(/\/\//g, "/");
      if (out.indexOf(marker) !== -1) return "target marker disclosed by the CLI";
      for (const p of [target, fs.realpathSync(target)]) {
        if (out.indexOf(p) !== -1 || flat.indexOf(slash(p)) !== -1) return "target path disclosed by the CLI: " + p;
      }
      eq(d.handoff_rendered == null, true, "handoff_rendered is null (" + show(d.handoff_rendered) + ")");
      return undefined;
    });
  }
}
caseEnd();

// The --from view must tell a state handoff reader failure apart from "no records", as --list does.
const viewOf = (sid) => mod("bin/lib/resume-session/upstream-view").buildUpstreamView({ heirSid: null, upstreamSid: sid });
const controlDirOf = (sid) => path.dirname(fx.legacyHandoffPath(sid));
const corruptState = (sid) => fs.writeFileSync(path.join(STATE_DIR, `${sid}.json`), "{ not json", "utf8");
const hasMarker = (v, m) => eq(typeof v.handoff_rendered === "string" && v.handoff_rendered.indexOf(m) !== -1, true, "marker in " + show(v.handoff_rendered));
// A regular file at <sid>.control makes the legacy source unreadable (the reader's R24 fixture).
const blockControlDir = (sid) => { fs.rmSync(controlDirOf(sid), { recursive: true, force: true }); fs.writeFileSync(controlDirOf(sid), "not a directory", "utf8"); };
const quietView = (sid) => { const orig = process.stderr.write; process.stderr.write = () => true; try { return viewOf(sid); } finally { process.stderr.write = orig; } };

caseBegin("from-corrupt-state-names-state-error", "bin/lib/resume-session/upstream-view.js");
{
  const up = "f2576-e1-corrupt-state";
  corruptState(up);
  check("E1: a corrupt-state-only session is none/state-unreadable naming \"state\" (view and CLI exit 3), unlike a session with no records", () => {
    const v = viewOf(up);
    eq(Array.isArray(v.state_handoff_errors) && v.state_handoff_errors.indexOf("state") !== -1, true, "state in " + show(v.state_handoff_errors));
    eq([v.availability, v.reason], ["none", "state-unreadable"], "view availability/reason");
    eq(viewOf("f2576-e1-no-record-at-all").state_handoff_errors, [], "no-record view state_handoff_errors");
    const cli = fromView(up);
    eq([cli.run.status, cli.d.availability, cli.d.reason, cli.d.state_handoff_errors], [3, "none", "state-unreadable", ["state"]], "CLI exit/availability/reason/state_handoff_errors");
  });
}
caseEnd();

caseBegin("from-reader-exception-is-reader-error", "bin/lib/resume-session/upstream-view.js");
{
  const up = "f2576-e2-reader-throws";
  seedActive(up);
  fx.pushEvents(up, [fx.record({ cls: "A", at_step: "-", record_key: "e2", summary: "F2576-E2" })]);
  check("E2: a throwing readStateHandoff yields state_handoff_errors [\"reader\"] and the view is still returned", () => {
    const barrel = require(require.resolve(path.join(ROOT, "hooks", "lib", "state-handoff-record")));
    const real = barrel.readStateHandoff;
    barrel.readStateHandoff = () => { throw new Error("F2576-E2 forced reader failure"); };
    const viewPath = require.resolve(path.join(ROOT, "bin", "lib", "resume-session", "upstream-view"));
    delete require.cache[viewPath];
    let v;
    try { v = require(viewPath).buildUpstreamView({ heirSid: null, upstreamSid: up }); } finally { barrel.readStateHandoff = real; delete require.cache[viewPath]; }
    eq([!!v && v.type, v.state_handoff_errors, v.handoff_rendered], ["upstream", ["reader"], null], "type/state_handoff_errors/handoff_rendered");
  });
}
caseEnd();

caseBegin("from-error-and-no-error-views", "bin/lib/resume-session/upstream-view.js");
{
  const e3 = "f2576-e3-legacy-unreadable";
  blockControlDir(e3);
  check("E3: an unresolvable control dir puts \"legacy-handoff-md\" in state_handoff_errors", () => {
    eq(fs.statSync(controlDirOf(e3)).isFile(), true, "fixture anchor: <sid>.control is a regular file");
    const v = quietView(e3);
    eq([v.state_handoff_errors, v.handoff_rendered], [["legacy-handoff-md"], null], "state_handoff_errors/handoff_rendered");
  });
  const e4 = "f2576-e4-zero-records";
  seedActive(e4);
  check("E4: a readable state file with zero records is state_handoff_errors [] and handoff_rendered null", () => {
    const v = viewOf(e4);
    eq([v.availability, v.state_handoff_errors, v.handoff_rendered], ["state-and-artifacts", [], null], "availability/state_handoff_errors/handoff_rendered");
  });
  const e5 = "f2576-e5-with-records";
  seedActive(e5);
  fx.pushEvents(e5, [fx.record({ cls: "A", at_step: "-", record_key: "e5", summary: "F2576-E5-MARK" })]);
  check("E5: a readable state file with records is state_handoff_errors [] and renders the entry", () => {
    const v = viewOf(e5);
    eq(v.state_handoff_errors, [], "state_handoff_errors");
    hasMarker(v, "F2576-E5-MARK");
  });
  check("E7: the NONE views (nothing stored, invalid sid) are unknown-session and carry state_handoff_errors []", () => {
    const a = viewOf("f2576-e7-nothing");
    const b = viewOf("../x");
    eq([a.availability, a.reason, a.state_handoff_errors, b.availability, b.state_handoff_errors], ["none", "unknown-session", [], "none", []], "availability/reason/state_handoff_errors");
  });
  const e6 = "f2576-e6-corrupt-state-legacy-ok";
  fx.writeLegacyHandoff(e6, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "e6", summary: "F2576-E6-MARK" }]);
  corruptState(e6);
  check("E6: a corrupt state file with a readable legacy handoff renders the legacy entry, names \"state\", and is not none/state-unreadable", () => {
    const v = viewOf(e6);
    eq(v.state_handoff_errors, ["state"], "state_handoff_errors");
    eq([v.availability !== "none", v.reason !== "state-unreadable"], [true, true], "availability=" + show(v.availability) + " reason=" + show(v.reason));
    hasMarker(v, "F2576-E6-MARK");
  });
  const e6b = "f2576-e6b-state-ok-legacy-blocked";
  seedActive(e6b);
  fx.pushEvents(e6b, [fx.record({ cls: "A", at_step: "-", record_key: "e6b", summary: "F2576-E6B-MARK" })]);
  blockControlDir(e6b);
  check("E6b: readable state records still render while the legacy source names \"legacy-handoff-md\"", () => {
    const v = quietView(e6b);
    eq(v.state_handoff_errors, ["legacy-handoff-md"], "state_handoff_errors");
    hasMarker(v, "F2576-E6B-MARK");
  });
}
caseEnd();

process.stdout.write(`Total: ${passed} passed, ${failed} failed, ${skipped} skipped\n`);
if (skipped > 0) process.stderr.write(`WARNING: ${skipped} case(s) skipped — see SKIP lines\n`);
process.exitCode = failed === 0 ? 0 : 1;
