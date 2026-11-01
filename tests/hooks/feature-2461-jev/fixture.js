"use strict";
// Test-only scaffolding for the feature-2461-*.js and feature-2764-*.js tests (#2461, #2764):
// one scene per case (both workflow pins, the Jev state dir, an empty decoy main root, a
// git-init'd project dir, an empty transcript base and a neutral cwd), the child-process env,
// the workflow seeders, the prompt-turn writer (through the real UserPromptSubmit hook), the
// decision-log and spawn-spy readers, and the mock Jev server of feature-2460-jev-shadow.
// Everything is synchronous so a case reads top to bottom. Holds no cases of its own.

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("../../lib/harness");
const J = require("../feature-2677-jev/jj-fixture");
const S = require("../feature-2698-supervisor/fixture");

const REPO = J.REPO;
const fwd = (p) => String(p).replace(/\\/g, "/");
const lib = (rel) => fwd(path.join(REPO, rel));
const SPY = fwd(path.join(__dirname, "spawn-spy.js"));
const NEXT_STEP = path.join(REPO, "bin", "workflow", "next-step");
const CHILD_TIMEOUT_MS = 60000;

const newSid = () => crypto.randomUUID();

// scene(root, name) -> {dir, wf, plans, state, cfg, claudeCfg, cwd, proj, io, transcripts, log, oldLog, spyLog}.
// claudeCfg is the scene's CLAUDE_CONFIG_DIR: transcripts live under its projects/ (the trusted root).
function scene(root, name) {
  const d = path.join(root, name);
  const sub = (s) => path.join(d, s);
  for (const s of ["wf", "plans", "state", "cfg", "claude-config", "cwd", "io", "transcripts-empty"]) fs.mkdirSync(sub(s), { recursive: true });
  gitInit(sub("proj"));
  return {
    dir: d, wf: sub("wf"), plans: sub("plans"), state: sub("state"), cfg: sub("cfg"), claudeCfg: sub("claude-config"), cwd: sub("cwd"),
    proj: sub("proj"), io: sub("io"), transcripts: sub("transcripts-empty"),
    log: path.join(sub("state"), "logs", "jev-decisions.jsonl"),
    oldLog: path.join(sub("state"), "logs", "jev-decisions.log"),
    spyLog: path.join(sub("io"), "spy.jsonl"),
  };
}

