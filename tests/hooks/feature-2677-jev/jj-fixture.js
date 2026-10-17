"use strict";
// Test-only scaffolding for the feature-2677-jev-*.js tests (#2677): the mock Jev server of
// feature-2460-jev-shadow, per-case fixtures (both workflow dirs, state dir, decoy main root,
// git-init'd project dir, neutral cwd), the jev-judge CLI runner and the skip-probe module-API
// query, the decision-log reader. Everything is synchronous so a case reads top to bottom.
// Holds no cases of its own.

const { spawn, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { gitInit } = require("../../lib/harness");

const REPO = path.resolve(__dirname, "..", "..", "..");
const MOCK_JS = path.join(REPO, "tests", "hooks", "feature-2460-jev-shadow", "mock-jev-server.js");
const SKIP_PROBE = path.join(REPO, "tests", "bin", "feature-2460-jev-judge", "skip-probe.js");
const JUDGE = path.join(REPO, "bin", "workflow", "jev-judge");
const SENTINEL_KEY = "jev-test-sentinel-key-2460";
const SID = "11111111-2222-4333-8444-555555555555";
const DROPPED = ["CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "JEV", "TYPESAFE_API_KEY", "JEV_BASE_URL",
  "JEV_HTTP_TIMEOUT_MS", "JEV_PENDING_TTL_MS", "NODE_OPTIONS"];
const CHILD_TIMEOUT_MS = 60000;

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// startMock(dir) -> {url, mode(obj), probs(defaultP, {key: p}), count(route), stop()}.
function startMock(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const portFile = path.join(dir, "port");
  const modeFile = path.join(dir, "mode.json");
  const reqLog = path.join(dir, "requests.jsonl");
  fs.writeFileSync(modeFile, "{}");
  fs.writeFileSync(reqLog, "");
  const child = spawn(process.execPath, [MOCK_JS, portFile, modeFile, reqLog], { stdio: "ignore" });
  const stop = () => { try { child.kill(); } catch (_e) { /* already gone */ } };
  process.on("exit", stop);
  for (let i = 0; i < 200 && !(fs.existsSync(portFile) && fs.readFileSync(portFile, "utf8").trim()); i++) sleepMs(50);
  const port = fs.existsSync(portFile) ? fs.readFileSync(portFile, "utf8").trim() : "";
  if (!port) { stop(); throw new Error("mock Jev server did not start"); }
  const mode = (obj) => { fs.writeFileSync(modeFile, JSON.stringify(obj)); fs.writeFileSync(reqLog, ""); };
  // Echo mode; each key is set under both spellings (S2-architecture and s2_architecture).
  const probs = (defaultP, keyProbs) => {
    const kp = {};
    for (const [k, p] of Object.entries(keyProbs || {})) { kp[k] = p; kp[k.toLowerCase().replace(/-/g, "_")] = p; }
    mode({ echo: true, defaultP, keyProbs: kp });
  };
  const count = (route) => fs.readFileSync(reqLog, "utf8").split("\n").filter(Boolean)
    .map((l) => JSON.parse(l)).filter((r) => r.path === `/v1/${route}`).length;
  return { url: `http://127.0.0.1:${port}`, mode, probs, count, stop };
}

// newFx(root, name, files) -> fixture. files: {outline, detail, writeCode} (true = default text,
// a string = that text, absent = no file). intent and context.md are always written.
function newFx(root, name, files = {}) {
  const fx = path.join(root, `fx-${name}`);
  for (const d of ["state", "wf", "plans", "cfg", "cwd", "transcripts"]) fs.mkdirSync(path.join(fx, d), { recursive: true });
  gitInit(path.join(fx, "proj"));
  const plans = path.join(fx, "plans");
  const put = (n, text) => fs.writeFileSync(path.join(plans, `${SID}-${n}`), text);
  put("intent.md", "# Intent\n\nAdd a --json flag to the report command; no other change.\n");
  put("context.md", "# Context\n\n## Issue body\n\nShort issue body: add a flag to the report CLI.\n");
  const text = (v, dflt) => (typeof v === "string" ? v : dflt);
  if (files.outline) put("outline.md", text(files.outline, "# Outline\n\nSingle approach: add the flag in report.js; no open decision.\n"));
  if (files.detail) put("detail.md", text(files.detail, "# Detail\n\nAdd the --json flag in report.js and print JSON.\n"));
  if (files.writeCode) put("write-code-files.txt", text(files.writeCode, "bin/report\n"));
  if (files.stateJson) fs.writeFileSync(path.join(fx, "wf", `${SID}.json`), files.stateJson);
  return {
    dir: fx, plans, wf: path.join(fx, "wf"), cwd: path.join(fx, "cwd"),
    log: path.join(fx, "state", "logs", "jev-decisions.log"),
    pins: {
      AGENTS_STATE_DIR: path.join(fx, "state"), WORKFLOW_STATE_DIR: path.join(fx, "wf"), WORKFLOW_PLANS_DIR: plans,
      AGENTS_MAIN_ROOT: path.join(fx, "cfg"), CLAUDE_PROJECT_DIR: path.join(fx, "proj"),
      CLAUDE_TRANSCRIPT_BASE_DIR: path.join(fx, "transcripts"),
    },
  };
}

function childEnv(fx, mock, extra = {}) {
  const env = Object.assign({}, process.env);
  for (const n of DROPPED) delete env[n];
  Object.assign(env, fx.pins, { JEV: "on", TYPESAFE_API_KEY: SENTINEL_KEY, JEV_BASE_URL: mock.url });
  for (const [k, v] of Object.entries(extra)) {
    if (v === null) delete env[k];
    else env[k] = v;
  }
  return env;
}

// The stdout of one child as {status, stdout, lines, kv(KEY) ("<none>" when absent), all(KEY)}.
function outcome(r) {
  const stdout = String(r.stdout || "").replace(/\r/g, "");
  const lines = stdout.split("\n").filter((l) => l !== "");
  const all = (k) => lines.filter((l) => l.startsWith(`${k}=`)).map((l) => l.slice(k.length + 1));
  const kv = (k) => { const v = all(k); return v.length ? v[0] : "<none>"; };
  return { status: r.status, stdout, stderr: String(r.stderr || ""), lines, kv, all };
}

// jj(fx, mock, args, extraEnv): the jev-judge CLI from the neutral cwd.
function jj(fx, mock, args, extra) {
  return outcome(spawnSync(process.execPath, [JUDGE, ...args], {
    cwd: fx.cwd, env: childEnv(fx, mock, extra), encoding: "utf8", timeout: CHILD_TIMEOUT_MS, input: "",
  }));
}
const cxQuery = (fx, mock, stage, extra) => jj(fx, mock, ["query", "--session", SID, "--point", "complexity-judge", "--stage", stage], extra);
const finalize = (fx, mock, ticket, extra) => jj(fx, mock, ["finalize", "--session", SID, "--ticket", ticket], extra);

// skipQuery(fx, mock, target): <target>-skip at stage outline through the module API (skip-probe).
function skipQuery(fx, mock, target, extra) {
  const o = { sid: SID, point: `${target}-skip`, stage: "outline", entry: { mode: "production" } };
  return outcome(spawnSync(process.execPath, [SKIP_PROBE, REPO, "query", JSON.stringify(o)], {
    cwd: fx.cwd, env: childEnv(fx, mock, extra), encoding: "utf8", timeout: CHILD_TIMEOUT_MS, input: "",
  }));
}

// decision(fx, ticket): the ticket's decision record (null when none); records(fx, ticket): all.
function records(fx, ticket) {
  if (!fs.existsSync(fx.log)) return [];
  return fs.readFileSync(fx.log, "utf8").split("\n").filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch (_e) { return null; } })
    .filter((x) => x && x.ticket === ticket);
}
const decision = (fx, ticket) => records(fx, ticket).find((x) => x.record_type === "decision") || null;

