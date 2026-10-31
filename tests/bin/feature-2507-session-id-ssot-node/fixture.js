"use strict";
// Tests: bin/check-session-id-ssot.sh
// Tags: TL1, bin, session-id, fixture, test-lang-exception:symmetry, scope:issue-specific
// Fixture helpers of tests/bin/feature-2507-session-id-ssot-node.js (#2507). Holds no case markers.
// Both runners judge the same tree: bashCli spawns bin/check-session-id-ssot.sh (the pre-port
// reference), nodeRun calls run() of bin/check-session-id-ssot/main.js in this process.
// Assumed Node contract: run({ argv, cwd, env, stdout, stderr }) -> rc (or a promise of it), where
// stdout / stderr are { write(s) } sinks and argv holds only the flags and paths.
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
// Taken before the entrypoint's spawn counter patches the module object, so these never count.
const { spawnSync } = require("node:child_process");

const REPO = path.join(__dirname, "..", "..", "..");
const GUARD = path.join(REPO, "bin", "check-session-id-ssot.sh");
const MAIN = path.join(REPO, "bin", "check-session-id-ssot", "main.js");
const TABLE_REL = "bin/check-session-id-ssot/path-tables.txt";
const RET_S = "CLAUDE_" + "SESSION_ID";
const RET_E = "CLAUDE_" + "ENV_FILE";
const fwd = (p) => p.replace(/\\/g, "/");

const expand = (s) => s.split("@S@").join(RET_S).split("@E@").join(RET_E).split("@CR@").join("\r");
const content = (row) => (row.bytes ? row.bytes.map(expand).join("") : row.lines.map(expand).join("\n") + "\n");

const roots = [];
function tmpRoot(tag) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), `sid-ssot-2507-${tag}-`));
  roots.push(d);
  return d;
}
function cleanup() {
  for (const d of roots.splice(0)) fs.rmSync(d, { recursive: true, force: true });
}

function writeFile(root, rel, text) {
  const abs = path.join(root, rel);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, text);
}

// makeTree(tag, rows, { tables }) — rows written under a fresh root; tables: the path-tables text
// (default: the guard's own copy), or null for a tree without the file.
function makeTree(tag, rows, opts = {}) {
  const root = tmpRoot(tag);
  const tables = opts.tables === undefined ? fs.readFileSync(path.join(REPO, TABLE_REL), "utf8") : opts.tables;
  if (tables !== null) writeFile(root, TABLE_REL, tables);
  for (const row of rows) writeFile(root, row.path, content(row));
  return root;
}

// expected(rows, gate) — the stdout the guard prints for these rows in this order.
function expected(rows, gate) {
  const out = [];
  for (const row of rows) {
    const lines = content(row).split("\n");
    for (const n of row.want) {
      const text = lines[n - 1];
      out.push(gate === "tomb" ? `${row.path}:${n}:${text}` : `${row.path}:${n}: ${text.replace(/^[\s]+/, "")}`);
    }
  }
  if (out.length === 0) return "";
  if (gate === "tomb") {
    return `${out.join("\n")}\n\nRetired session-id relay names reintroduced (${out.length}). Use CLAUDE_CODE_SESSION_ID; see docs/architecture/claude-code/session-id-resolution.md#retired-relay.\n`;
  }
  return `${out.join("\n")}\n\nDirect session-id env reads bypass the SSOT resolver (${out.length}).\n` +
    "Call resolveSessionId() instead, or add an inline waiver:\n" +
    "  // session-id-ssot: waived (<role>) — <why the resolver cannot be used here>\n" +
    "See docs/architecture/claude-code/session-id-resolution.md.\n";
}

function childEnv() {
  const env = { ...process.env, LC_ALL: "C.UTF-8" };
  delete env[RET_S];
  delete env[RET_E];
  delete env.CLAUDE_CODE_SESSION_ID;
  return env;
}

function bashCli(cwd, argv, guard = GUARD) {
  const r = spawnSync("bash", [fwd(guard), ...argv], { cwd, env: childEnv(), encoding: "utf8", timeout: 120000 });
  assert.ok(!r.error, `bash guard did not run: ${r.error}`);
  return { rc: r.status, stdout: r.stdout, stderr: r.stderr };
}

let mainModule = null;
function loadMain() {
  if (!mainModule) mainModule = require(MAIN);
  assert.strictEqual(typeof mainModule.run, "function", "bin/check-session-id-ssot/main.js exports no run()");
  return mainModule;
}

async function nodeRun(cwd, argv) {
  const main = loadMain();
  let stdout = "";
  let stderr = "";
  const rc = await main.run({
    argv, cwd, env: childEnv(),
    stdout: { write: (s) => { stdout += String(s); return true; } },
    stderr: { write: (s) => { stderr += String(s); return true; } },
  });
  return { rc, stdout, stderr };
}

// verdict(rows, gate) — the { rc, stdout } a positional run over rows must give.
function verdict(rows, gate) {
  const stdout = expected(rows, gate);
  return { rc: stdout === "" ? 0 : 1, stdout };
}

// A reported line's trailing CR is platform-dependent in the bash guard (MSYS read drops it, Linux
// keeps it), so stdout is compared with CR-before-LF folded; the reported line itself must match.
const foldCr = (s) => String(s).replace(/\r\n/g, "\n");
function assertRun(got, want, label) {
  assert.strictEqual(foldCr(got.stdout), foldCr(want.stdout), `${label}: stdout`);
  assert.strictEqual(got.rc, want.rc, `${label}: rc (stderr: ${got.stderr})`);
}

function git(cwd, ...args) {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
}

module.exports = {
  REPO, GUARD, MAIN, TABLE_REL, RET_S, RET_E, expand, makeTree, writeFile, expected, verdict,
  bashCli, nodeRun, assertRun, git, tmpRoot, cleanup,
};
