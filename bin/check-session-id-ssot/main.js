"use strict";
// check-session-id-ssot (#2507 D7 port of the bash guard): (1) the SSOT read gate (#2270) and
// (2) the retired-relay tombstone (#1091), with test isolation lines judged by the registry's
// envClearLine part (#2590, #2411). Contract: docs/architecture/claude-code/session-id-resolution.md
// run({ argv, cwd, env, stdout, stderr }) -> rc: 0 clean | 1 violations | 2 usage or setup failure.
const path = require("node:path");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");
const { spawnSync } = require("../../hooks/lib/limited-child-process");
const S = require("./scan");

const GUARD_ROOT = path.join(__dirname, "..", "..");
const GIT_TIMEOUT_MS = 60000;

function parseArgs(argv) {
  const files = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--staged") continue;
    if (a === "--") return { files: files.concat(argv.slice(i + 1)) };
    if (a.startsWith("-")) return { error: `unknown flag: ${a}` };
    files.push(a);
  }
  return { files };
}

function trackedFiles(cwd, env) {
  const r = spawnSync("git", ["ls-files", "-z"], { cwd, env, encoding: "utf8", timeout: GIT_TIMEOUT_MS, maxBuffer: 256 * 1024 * 1024 });
  // A failed listing must end rc 2, never be judged as a clean tree of 0 files.
  if (r.error) throw new S.GuardError(r.error.code === "ENOENT" ? "git not found" : `git ls-files failed: ${r.error.code || r.error.message}`);
  if (r.status === null) throw new S.GuardError(`git ls-files killed by signal ${r.signal || "unknown"}`);
  if (r.status !== 0) throw new S.GuardError(`git ls-files exited ${r.status}: ${String(r.stderr || "").trim()}`);
  return String(r.stdout || "").split("\0").filter((f) => f !== "");
}

// The supported entry whose envClearLine judges f's lines, or "" outside isolation scope.
function isolationEntry(f, tables, registry) {
  if (!/^tests\/.*\//.test(f) && !tables.isolation.includes(f)) return "";
  const reg = registry();
  if (!reg) return "";
  const supported = reg.lib.entriesWhere("supported", reg.table);
  const byHelper = supported.find((e) => e.helperLibrary && e.helperLibrary.path === f);
  if (byHelper) return byHelper;
  const m = reg.lib.matchBasename(f.slice(f.lastIndexOf("/") + 1), reg.table);
  return m && m.status === "supported" ? m.entry : "";
}

// clears(entry, line, err) — true when the entry's envClearLine part accepts the line; an
// unreachable or failing part reports the line (fail closed).
function clears(entry, line, err) {
  const spec = entry.envClearLine;
  try {
    if (!spec || !spec.file) throw new Error(`entry ${entry.id} has no envClearLine`);
    let mod;
    try {
      mod = require(path.join(GUARD_ROOT, spec.file));
    } catch {
      throw new Error(`${entry.id}.envClearLine: part file missing: ${spec.file}`);
    }
    if (typeof mod[spec.function] !== "function") throw new Error(`${entry.id}.envClearLine: ${spec.file} does not define ${spec.function}`);
    return mod[spec.function](S.tombstoneNames(), line) === 0;
  } catch (e) {
    err(`[test-language-registry] ${String(e.message).split("\n")[0]}`);
    return false;
  }
}

function registryLoader(err) {
  let reg;
  return () => {
    if (reg !== undefined) return reg;
    try {
      const lib = require(path.join(GUARD_ROOT, "hooks", "lib", "test-language-registry.js"));
      reg = { lib, table: lib.loadRegistry() };
    } catch (e) {
      err(`[test-language-registry] ${String(e.message).replace(/\s*\n\s*/g, " ")}`);
      reg = null;
    }
    return reg;
  };
}

function tombstoneLines(files, texts, tables, err) {
  const out = [];
  const registry = registryLoader(err);
  for (const f of files) {
    const found = S.tombstoneHits(texts.get(f));
    if (found.length === 0) continue;
    const entry = isolationEntry(f, tables, registry);
    for (const h of found) if (!(entry && clears(entry, h.line, err))) out.push(`${f}:${h.n}:${h.line}`);
  }
  if (out.length === 0) return [];
  return [...out, "", `Retired session-id relay names reintroduced (${out.length}). Use CLAUDE_CODE_SESSION_ID; see docs/architecture/claude-code/session-id-resolution.md#retired-relay.`];
}

function readLines(files, texts) {
  const out = [];
  for (const f of files) {
    const text = texts.get(f);
    const all = text === null ? [] : S.splitLines(text);
    for (const h of S.readHits(text)) {
      if (S.waived(h.line) || (h.n > 1 && S.waived(all[h.n - 2]))) continue;
      out.push(`${f}:${h.n}: ${h.line.replace(/^[ \t\n\v\f\r]+/, "")}`);
    }
  }
  if (out.length === 0) return [];
  return [...out, "", `Direct session-id env reads bypass the SSOT resolver (${out.length}).`,
    "Call resolveSessionId() instead, or add an inline waiver:",
    "  // session-id-ssot: waived (<role>) — <why the resolver cannot be used here>",
    "See docs/architecture/claude-code/session-id-resolution.md."];
}

function run({ argv = [], cwd = process.cwd(), env = process.env, stdout = process.stdout, stderr = process.stderr } = {}) {
  const err = (s) => stderr.write(`${s}\n`);
  const root = toWindowsPath(cwd);
  const args = parseArgs(argv);
  if (args.error) {
    err("usage: check-session-id-ssot.sh [--staged] [file ...]");
    err(`check-session-id-ssot: ${args.error}`);
    return 2;
  }
  try {
    const tables = S.loadTables(root, GUARD_ROOT, err);
    const files = args.files.length ? args.files : trackedFiles(root, env);
    const scope = S.select(files, root, tables);
    const texts = new Map();
    for (const f of [...scope.tomb, ...scope.read]) if (!texts.has(f)) texts.set(f, S.readText(root, f));
    const lines = [...tombstoneLines(scope.tomb, texts, tables, err), ...readLines(scope.read, texts)];
    if (lines.length) stdout.write(`${lines.join("\n")}\n`);
    return lines.length ? 1 : 0;
  } catch (e) {
    if (!(e instanceof S.GuardError)) throw e;
    err(`check-session-id-ssot: ${e.message}`);
    return 2;
  }
}

module.exports = { run };

if (require.main === module) {
  process.exitCode = run({ argv: process.argv.slice(2) });
}