// keyset("S2-architecture,s5_breaking") -> "s2_architecture,s5_breaking" (spelling-neutral).
const keyset = (csv) => String(csv).split(",").map((s) => s.trim().toLowerCase().replace(/-/g, "_"))
  .filter((s) => s !== "" && s !== "-").sort().join(",");

// withPins(fx, fn): process.env pointed at the fixture's dirs while fn runs (in-process guards).
function withPins(fx, fn) {
  const saved = {};
  for (const k of Object.keys(fx.pins)) { saved[k] = process.env[k]; process.env[k] = fx.pins[k]; }
  try { return fn(); } finally {
    for (const k of Object.keys(saved)) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
  }
}

// Legacy workflow state at detail (feature-1286 shape): research and outline done, detail pending.
const STATE_AT_DETAIL = JSON.stringify({ steps: Object.fromEntries([
  ["workflow_init", "complete"], ["clarify_intent", "complete"], ["research", "complete"], ["outline", "complete"],
  ["detail", "pending"], ["branching_complete", "pending"], ["write_tests", "pending"], ["review_tests", "pending"],
  ["run_tests", "pending"], ["review_security", "pending"], ["docs", "pending"], ["user_verification", "pending"],
  ["cleanup", "pending"], ["pre_final_report_gate", "pending"],
].map(([k, s]) => [k, { status: s }])) });

module.exports = {
  REPO, SID, SENTINEL_KEY, STATE_AT_DETAIL, sleepMs, startMock, newFx, jj, cxQuery, finalize, skipQuery,
  records, decision, keyset, withPins,
};
