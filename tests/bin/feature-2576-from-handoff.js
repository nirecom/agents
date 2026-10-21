#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/handoff-artifact.js, bin/lib/resume-session/upstream-view.js, bin/resume-session-detect
// Tags: TL2, session, resume, handoff, input-validation, path-traversal, security, symlink, regression-2576, regression-2302, scope:issue-specific, pwsh-not-required
// #2576: `--from` reads the session upstream's handoff from where the writer puts it
// (<WORKFLOW_STATE_DIR>/<sid>.control/handoff.md, via findHandoffPath), not from a
// <sid>-handoff.md the writer never produces. #2302: an id failing SESSION_ID_VALID_RE
// resolves no artifact at all — unknown-session, exit 3, no path disclosed.

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
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const PLANS_DIR = process.env.WORKFLOW_PLANS_DIR;
const HOME = fs.mkdtempSync(path.join(SCRATCH, "home-"));
const TBASE = fs.mkdtempSync(path.join(SCRATCH, "transcripts-"));
const CLI = path.join(ROOT, "bin", "resume-session-detect");
const APPEND = path.join(ROOT, "bin", "workflow", "handoff-append");

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

// An ACTIVE session upstream, seeded the way T23b seeds its donor.
function seedActive(sid) {
  const io = mod("hooks/workflow-state/state-io");
  io.writeState(sid, io.createInitialState(sid, { cwd: "/fixture/f2576/repo", git_branch: "feature/donor" }));
  io.markStep(sid, "workflow_init", "complete");
  fs.writeFileSync(path.join(PLANS_DIR, `${sid}-intent.md`), "**Title:** handoff donor\n");
  mod("tests/lib/plan-approval-fixture").approveLive(sid, "clarify_intent");
  io.markStep(sid, "clarify_intent", "complete");
}
function seedHeir(sid) {
  const io = mod("hooks/workflow-state/state-io");
  io.writeState(sid, io.createInitialState(sid, { cwd: "/fixture/f2576/repo", git_branch: "feature/donor" }));
}

caseBegin("find-handoff-path-unit", "hooks/lib/handoff-artifact.js");
{
  const HA = mod("hooks/lib/handoff-artifact");
  check("U1: findHandoffPath is exported", () => eq(typeof HA.findHandoffPath, "function", "typeof findHandoffPath"));
  for (const bad of ["../x", "a/b", "a.b", "", "..", null, undefined, 7]) {
    check(`U2: findHandoffPath(${show(bad)}) returns null without throwing`, () => {
      eq(HA.findHandoffPath(bad), null, "findHandoffPath");
    });
  }
  check("U3: a valid sid with no handoff file returns null", () => eq(HA.findHandoffPath("f2576-no-handoff"), null, "findHandoffPath"));
  check("U4: a valid sid whose control-dir handoff exists returns that path", () => {
    const sid = "f2576-has-handoff";
    const want = path.join(STATE_DIR, `${sid}.control`, "handoff.md");
    fs.mkdirSync(path.dirname(want), { recursive: true });
    fs.writeFileSync(want, "# Handoff\n");
    const got = HA.findHandoffPath(sid);
    eq(typeof got === "string" ? path.resolve(got) : got, path.resolve(want), "findHandoffPath");
  });
}
caseEnd();

caseBegin("from-renders-control-dir-handoff", "bin/lib/resume-session/upstream-view.js");
{
  const up = "f2576-t23d-donor";
  const heir = "f2576-t23d-heir";
  const marker = "F2576-T23D-HANDOFF-MARKER";
  seedActive(up);
  seedHeir(heir);
  check("T23d: handoff-append records the entry for the active session upstream", () => {
    const run = spawnNode([APPEND, "--session", up, "--class", "A", "--step", "-", "--key", "t23d",
      "--summary", marker, "--pointer", "-", "--origin", "procedure-point"]);
    eq(run.status, 0, "handoff-append exit (stderr " + show(run.stderr) + ")");
    eq(/WRITTEN=1/.test(run.stdout || ""), true, "WRITTEN=1 in " + show(run.stdout));
  });
  check("T23d: the writer put the handoff in the control dir and no <sid>-handoff.md in the plans dir", () => {
    eq(fs.existsSync(path.join(STATE_DIR, `${up}.control`, "handoff.md")), true, "control-dir handoff exists");
    eq(fs.existsSync(path.join(PLANS_DIR, `${up}-handoff.md`)), false, "plans-dir handoff exists");
  });
  let d = null;
  check("T23d: --from exits 0 and answers on one JSON record", () => {
    const run = spawnNode([CLI, "--from", up], { CLAUDE_CODE_SESSION_ID: heir });
    d = parseOut(run);
    eq(run.status, 0, "--from exit (stderr " + show(run.stderr) + ")");
  });
  check("T23d: handoff_rendered is a string carrying the recorded summary", () => {
    if (!d) return "no record";
    eq(typeof d.handoff_rendered, "string", "typeof handoff_rendered");
    eq(d.handoff_rendered.indexOf(marker) !== -1, true, "marker in handoff_rendered");
  });
  check("T23d: artifacts.handoff points at <sid>.control/handoff.md", () => {
    if (!d) return "no record";
    const h = d.artifacts && d.artifacts.handoff;
    eq(typeof h, "string", "typeof artifacts.handoff (" + show(h) + ")");
    eq(slash(h).endsWith(`${up}.control/handoff.md`), true, "artifacts.handoff suffix (" + show(h) + ")");
  });
}
caseEnd();

