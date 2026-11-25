"use strict";
// Tests: hooks/scan-outbound.js, hooks/lib/forge-write-extract.js
// Tags: TL2, hooks, pretooluse, scan-outbound, forge, security, subprocess, sandbox, table-driven, scope:issue-specific
// #3150 T-A2 (hook call sites): the shared path check reaches the PreToolUse hook through both
// a Write payload and a forge body (inline --body and --body-file). Old path forms block as
// before; new forms (lower-case users, JSON \\, U+00A5, any-case home) block too; an allowlist
// row lets each through. The hook runs from a copy outside any git repository, so the scanner
// reads only the synthetic lists written here; scan-offensive is a stub and gh is faked.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const restore = isolate();
const REPO = path.join(__dirname, "..", "..");
const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "f3150-hook-")));
after(() => { fs.rmSync(TMP, { recursive: true, force: true }); restore(); });

const BS = "\\";
const SL = "/";
const YEN = "¥";
const NAME = "someone";

// The sandbox: the hook tree and the scanner, nothing that resolves to the real lists.
const SBOX = path.join(TMP, "sbox");
for (const rel of ["hooks", "bin/scan-outbound.sh", "bin/scan-outbound.d", "bin/lib"]) {
  fs.cpSync(path.join(REPO, rel), path.join(SBOX, rel), { recursive: true });
}
fs.writeFileSync(path.join(SBOX, "bin", "scan-offensive"), "#!/usr/bin/env node\nprocess.exit(0);\n");
fs.writeFileSync(path.join(SBOX, ".private-info-blocklist"), "fixture-never-present-token\n");
const HOOK = path.join(SBOX, "hooks", "scan-outbound.js");
const NEUTRAL = path.join(TMP, "neutral");
fs.mkdirSync(NEUTRAL);
const TRANSCRIPTS = path.join(TMP, "transcripts");
fs.mkdirSync(TRANSCRIPTS);

// Every gh spawn fails (status 1) so no visibility lookup reaches the network.
const FAKE_GH = path.join(TMP, "fake-gh.js");
fs.writeFileSync(FAKE_GH, `"use strict";
const cp = require("child_process");
const isGh = (c) => /(^|[\\\\/])gh(\\.exe)?$/i.test(String(c));
const fake = (o) => { const enc = o && o.encoding && o.encoding !== "buffer"; const e = enc ? "" : Buffer.alloc(0);
  return { pid: 0, status: 1, signal: null, stdout: e, stderr: e, output: [null, e, e] }; };
for (const name of ["spawnSync", "execFileSync"]) {
  const orig = cp[name];
  cp[name] = function (cmd, args, opts) {
    if (!isGh(cmd)) return orig.apply(this, arguments);
    if (name === "spawnSync") return fake(Array.isArray(args) ? opts : args);
    const e = new Error("fake gh"); e.status = 1; throw e;
  };
}
const origExec = cp.execSync;
cp.execSync = function (cmd) {
  if (/(^|[\\s/\\\\])gh(\\.exe)?(\\s|$)/.test(String(cmd))) { const e = new Error("fake gh"); e.status = 1; throw e; }
  return origExec.apply(this, arguments);
};
`);

function setAllow(rows) {
  const p = path.join(SBOX, ".private-info-allowlist");
  fs.rmSync(p, { force: true });
  if (rows.length > 0) fs.writeFileSync(p, rows.join("\n") + "\n");
}

// runHook(toolName, toolInput) -> { decision, reason }
function runHook(toolName, toolInput) {
  const env = { ...process.env, CLAUDE_TRANSCRIPT_BASE_DIR: TRANSCRIPTS };
  for (const k of ["CLAUDE_CODE_SESSION_ID", "CLAUDE_PROJECT_DIR", "HOOK_CWD", "AGENTS_MAIN_ROOT"]) delete env[k];
  const input = JSON.stringify({ tool_name: toolName, tool_input: toolInput });
  const r = spawnSync(process.execPath, ["-r", FAKE_GH, HOOK], { input, cwd: NEUTRAL, env, encoding: "utf8", timeout: 60000 });
  assert.ok(!r.error, `hook spawn error: ${r.error && r.error.message}`);
  const lines = String(r.stdout || "").trim().split("\n").filter(Boolean);
  let out = {};
  try { out = JSON.parse(lines[lines.length - 1]); } catch { out = {}; }
  assert.ok(out.decision, `hook printed a decision (stdout=${r.stdout} stderr=${r.stderr})`);
  return { decision: out.decision, reason: String(out.reason || "") };
}

