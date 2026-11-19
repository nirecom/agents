"use strict";
// Fixture of tests/bin/feature-2941-pm-state-cli.js (#2941). No case markers.
// bin/pm-state runs as a child from a fixture repo whose origin is github.com/o/r, with a fake gh
// first on PATH (./fake-gh.js), the pinned state dirs, no session id and an empty transcript base.
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { gitInit } = require("../../lib/harness");
const P = require("../../lib/pm-state-fixture");

function makeFixture(tmp) {
  const bin = path.join(tmp, "bin");
  const repo = path.join(tmp, "repo");
  const transcripts = path.join(tmp, "transcripts");
  for (const d of [bin, repo, transcripts]) fs.mkdirSync(d, { recursive: true });
  gitInit(repo);
  const g = cp.spawnSync("git", ["-C", repo, "remote", "add", "origin", "https://github.com/o/r.git"], { encoding: "utf8", timeout: 30000 });
  if (g.status !== 0) throw new Error(`git remote add: ${g.stderr}`);
  const log = path.join(tmp, "gh.log");
  const mapFile = path.join(tmp, "gh-map.json");
  fs.writeFileSync(log, "");
  fs.writeFileSync(mapFile, "{}");
  fs.writeFileSync(path.join(bin, "gh"), `#!/bin/bash\nexec node '${P.fwd(path.join(__dirname, "fake-gh.js"))}' "$@"\n`, { mode: 0o755 });

  const setMap = (m) => fs.writeFileSync(mapFile, JSON.stringify(m));
  const ghCalls = () => fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  // queriesFor(n) -> how many logged graphql calls asked about issue n.
  const queriesFor = (n, calls) => calls.filter((a) => new RegExp(`\\bnumber\\s*[:=]\\s*\\\\?"?${n}\\b`).test(a.join(" "))).length;

  // run(args, {env, caller}) -> {code, out, err, json, calls}: bin/pm-state through bash; calls are
  // the gh calls this run made; caller becomes CLAUDE_CODE_SESSION_ID (the calling PM session).
  function run(args, o = {}) {
    const before = ghCalls().length;
    const env = Object.assign({}, process.env, { PM_FAKE_GH_LOG: log, PM_FAKE_GH_MAP: mapFile, CLAUDE_TRANSCRIPT_BASE_DIR: transcripts }, o.env || {});
    delete env.CLAUDE_CODE_SESSION_ID;
    if (o.caller) env.CLAUDE_CODE_SESSION_ID = o.caller;
    const pathKey = Object.keys(env).find((k) => k.toUpperCase() === "PATH") || "PATH";
    env[pathKey] = `${bin}${path.delimiter}${env[pathKey] || ""}`;
    const r = cp.spawnSync("bash", ["-c", '"$0" "$@"', P.fwd(path.join(P.ROOT, "bin", "pm-state")), ...args], { cwd: repo, env, encoding: "utf8", timeout: 60000 });
    let json;
    try { json = JSON.parse(String(r.stdout).trim()); } catch (_) { json = undefined; }
    return { code: r.status, out: r.stdout || "", err: `${r.stderr || ""}${r.error ? String(r.error) : ""}`, json, calls: ghCalls().slice(before) };
  }
  let n = 0;
  const seqFile = (obj) => {
    const f = path.join(tmp, `seq-${++n}.json`);
    fs.writeFileSync(f, typeof obj === "string" ? obj : JSON.stringify(obj));
    return f;
  };
  return { repo, run, setMap, ghCalls, queriesFor, seqFile };
}

// table(nums) -> a set-sequence payload {tables:[...]} with one wave holding the issues.
const table = (nums) => ({ tables: [{ title: "order", waves: [{ issues: nums.map((number) => ({ number, reason: "fixture", blocked_by: [], conflicts: [] })) }] }] });
const nums = (issues) => (issues || []).map((i) => (typeof i === "object" ? i.number : Number(String(i).replace(/^.*#/, ""))));
const parent = (n, repo) => ({ parent: { number: n, repo: repo || "o/r" } });

module.exports = { makeFixture, table, nums, parent, P };
