"use strict";
// Fixture of tests/hooks/feature-3019-pm-instructions.js (#3019). No case markers.
// A world is its own pinned state/plans pair: the PM owner lookup scans every state file, so worlds never
// share one. Every child (probe, CLI, hook) runs from one fixture repo (origin github.com/o/r) with the
// #2941 fake gh first on PATH, no session id, an empty transcript base and a temp HOME. The PM owner of an
// issue is the fake gh map's PM field value (W.field), read by `bin/pm-state owner` (#2942).
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { gitInit } = require("../../lib/harness");
const P = require("../../lib/pm-state-fixture");

const ROOT = P.ROOT;
const FAKE_GH = path.join(ROOT, "tests", "bin", "feature-2941-pm-state-cli", "fake-gh.js");
const SSOT_MD = path.join(ROOT, "skills", "_shared", "pm-supervisor-duties.md");
const CLI = path.join(ROOT, "bin", "pm-instructions");
const PROBE = path.join(__dirname, "probe.js");
// The test seam the library must honor: an absolute path that replaces the SSOT md (assumption, see report).
const MD_ENV = "PM_INSTRUCTIONS_MD_PATH";
const MAX_BYTES = 8192;
// The heading contract from the detail plan's SSOT md section-structure table, written here independently of sections.js.
const CONTRACT = [
  { h2: "PM session", h3: "Session start", recipient: "pm", timing: "session-start" },
  { h2: "PML2 delta", h3: "Session start", recipient: "pml2", timing: "session-start" },
  { h2: "Workflow session", h3: "Issue start", recipient: "workflow", timing: "issue-start" },
  { h2: "Workflow session", h3: "Before companion presentation", recipient: "workflow", timing: "before-companions" },
  { h2: "Workflow session", h3: "Before plan confirmation sentinel", recipient: "workflow", timing: "before-plan-confirm" },
  { h2: "Workflow session", h3: "Before user verification", recipient: "workflow", timing: "before-user-verification" },
  { h2: "Workflow session", h3: "After Final Report", recipient: "workflow", timing: "after-final-report" },
];
const TIMING_KEYS = ["session-start", "issue-start", "before-companions", "before-plan-confirm", "before-user-verification", "after-final-report"];
// #3144 replaced the [interim: #2991] lines with the Review request mechanism.
const INTERIM_ISSUES = [2943, 2944, 3056, 3057, 3118];
const mark = (c) => `BODY-${c.recipient}-${c.timing}`;
const byKey = (recipient, timing) => CONTRACT.find((c) => c.recipient === recipient && c.timing === timing);
// The session-start bundles: pm -> its one section; workflow -> issue-start only (#3144: the two review
// timings are fetched through --timing at their checkpoint).
const BUNDLE = {
  pm: [byKey("pm", "session-start")],
  workflow: [byKey("workflow", "issue-start")],
};

// fixtureMd({drop, body}) -> an SSOT-shaped md whose every section carries its own BODY marker line;
// drop {h2, h3?} leaves that heading out; body {h2, h3, text} replaces one section's text.
function fixtureMd(o = {}) {
  const out = ["# PM supervisor duties (fixture)", "", "<!-- BODY-in-a-comment must never be injected -->", ""];
  let h2 = null;
  for (const c of CONTRACT) {
    const dropH2 = o.drop && o.drop.h2 === c.h2 && !o.drop.h3;
    if (c.h2 !== h2) { h2 = c.h2; if (!dropH2) out.push(`## ${c.h2}`, ""); }
    if (dropH2 || (o.drop && o.drop.h2 === c.h2 && o.drop.h3 === c.h3)) continue;
    const text = o.body && o.body.h2 === c.h2 && o.body.h3 === c.h3 ? o.body.text : `- ${mark(c)} directive line.`;
    out.push(`### ${c.h3}`, "", text, "");
  }
  return out.join("\n");
}

// headingPairs(text) -> {h2: Map<name, count>, pairs: Map<"h2/h3", count>} of the comment-free text.
function headingPairs(text) {
  const clean = text.replace(/<!--[\s\S]*?-->/g, "").replace(/<!--[\s\S]*$/, "");
  const h2 = new Map();
  const pairs = new Map();
  let cur = null;
  for (const line of clean.split(/\r?\n/)) {
    let m = /^## (.+?)\s*$/.exec(line);
    if (m) { cur = m[1]; h2.set(cur, (h2.get(cur) || 0) + 1); continue; }
    m = /^### (.+?)\s*$/.exec(line);
    if (m && cur) pairs.set(`${cur}/${m[1]}`, (pairs.get(`${cur}/${m[1]}`) || 0) + 1);
  }
  return { h2, pairs };
}

