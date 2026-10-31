"use strict";
// Fixture surface of tests/hooks/feat-user-prompt-submit-issue-title.js (#299). No case markers.
// makeFixtures(tmp) neutralizes the environment (empty global .env, no GitLab host, empty transcript
// base, cwd in a fixture dir) and returns the helpers every case file uses; F.restoreEnv undoes it.
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");

const ENV_KEYS = ["AGENTS_MAIN_ROOT", "CLAUDE_PROJECT_DIR", "GITLAB_HOSTNAME", "GITLAB_SSH_HOSTNAME", "CLAUDE_TRANSCRIPT_BASE_DIR"];

function makeFixtures(tmp) {
  const ROOT = path.resolve(__dirname, "..", "..", "..");
  const ENTRY = path.join(ROOT, "hooks", "user-prompt-submit-issue-title.js");
  const WS = require(path.join(ROOT, "hooks", "workflow-state.js"));
  const { localEnvPathFor } = require(path.join(ROOT, "hooks", "lib", "local-env.js"));
  const T0 = Date.UTC(2026, 9, 31, 12, 0, 0);
  const MIN = 60 * 1000;

  const savedEnv = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
  const savedCwd = process.cwd();
  const neutral = path.join(tmp, "neutral");
  for (const d of [neutral, path.join(tmp, "agents-stub"), path.join(tmp, "transcripts")]) fs.mkdirSync(d);
  fs.writeFileSync(path.join(tmp, "agents-stub", ".env"), "");
  for (const k of ENV_KEYS) delete process.env[k];
  process.env.AGENTS_MAIN_ROOT = path.join(tmp, "agents-stub");
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(tmp, "transcripts");
  process.chdir(neutral);
  const restoreEnv = () => {
    process.chdir(savedCwd);
    for (const k of ENV_KEYS) { if (savedEnv[k] === undefined) delete process.env[k]; else process.env[k] = savedEnv[k]; }
  };

  let n = 0;
  const newSid = (tag) => `it-${tag}-${process.pid}-${++n}`;
  const wrapped = (name, args) => `<command-message>${name}</command-message>\n<command-name>/${name}</command-name>\n<command-args>${args}</command-args>`;
  const input = (sid, prompt, cwd = neutral) => ({ session_id: sid, hook_event_name: "UserPromptSubmit", prompt, cwd });
  const recordPath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.control`, "issue-title.json");
  const readRecord = (sid) => { try { return JSON.parse(fs.readFileSync(recordPath(sid), "utf8")); } catch (_) { return null; } };

  // seed(sid, {transcript, status, first}) — a state as SessionStart (transcript string) or a late
  // markStep path (transcript null) would leave it; `first` adds first_session_id to the raw file.
  function seed(sid, o = {}) {
    WS.writeState(sid, WS.createInitialState(sid, { cwd: neutral, git_branch: null, transcript_path: o.transcript === undefined ? "/fixture/t.jsonl" : o.transcript }));
    if (o.first) {
      const p = WS.getStatePath(sid);
      const raw = JSON.parse(fs.readFileSync(p, "utf8"));
      raw.first_session_id = o.first;
      fs.writeFileSync(p, JSON.stringify(raw));
    }
    if (o.status) WS.markStep(sid, "workflow_init", o.status);
  }
  const writeIntent = (sid, lines) => fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-intent.md`), `**Title:** fixture\n\n## Issues\n${lines.join("\n")}\n`);

  // deps(titles, at) — fetchTitle answers titles["<repo>#<N>"] (a function value is called;
  // undefined -> "Title<N>"); spawnSync records and fails.
  function deps(titles = {}, at = T0) {
    const d = { fetchCalls: [], spawnCalls: [] };
    d.fetchTitle = (ref) => { d.fetchCalls.push(ref); const v = titles[`${ref.repo || ""}#${ref.number}`]; return typeof v === "function" ? v(ref) : (v === undefined ? `Title${ref.number}` : v); };
    d.now = () => at;
    d.spawnSync = (cmd, args, opts) => { d.spawnCalls.push({ cmd, args, opts }); return { status: 1, stdout: "", stderr: "stub" }; };
    return d;
  }
  // realPath(origin, answers) — deps without fetchTitle; git answers `origin`, answers[cmd] answers others.
  function realPath(origin, answers = {}) {
    const d = deps(); delete d.fetchTitle;
    d.spawnSync = (cmd, args, opts) => {
      d.spawnCalls.push({ cmd, args, opts });
      if (cmd === "git") return { status: 0, stdout: `${origin}\n`, stderr: "" };
      return answers[cmd] || { status: 1, stdout: "", stderr: "stub" };
    };
    return d;
  }
  function call(sid, prompt, d, cwd) { let r; try { r = require(ENTRY).run(input(sid, prompt, cwd), d); } catch (e) { r = { threw: e.message }; } return r; }
  // Anchor for every "nothing happened" check: without a loadable run() they would pass vacuously.
  const LOADED = (() => { try { return typeof require(ENTRY).run === "function"; } catch (_) { return false; } })();
  const quiet = (r) => LOADED && typeof r !== "string" && !(r && r.threw);
  const spawned = (d, cmd) => d.spawnCalls.filter((x) => x.cmd === cmd);
  const cmds = (d) => JSON.stringify(d.spawnCalls.map((x) => x.cmd));

  function constants() {
    const out = {};
    for (const rel of [ENTRY, path.join(ROOT, "hooks", "user-prompt-submit-issue-title", "title.js")]) {
      let m = {};
      try { m = require(rel); } catch (_) { /* the H4 checks report the missing values */ }
      for (const k of ["ORIGIN_TIMEOUT_MS", "TRACKER_TIMEOUT_MS", "MAX_ATTEMPTS", "COOLDOWN_MS"]) if (out[k] === undefined && m[k] !== undefined) out[k] = m[k];
    }
    return out;
  }
  function runHook(stdin) {
    const env = Object.assign({}, process.env);
    delete env.CLAUDE_CODE_SESSION_ID;
    const r = cp.spawnSync(process.execPath, [ENTRY], { input: stdin, encoding: "utf8", timeout: 20000, cwd: neutral, env });
    return { code: r.status, out: (r.stdout || "").trim(), err: r.stderr || "" };
  }
  // project(tag, envLines) — a project root (.git entry) whose .env.local holds envLines, or none when null.
  let p = 0;
  function project(tag, envLines) {
    const dir = path.join(tmp, `project-${tag}-${++p}`);
    fs.mkdirSync(path.join(dir, ".git"), { recursive: true });
    if (envLines) fs.writeFileSync(localEnvPathFor(dir), `${envLines.join("\n")}\n`);
    return dir;
  }

  return {
    ROOT, ENTRY, WS, T0, MIN, neutral, LOADED, restoreEnv,
    newSid, wrapped, input, recordPath, readRecord, seed, writeIntent,
    deps, realPath, call, quiet, spawned, cmds, constants, runHook, project,
  };
}

module.exports = { makeFixtures };
