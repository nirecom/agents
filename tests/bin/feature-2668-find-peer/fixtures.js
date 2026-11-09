"use strict";
// Fixture surface of tests/bin/feature-2668-find-peer.js and tests/bin/feature-2668-peer-msg.js (#2668).
// No case markers. Every child runs from a neutral temp cwd with CLAUDE_CODE_SESSION_ID removed
// unless a case passes its own, and with a stub AGENTS_MAIN_ROOT.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const cp = require("node:child_process");
const { fakeCliDir, fakeCliEnv, withEnv, calls } = require("./fake-cli");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const fwd = (p) => p.replace(/\\/g, "/");

// agentsListText(entries) renders a ListAgents dump for --agents-file. The real shape is captured
// by verification (b) of the detail plan and saved as the parser fixture; until it lands, this
// placeholder stands in, and this function is the one place to change when it does:
// one entry per line, "- [<ref>] <name>", plus " session=<id>" when the dump shows the session id
// of the entry without going through its name.
function agentsListText(entries) {
  return `${entries.map((e) => `- [${e.ref}] ${e.name}${e.sessionId ? ` session=${e.sessionId}` : ""}`).join("\n")}\n`;
}

// realAgentsListText(entries) renders the ListAgents dump observed on Claude Code 2.1.319: two header
// lines, then per peer "  <name> [<ref6>]  ·  <kind>  ·  <state>  ·  started 7h ago"; e.raw replaces a row.
function realAgentsListText(entries, own = { name: "#1 Self [00000000]", ref: "000000" }) {
  const rows = entries.map((e) => (e.raw !== undefined ? e.raw : `  ${e.name} [${e.ref}]  ·  ${e.kind || "interactive"}  ·  ${e.state || "idle"}  ·  started 7h ago`));
  return `This session is "${own.name}" [${own.ref}].\nPeer sessions (${entries.length}):\n${rows.join("\n")}\n`;
}

// uuid(prefix8) ->a lower-case UUID that starts with prefix8 (8 hex digits); the rest is fixed so
// two ids that share the prefix differ only after it.
let serial = 0;
function uuid(prefix8, tail) {
  const t = tail || String(++serial).padStart(12, "0");
  return `${prefix8}-0000-4000-8000-${t}`;
}

// parseKv(stdout) -> { KEY: value } of the key=value lines; a repeated key keeps every value in
// KEY_all so a case can assert that a key was printed once.
function parseKv(stdout) {
  const out = {};
  for (const line of String(stdout || "").split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (!m) continue;
    if (out[m[1]] === undefined) out[m[1]] = m[2];
    (out[`${m[1]}_all`] = out[`${m[1]}_all`] || []).push(m[2]);
  }
  return out;
}

function makeFixtures(tmp) {
  const neutral = path.join(tmp, "neutral");
  const stubRoot = path.join(tmp, "agents-stub");
  const mockBin = path.join(tmp, "mock-bin");
  for (const d of [neutral, stubRoot, mockBin, path.join(tmp, "transcripts")]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(stubRoot, ".env"), "");

  // childEnv(extra) -> the environment of every spawned CLI: isolated workflow dirs (pinned by the
  // dispatcher's isolate()), no inherited session id, an empty transcript base, a stub main root,
  // the mock bin first on PATH. extra values win; a null value removes the key.
  fakeCliDir(mockBin);
  const cliLog = path.join(tmp, "cli.log");
  fs.writeFileSync(cliLog, "");
  function childEnv(extra = {}) {
    const base = withEnv(process.env, { CLAUDE_CODE_SESSION_ID: null, CLAUDECODE: null, CLAUDE_PROJECT_DIR: null, AGENTS_MAIN_ROOT: stubRoot, CLAUDE_TRANSCRIPT_BASE_DIR: path.join(tmp, "transcripts") });
    return withEnv(withEnv(base, fakeCliEnv(mockBin, cliLog, base)), extra);
  }
  // cliCalls(cmd) -> the logged gh / glab calls of every child so far (cmd filters by name).
  const cliCalls = (cmd) => calls(cliLog).filter((c) => !cmd || c.cmd === cmd);

  // runBin(rel, args, { env, cwd, input, timeout }) -> { code, out, err, kv }. The file is run
  // through bash so a node-shebang and a bash entry both start the same way on every OS.
  function runBin(rel, args, o = {}) {
    const file = fwd(path.join(ROOT, rel));
    const r = cp.spawnSync("bash", ["-c", '"$0" "$@"', file, ...args], {
      cwd: o.cwd || neutral, env: childEnv(o.env), input: o.input || "", encoding: "utf8", timeout: o.timeout || 60000,
    });
    return { code: r.status, out: r.stdout || "", err: `${r.stderr || ""}${r.error ? String(r.error) : ""}`, kv: parseKv(r.stdout) };
  }

  let n = 0;
  function writeFile(name, text) {
    const p = path.join(tmp, `${++n}-${name}`);
    fs.writeFileSync(p, text);
    return p;
  }

  // gitRepo(origin) -> a fixture repo whose origin is `origin`; no installed hook fires in it.
  function gitRepo(origin) {
    const dir = path.join(tmp, `repo-${++n}`);
    for (const args of [["init", "-q", dir], ["-C", dir, "config", "core.hooksPath", "/dev/null"], ["-C", dir, "remote", "add", "origin", origin]]) {
      const r = cp.spawnSync("git", args, { encoding: "utf8", timeout: 30000 });
      if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
    }
    return dir;
  }

  // mockGlab(labels) — a bash glab first on PATH (wip-state.sh reaches glab from bash): every call
  // is logged to the returned file; `--json labels` answers the given label names.
  function mockGlab(labels) {
    const log = path.join(tmp, `glab-${++n}.log`);
    const json = JSON.stringify(labels.map((name) => ({ name })));
    fs.writeFileSync(path.join(mockBin, "glab"), `#!/bin/bash\nprintf '%s\\n' "$*" >> '${fwd(log)}'\ncase "$*" in *"--json labels"*) printf '%s\\n' '${json}'; exit 0 ;; esac\nexit 1\n`, { mode: 0o755 });
    fs.writeFileSync(log, "");
    return log;
  }

  return { ROOT, neutral, stubRoot, mockBin, childEnv, cliCalls, runBin, writeFile, gitRepo, mockGlab };
}

// load(rel) -> the module, or a stand-in whose every property throws the load error, so a case
// against a missing source fails with the reason instead of crashing the file at load time.
function load(rel) {
  try {
    return require(path.join(ROOT, rel));
  } catch (e) {
    return new Proxy({}, { get: (_t, k) => (k === "then" ? undefined : () => { throw new Error(`cannot load ${rel}: ${e.message}`); }) });
  }
}

module.exports = { ROOT, agentsListText, realAgentsListText, uuid, parseKv, makeFixtures, load, tmpRoot: () => fs.mkdtempSync(path.join(os.tmpdir(), "find-peer-")) };
