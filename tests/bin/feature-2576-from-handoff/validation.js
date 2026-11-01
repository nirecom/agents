"use strict";
// Session-id validation cases of feature-2576-from-handoff.js (#2302): a malformed id resolves
// nothing, even when a real file sits at the exact path it would join to.

const path = require("path");
const fs = require("fs");
const { mod, fx, STATE_DIR, PLANS_DIR, TBASE, CLI, check, show, eq, slash, spawnNode, parseOut, plant } = require("./common");

function invalidSidIsUnknownSession() {
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

function entryValidation() {
  // Seed, at the exact path each malformed id would join to, every store a lookup reads:
  // state file, handoff (control dir and plans dir), session-progress.md and a transcript.
  // Any of them surfacing in the view means a lookup ran past the entry check.
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = TBASE;
  const view = mod("bin/lib/resume-session/upstream-view");
  const SENT = "F2576-C3-LEAK";
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

// artifactsFor is module-private, so each kind's resolver is probed through buildUpstreamView.
function artifactsPerKind() {
  const view = mod("bin/lib/resume-session/upstream-view");
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

module.exports = { invalidSidIsUnknownSession, entryValidation, artifactsPerKind };