let seq = 0;
const writeOf = (text) => ({ file_path: path.join(TMP, "out", `note-${++seq}.md`).replace(/\\/g, "/"), content: `${text}\n` });
const inlineBodyOf = (text) => ({ command: `gh issue create --title t --body '${text}'`, cwd: NEUTRAL });
function bodyFileOf(text) {
  const f = path.join(TMP, `body-${++seq}.md`);
  fs.writeFileSync(f, `${text}\n`);
  return { command: `gh issue create --title t --body-file ${f.replace(/\\/g, "/")}`, cwd: NEUTRAL };
}

// form: old (reported before #3150) / new (reported from #3150 on).
const PATHS = [
  { name: "old-mac-users", form: "old", text: `see ${SL}Users${SL}${NAME}${SL}proj` },
  { name: "old-drive-backslash", form: "old", text: `see C:${BS}Users${BS}${NAME}${BS}proj` },
  { name: "old-home", form: "old", text: `see ${SL}home${SL}${NAME}${SL}proj` },
  { name: "new-lower-drive-slash", form: "new", text: `see c:${SL}users${SL}${NAME}${SL}proj` },
  { name: "new-json-backslash", form: "new", text: `see "C:${BS}${BS}Users${BS}${BS}${NAME}${BS}${BS}proj"` },
  { name: "new-yen", form: "new", text: `see C:${YEN}Users${YEN}${NAME}${YEN}proj` },
  { name: "new-upper-home", form: "new", text: `see ${SL}HOME${SL}${NAME}${SL}proj` },
];
// Inline --body is single-quoted; a form that holds no quote fits there.
const ROUTES = [
  { route: "write", target: "hooks/scan-outbound.js", tool: "Write", input: writeOf, fits: () => true },
  { route: "forge-inline-body", target: "hooks/lib/forge-write-extract.js", tool: "Bash", input: inlineBodyOf, fits: (t) => !t.includes("'") },
  { route: "forge-body-file", target: "hooks/lib/forge-write-extract.js", tool: "Bash", input: bodyFileOf, fits: () => true },
];

caseBegin("hook-write-path-forms-block", "hooks/scan-outbound.js");
setAllow([]);
for (const { name, form, text } of PATHS) {
  test(`write/${name} (${form} form): blocked as private information with a [path] finding`, () => {
    const { decision, reason } = runHook("Write", writeOf(text));
    assert.strictEqual(decision, "block", `write/${name}: decision (reason: ${reason})`);
    assert.match(reason, /Private information detected/, `write/${name}: private-info block`);
    assert.match(reason, /\[path\]/, `write/${name}: a path finding`);
  });
}
caseEnd();

caseBegin("hook-forge-body-path-forms-block", "hooks/lib/forge-write-extract.js");
for (const { route, input, fits } of ROUTES.filter((r) => r.tool === "Bash")) {
  for (const { name, form, text } of PATHS.filter((p) => fits(p.text))) {
    test(`${route}/${name} (${form} form): the extracted forge body is blocked`, () => {
      setAllow([]);
      const { decision, reason } = runHook("Bash", input(text));
      assert.strictEqual(decision, "block", `${route}/${name}: decision (reason: ${reason})`);
      assert.match(reason, /\[path\]/, `${route}/${name}: a path finding`);
    });
  }
}
caseEnd();

caseBegin("hook-allowlist-row-approves-every-form", "hooks/scan-outbound.js");
for (const { route, tool, input, fits } of ROUTES) {
  for (const { name, text } of PATHS.filter((p) => fits(p.text))) {
    test(`${route}/${name}: an allowlist row naming the user lets it through`, () => {
      setAllow([NAME]);
      try {
        const { decision, reason } = runHook(tool, input(text));
        assert.strictEqual(decision, "approve", `${route}/${name}: decision (reason: ${reason})`);
      } finally {
        setAllow([]);
      }
    });
  }
}
caseEnd();

caseBegin("hook-non-path-look-alikes-approved", "hooks/scan-outbound.js");
for (const text of [`GET https:${SL}${SL}api.github.com${SL}users${SL}${NAME}`, `Manage Users${SL}Groups here`, `see ${SL}Users${SL}<name>${SL}proj`]) {
  test(`write ${JSON.stringify(text)}: approved (no local path)`, () => {
    setAllow([]);
    const { decision, reason } = runHook("Write", writeOf(text));
    assert.strictEqual(decision, "approve", `decision (reason: ${reason})`);
  });
}
caseEnd();