function makeShared(tmp) {
  const S = { tmp, repo: path.join(tmp, "repo"), ghBin: path.join(tmp, "gh-bin"), home: path.join(tmp, "home"), cfg: path.join(tmp, "cfg"), transcripts: path.join(tmp, "transcripts"), mdDir: path.join(tmp, "md") };
  for (const d of [S.repo, S.ghBin, S.home, S.cfg, S.transcripts, S.mdDir]) fs.mkdirSync(d, { recursive: true });
  gitInit(S.repo);
  const g = cp.spawnSync("git", ["-C", S.repo, "remote", "add", "origin", "https://github.com/o/r.git"], { encoding: "utf8", timeout: 30000 });
  if (g.status !== 0) throw new Error(`git remote add: ${g.stderr}`);
  fs.writeFileSync(path.join(S.ghBin, "gh"), `#!/bin/bash\nexec node '${P.fwd(FAKE_GH)}' "$@"\n`, { mode: 0o755 });
  // md(name, text) -> the absolute path of a fixture md (text null -> a path that does not exist).
  S.md = (name, text) => {
    const f = path.join(S.mdDir, `${name}.md`);
    if (text !== null) fs.writeFileSync(f, text);
    return f;
  };
  return S;
}

const PINS = ["WORKFLOW_STATE_DIR", "WORKFLOW_PLANS_DIR"];