// envOf(sc, mock, extra) — every child's env: pins, no inherited session / Jev / preload, Jev on
// against the mock with the sentinel key. An extra value of null deletes that variable.
function envOf(sc, mock, extra = {}) {
  const env = Object.assign({}, process.env);
  for (const k of Object.keys(env)) {
    if (/^(JEV|CONFIRM_|ENFORCE_|AUTO_MERGE_)/.test(k)) delete env[k];
  }
  for (const k of ["CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "TYPESAFE_API_KEY", "NODE_OPTIONS", "SPY_LOG", "FAKE_NEXT_STEP"]) delete env[k];
  Object.assign(env, {
    AGENTS_STATE_DIR: sc.state, WORKFLOW_STATE_DIR: sc.wf, WORKFLOW_PLANS_DIR: sc.plans,
    AGENTS_MAIN_ROOT: sc.cfg, CLAUDE_PROJECT_DIR: sc.proj, CLAUDE_TRANSCRIPT_BASE_DIR: sc.transcripts, CLAUDE_CONFIG_DIR: sc.claudeCfg,
    CONV_LANG: "english", ENFORCE_WORKFLOW: "on", ENFORCE_WORKTREE: "on",
    JEV: "on", TYPESAFE_API_KEY: J.SENTINEL_KEY,
  });
  if (mock) env.JEV_BASE_URL = mock.url;
  for (const [k, v] of Object.entries(extra || {})) {
    if (v === null) delete env[k];
    else env[k] = v;
  }
  return env;
}

// spyEnv(sc) — the extra env that loads the spawn spy into the child and all its node children.
const spyEnv = (sc) => ({ NODE_OPTIONS: `--require "${SPY}"`, SPY_LOG: fwd(sc.spyLog) });
// fakeNextStepEnv(mode) — the extra env that swaps the next-step process for fake-next-step.js's mode.
const FAKE_NS = fwd(path.join(__dirname, "fake-next-step.js"));
const fakeNextStepEnv = (mode) => ({ NODE_OPTIONS: `--require "${FAKE_NS}"`, FAKE_NEXT_STEP: mode });

// outcome(r) -> {status, stdout, stderr, lines, kv(KEY), json (last JSON line or null), ms}.
function outcome(r, ms) {
  const stdout = String(r.stdout || "").replace(/\r/g, "");
  const lines = stdout.split("\n").filter((l) => l !== "");
  const all = (k) => lines.filter((l) => l.startsWith(`${k}=`)).map((l) => l.slice(k.length + 1));
  const kv = (k) => { const v = all(k); return v.length ? v[0] : "<none>"; };
  let json = null;
  for (let i = lines.length - 1; i >= 0 && json === null; i--) {
    try { const o = JSON.parse(lines[i]); if (o && typeof o === "object") json = o; } catch (_e) { /* not JSON */ }
  }
  return { status: r.status, stdout, stderr: String(r.stderr || ""), lines, kv, all, json, ms };
}

// run(sc, mock, argv, {input, extra, timeout}) — node <argv> from the neutral cwd.
function run(sc, mock, argv, opts = {}) {
  const t0 = Date.now();
  const r = spawnSync(process.execPath, argv, {
    cwd: sc.cwd, env: envOf(sc, mock, opts.extra), encoding: "utf8",
    timeout: opts.timeout || CHILD_TIMEOUT_MS, input: opts.input === undefined ? "" : opts.input,
  });
  return outcome(r, Date.now() - t0);
}

// nodeEval(sc, mock, code, args, extra) — `node -e code`; args land at process.argv[2..].
const nodeEval = (sc, mock, code, args = [], extra) => run(sc, mock, ["-e", code, "--", "eval", ...args], { extra });

// mustEval(...) — nodeEval that throws with stderr when the child fails (seeding only).
function mustEval(sc, code, args) {
  const r = nodeEval(sc, null, code, args, { JEV: "off" });
  if (r.status !== 0) throw new Error(`fixture child failed (${r.status}): ${r.stderr}`);
  return r;
}

const runHook = (sc, mock, rel, input, extra) => run(sc, mock, [path.join(REPO, rel)], { input: JSON.stringify(input), extra });
const nextStep = (sc, mock, sid, args = [], extra) => run(sc, mock, [NEXT_STEP, "--session", sid, ...args], { extra });

// seedStarted(sc, sid) — workflow_init and clarify_intent complete (approved, glossary_check
// recorded): next-step's current step is research and ACTION=invoke (feature-2698 shape).
function seedStarted(sc, sid) {
  const repo = path.join(sc.dir, "glossary-repo");
  if (!fs.existsSync(path.join(repo, ".git"))) gitInit(repo);
  mustEval(sc, `
const wf = require(${JSON.stringify(lib("hooks/workflow-state/state-io.js"))});
const sid = process.argv[2];
wf.markStep(sid, "workflow_init", "complete");
require(${JSON.stringify(lib("tests/lib/plan-approval-fixture.js"))}).approveLive(sid, "clarify_intent");
require(${JSON.stringify(lib("tests/lib/glossary-check-record.js"))})
  .completeWithRecord(sid, "clarify_intent", process.argv[3], wf.markStep);`, [sid, fwd(repo)]);
}

// markSteps(sc, sid, [[step, status], ...]) — real markStep calls, in order.
function markSteps(sc, sid, pairs) {
  mustEval(sc, `
const wf = require(${JSON.stringify(lib("hooks/workflow-state/state-io.js"))});
for (const [s, st] of JSON.parse(process.argv[3])) wf.markStep(process.argv[2], s, st);`, [sid, JSON.stringify(pairs)]);
}

// writeTranscript(sc, name, entries) -> its forward-slash path, <claudeCfg>/projects/fixture-proj/<name>.jsonl.
const transcriptDir = (sc) => path.join(sc.claudeCfg, "projects", "fixture-proj");
function writeTranscript(sc, name, entries) {
  fs.mkdirSync(transcriptDir(sc), { recursive: true });
  const p = path.join(transcriptDir(sc), `${name}.jsonl`);
  fs.writeFileSync(p, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  return fwd(p);
}

const controlFile = (sc, sid, name) => path.join(sc.wf, `${sid}.control`, name);
const readJson = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch (_e) { return null; } };
// writeControl(sc, sid, name, text) — a raw control file (malformed / old-format cases).
function writeControl(sc, sid, name, text) {
  fs.mkdirSync(path.dirname(controlFile(sc, sid, name)), { recursive: true });
  fs.writeFileSync(controlFile(sc, sid, name), text);
}

// promptTurn(sc, sid, transcriptPath) — one user prompt through the real UserPromptSubmit hook;
// returns the prompt-turn.json it left (null when none).
function promptTurn(sc, sid, transcriptPath) {
  const input = { session_id: sid, hook_event_name: "UserPromptSubmit", prompt: "go on", cwd: fwd(sc.cwd) };
  if (transcriptPath !== undefined) input.transcript_path = transcriptPath;
  runHook(sc, null, "hooks/user-prompt-submit-turn-id.js", input, { JEV: "off" });
  return readJson(controlFile(sc, sid, "prompt-turn.json"));
}

// records(sc, logPath) -> the parsed decision-log lines (unparsable lines dropped).
function records(sc, logPath) {
  const p = logPath || sc.log;
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, "utf8").split("\n").filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch (_e) { return null; } }).filter(Boolean);
}

// spyCalls(sc) -> every spied call; calledScript(sc, suffix) -> the calls that ran that script.
function spyCalls(sc) {
  if (!fs.existsSync(sc.spyLog)) return [];
  return fs.readFileSync(sc.spyLog, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
}
const calledScript = (sc, suffix) => spyCalls(sc).filter((c) => [c.file, ...c.args].some((a) => fwd(a).endsWith(suffix)));

// startMock(dir) — J.startMock plus conv(defaultP, keyProbs, more) (echo mode, every key under
// both spellings, request bodies captured) and requests() (the logged systemone requests).
function startMock(dir) {
  const m = J.startMock(dir);
  const reqLog = path.join(dir, "requests.jsonl");
  m.conv = (defaultP, keyProbs = {}, more = {}) => {
    const kp = {};
    for (const [k, p] of Object.entries(keyProbs)) { kp[k] = p; kp[k.replace(/-/g, "_")] = p; }
    m.mode(Object.assign({ echo: true, capture: true, defaultP, keyProbs: kp }, more));
  };
  m.requests = () => fs.readFileSync(reqLog, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l))
    .filter((r) => r.path === "/v1/systemone");
  return m;
}

module.exports = {
  REPO, SENTINEL_KEY: J.SENTINEL_KEY, fwd, lib, newSid, scene, envOf, spyEnv, fakeNextStepEnv, run, nodeEval, runHook, nextStep,
  seedStarted, markSteps, transcriptDir, writeTranscript, controlFile, readJson, writeControl, promptTurn, records,
  spyCalls, calledScript, startMock, sleepMs: J.sleepMs, U: S.U, R: S.R, A: S.A, T: S.T, TU: S.TU,
};