caseBegin("from-handoff-only-is-artifacts-only", "bin/lib/resume-session/upstream-view.js");
{
  const up = "f2576-t23f-donor";
  const marker = "F2576-T23F-HANDOFF-MARKER";
  // No state file and no plan artifact: the handoff is the only thing the session upstream left.
  mod("hooks/lib/handoff-artifact").appendHandoffEntry(up, {
    cls: "A", step: "-", key: "t23f", summary: marker, pointer: "-", origin: "procedure-point",
  });
  check("T23f: fixture anchor — only the control-dir handoff exists", () => {
    eq(fs.existsSync(path.join(STATE_DIR, `${up}.control`, "handoff.md")), true, "control-dir handoff exists");
    eq(fs.existsSync(path.join(STATE_DIR, `${up}.json`)), false, "state file exists");
    eq(fs.existsSync(path.join(PLANS_DIR, `${up}-intent.md`)), false, "intent exists");
  });
  check("T23f: a handoff-only session is artifacts-only, exit 0, with artifacts.handoff set and rendered", () => {
    const run = spawnNode([CLI, "--from", up]);
    const d = parseOut(run);
    eq(run.status, 0, "--from exit");
    eq(d.availability, "artifacts-only", "availability");
    eq(typeof (d.artifacts && d.artifacts.handoff), "string", "typeof artifacts.handoff");
    eq(typeof d.handoff_rendered === "string" && d.handoff_rendered.indexOf(marker) !== -1, true, "marker in handoff_rendered");
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
    handoff: path.join(STATE_DIR, `${sid}.control`, "handoff.md"),
  });
  check("A0: ARTIFACT_KINDS is exactly intent/outline/detail/handoff", () => {
    eq(view.ARTIFACT_KINDS, ["intent", "outline", "detail", "handoff"], "ARTIFACT_KINDS");
  });
  for (const bad of ["../x", "a/b", "a.b", "", ".."]) {
    const t = targetsOf(bad);
    for (const k of Object.keys(t)) plant(t[k], k === "handoff" ? "# Handoff\n" : "**Title:** F2576-A1-PLANTED\n");
    check(`A1: buildUpstreamView(${show(bad)}) resolves every kind to null without throwing, traversal targets planted`, () => {
      const v = view.buildUpstreamView({ heirSid: null, upstreamSid: bad });
      const arts = (v && v.artifacts) || {};
      for (const k of view.ARTIFACT_KINDS) if (arts[k] != null) return `artifact ${k} resolved: ${show(arts[k])}`;
      eq(v.availability, "none", "availability");
      return undefined;
    });
  }
  check("A2: a valid sid with intent/outline/detail/handoff present resolves each kind to its own path", () => {
    const sid = "f2576-a2-all-kinds";
    const t = targetsOf(sid);
    for (const k of Object.keys(t)) plant(t[k], k === "handoff" ? "# Handoff\n" : "**Title:** F2576-A2\n");
    const v = view.buildUpstreamView({ heirSid: null, upstreamSid: sid });
    eq(v.availability, "artifacts-only", "availability");
    eq(Object.keys(v.artifacts).sort(), [...view.ARTIFACT_KINDS].sort(), "artifact kinds");
    for (const k of view.ARTIFACT_KINDS) {
      const got = v.artifacts[k];
      eq(typeof got === "string" ? path.resolve(got) : got, path.resolve(t[k]), `artifacts.${k}`);
    }
  });
}
caseEnd();