function makeWorld(S, name) {
  const dir = path.join(S.tmp, `world-${name}`);
  const W = { dir, state: path.join(dir, "state"), plans: path.join(dir, "plans"), log: path.join(dir, "gh.log"), map: path.join(dir, "gh-map.json") };
  for (const d of [W.state, W.plans]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(W.log, "");
  fs.writeFileSync(W.map, "{}");
  // within(fn) — runs fn with this world's pins in process.env (the seeders resolve their paths from it).
  W.within = (fn) => {
    const saved = PINS.map((k) => process.env[k]);
    process.env.WORKFLOW_STATE_DIR = W.state;
    process.env.WORKFLOW_PLANS_DIR = W.plans;
    try { return fn(); } finally { PINS.forEach((k, i) => { if (saved[i] === undefined) delete process.env[k]; else process.env[k] = saved[i]; }); }
  };
  W.pm = (sid, value) => W.within(() => P.seedPm(sid, value));
  W.plain = (sid) => W.within(() => P.seedState(sid, { wfInit: "complete" }));
  W.intent = (sid, refs) => W.within(() => {
    const f = require(path.join(ROOT, "hooks", "lib", "plans-artifact-registry.js")).getPlansArtifactPath(sid, "intent");
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, `# Intent\n\n## Issues\n\n${refs.map((r) => `- ${r}: fixture issue`).join("\n")}\n\n## Background\n\nfixture\n`);
  });
  W.progress = (sid, factLine) => W.within(() => {
    const f = require(path.join(ROOT, "hooks", "lib", "progress-file.js")).progressPathFor(sid);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, `# Session progress\n\n## Current state\n\nfixture\n\n## Facts to carry over\n\n### User decisions\n\n- ${factLine}\n`);
  });
  W.setMap = (m) => fs.writeFileSync(W.map, JSON.stringify(m));
  // field({"o/r#N": tag|null}) -> sets the Projects v2 PM field of those issues in the fake gh map (#2942: the
  // owner is read from this field, never from the PM state's issue list); other map keys of an entry are kept.
  W.field = (values) => {
    const m = JSON.parse(fs.readFileSync(W.map, "utf8"));
    for (const [k, tag] of Object.entries(values)) m[k] = Object.assign({}, m[k], { pm: tag });
    W.setMap(m);
  };
  W.ghCalls = () => fs.readFileSync(W.log, "utf8").split("\n").filter(Boolean).length;
  W.ghLog = () => fs.readFileSync(W.log, "utf8");
  // env(extra) -> the child env; an extra value of null removes that key.
  W.env = (extra = {}) => {
    const e = Object.assign({}, process.env, {
      WORKFLOW_STATE_DIR: W.state, WORKFLOW_PLANS_DIR: W.plans, CLAUDE_TRANSCRIPT_BASE_DIR: S.transcripts,
      HOME: S.home, USERPROFILE: S.home, AGENTS_MAIN_ROOT: S.cfg, CLAUDE_PROJECT_DIR: S.repo,
      PM_FAKE_GH_LOG: W.log, PM_FAKE_GH_MAP: W.map,
    });
    for (const k of ["CLAUDE_CODE_SESSION_ID", MD_ENV, "PM_FAKE_GH_SLEEP_MS", "PM_FAKE_GH_MODE", "PM_FAKE_GH_SIDE", "PM_FAKE_GH_PM_STORE"]) delete e[k];
    for (const [k, v] of Object.entries(extra)) { if (v === null) delete e[k]; else e[k] = String(v); }
    const pathKey = Object.keys(e).find((k) => k.toUpperCase() === "PATH") || "PATH";
    e[pathKey] = `${S.ghBin}${path.delimiter}${e[pathKey] || ""}`;
    return e;
  };
  const spawn = (argv, extra, input) => {
    const before = W.ghCalls();
    const t0 = Date.now();
    const r = cp.spawnSync(process.execPath, argv, { cwd: S.repo, env: W.env(extra), input: input || "", encoding: "utf8", timeout: 90000 });
    return { code: r.status, out: r.stdout || "", err: `${r.stderr || ""}${r.error ? String(r.error) : ""}`, ms: Date.now() - t0, calls: W.ghCalls() - before };
  };
  // probe(req, extra) -> {code, out, err, ms, calls, value}: one getPmInstructionsInjection call in a child
  // (./probe.js); a non-zero exit (the module missing, an uncaught throw) is thrown with its stderr.
  W.probe = (req, extra) => {
    const r = spawn([PROBE, JSON.stringify(req)], extra);
    if (r.code !== 0) {
      const lines = r.err.split("\n");
      const why = lines.find((l) => /^\w*Error\b|Cannot find module/.test(l.trim())) || lines.slice(0, 4).join(" | ");
      throw new Error(`probe exit=${r.code}: ${why.trim()}`);
    }
    const j = JSON.parse(r.out);
    return Object.assign(r, { value: j.out, innerMs: j.ms });
  };
  // cli(args, extra) -> bin/pm-instructions; throws while the CLI does not exist (an exit 1 must not pass by accident).
  W.cli = (args, extra) => {
    if (!fs.existsSync(CLI)) throw new Error("bin/pm-instructions does not exist");
    return spawn([CLI, ...args], extra);
  };
  W.pmState = (args) => {
    const r = spawn([path.join(ROOT, "bin", "pm-state"), ...args]);
    if (r.code !== 0) throw new Error(`pm-state ${args.join(" ")} exit=${r.code}: ${r.err}`);
    return JSON.parse(r.out.trim());
  };
  // hook(file, sid, event, extra, over) -> {code, err, ctx}: the hook's additionalContext ("" when absent);
  // over (optional) replaces hook input fields, e.g. {source: "startup"}.
  W.hook = (file, sid, event, extra, over) => {
    const base = { session_id: sid, hook_event_name: event, source: event === "SessionStart" ? "resume" : undefined, cwd: S.repo, transcript_path: path.join(S.transcripts, `${sid}.jsonl`) };
    const input = JSON.stringify(Object.assign(base, over));
    const r = spawn([path.join(ROOT, "hooks", file)], extra, input);
    let ctx = "";
    try { const j = JSON.parse(r.out.trim() || "{}"); const h = j.hookSpecificOutput || j; ctx = typeof h.additionalContext === "string" ? h.additionalContext : ""; } catch (_) { ctx = ""; }
    return Object.assign(r, { ctx });
  };
  return W;
}

const brief = (r) => `code=${r.code} value=${JSON.stringify(r.value === undefined ? r.out : r.value).slice(0, 600)} err=${String(r.err).slice(0, 300)}`;
const firstLine = (s) => String(s).split("\n")[0];

module.exports = {
  ROOT, SSOT_MD, CLI, MD_ENV, MAX_BYTES, CONTRACT, TIMING_KEYS, INTERIM_ISSUES, BUNDLE, mark, byKey,
  fixtureMd, headingPairs, makeShared, makeWorld, brief, firstLine, P,
};