caseBegin("handoff-directory-is-not-a-handoff", "hooks/lib/handoff-artifact.js");
{
  const HA = mod("hooks/lib/handoff-artifact");
  const view = mod("bin/lib/resume-session/upstream-view");
  const sid = "f2576-c2-handoff-dir";
  const dirAsHandoff = path.join(STATE_DIR, `${sid}.control`, "handoff.md");
  fs.mkdirSync(dirAsHandoff, { recursive: true });
  check("D0: fixture anchor — handoff.md is a directory and no state file exists", () => {
    eq(fs.statSync(dirAsHandoff).isDirectory(), true, "handoff.md is a directory");
    eq(fs.existsSync(path.join(STATE_DIR, `${sid}.json`)), false, "state file exists");
  });
  check("D1: findHandoffPath returns null for a directory named handoff.md", () => eq(HA.findHandoffPath(sid), null, "findHandoffPath"));
  check("D2: readHandoff reports the handoff absent without throwing", () => eq(HA.readHandoff(sid).exists, false, "readHandoff.exists"));
  check("D3: buildUpstreamView does not report the directory as an available handoff", () => {
    const v = view.buildUpstreamView({ heirSid: null, upstreamSid: sid });
    eq(((v && v.artifacts) || {}).handoff == null, true, "artifacts.handoff is null (" + show(v && v.artifacts) + ")");
    eq(v.availability, "none", "availability");
    eq(v.handoff_rendered, null, "handoff_rendered");
  });
}
caseEnd();

// A handoff.md symlink would let the control dir disclose any file it points at, so only
// a regular file (lstat) counts. The regular-file positive control is U4.
caseBegin("handoff-symlink-is-not-a-handoff", "hooks/lib/handoff-artifact.js");
{
  const HA = mod("hooks/lib/handoff-artifact");
  const view = mod("bin/lib/resume-session/upstream-view");
  const sid = "f2576-s-handoff-symlink";
  const marker = "F2576-S-SYMLINK-TARGET-MARKER";
  const target = path.join(SCRATCH, "outside-control", "secret.md");
  const link = path.join(STATE_DIR, `${sid}.control`, "handoff.md");
  // The target is a document the writer itself produced, so following the link WOULD render the marker.
  const donorSid = "f2576-s-symlink-target-src";
  HA.appendHandoffEntry(donorSid, {
    cls: "A", step: "-", key: "s-symlink", summary: marker, pointer: "-", origin: "procedure-point",
  });
  const donorControl = path.join(STATE_DIR, `${donorSid}.control`);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, fs.readFileSync(path.join(donorControl, "handoff.md"), "utf8"));
  fs.rmSync(donorControl, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(link), { recursive: true });
  let linked = false;
  try {
    fs.symlinkSync(target, link, "file");
    linked = true;
  } catch (e) {
    if (!e || (e.code !== "EPERM" && e.code !== "EACCES")) throw e;
    skipped += 5;
    const msg = `SKIP: S0-S3 handoff-symlink cases — symlink creation refused (${e.code}); enable Windows developer mode to run them\n`;
    process.stdout.write(msg);
    process.stderr.write(msg);
  }
  if (linked) {
    check("S0: fixture anchor — handoff.md is a symlink to a writer-produced handoff outside the control dir carrying the marker", () => {
      eq(fs.lstatSync(link).isSymbolicLink(), true, "handoff.md is a symlink");
      eq(fs.existsSync(path.join(STATE_DIR, `${donorSid}.control`)), false, "scratch writer control dir removed");
      eq(path.resolve(fs.realpathSync(link)), path.resolve(fs.realpathSync(target)), "link resolves to the target");
      eq(fs.readFileSync(link, "utf8").indexOf(marker) !== -1, true, "marker readable through the link");
      eq(slash(path.relative(path.dirname(link), target)).startsWith(".."), true, "target is outside the control dir");
      eq(fs.existsSync(path.join(STATE_DIR, `${sid}.json`)), false, "state file exists");
    });
    check("S1: findHandoffPath returns null for a symlinked handoff.md", () => eq(HA.findHandoffPath(sid), null, "findHandoffPath"));
    check("S2: readHandoff does not follow a symlinked handoff.md", () => eq(HA.readHandoff(sid).exists, false, "readHandoff.exists"));
    check("S3: buildUpstreamView reports no handoff and discloses nothing of the link target", () => {
      const v = view.buildUpstreamView({ heirSid: null, upstreamSid: sid });
      eq(JSON.stringify(v).indexOf(marker) === -1, true, "target marker absent from the view");
      eq(((v && v.artifacts) || {}).handoff == null, true, "artifacts.handoff is null (" + show(v && v.artifacts) + ")");
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
      eq(((d && d.artifacts) || {}).handoff == null, true, "artifacts.handoff is null (" + show(d && d.artifacts) + ")");
      eq(d.handoff_rendered == null, true, "handoff_rendered is null (" + show(d.handoff_rendered) + ")");
      return undefined;
    });
  }
}
caseEnd();

process.stdout.write(`Total: ${passed} passed, ${failed} failed, ${skipped} skipped\n`);
if (skipped > 0) process.stderr.write(`WARNING: ${skipped} case(s) skipped — see SKIP lines\n`);
process.exitCode = failed === 0 ? 0 : 1;
