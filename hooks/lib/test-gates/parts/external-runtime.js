"use strict";
// The pester / pytest parts (#2507 D7): their readers and analyzers stay child processes of their
// own runtime, so this is the one place their launch arguments live. reader(file, { id }) ->
// { rc, g } (79 when the runtime is not on PATH); analyzer(op, file, helper, { id }) ->
// { rc, stdout, stderr } as the child answers (69 when the runtime is not on PATH).

const path = require("path");
const { REPO_ROOT, which, env } = require("../registry");
const S = require("../source");
const { bridge } = require("./reader-records");
const { toWindowsPath } = require("../../branch-diff");

const PARTS = path.join(REPO_ROOT, "bin", "lib", "test-language-parts");
const LAUNCH = {
  pester: { command: "pwsh", pre: ["-NoProfile", "-NonInteractive", "-File"], reader: "pester-case-reader.ps1", analyzer: "pester-case-analyzer.ps1" },
  pytest: { command: "uv", pre: ["run", "--no-project", "python"], reader: "pytest-case-reader.py", analyzer: "pytest-case-analyzer.py" },
};
const TIMEOUT_MS = 120000;

// native(p) — the path a non-shell child opens (cygpath -m form).
const native = (p) => toWindowsPath(String(p)).replace(/\\/g, "/");

// launchSpec(id, kind, { op, file, helper }) -> { command, args }; helper is passed for self-impl only.
function launchSpec(id, kind, { op, file, helper } = {}) {
  const l = LAUNCH[id];
  if (!l) throw new Error(`external-runtime: no launch for ${id}`);
  const script = native(path.join(PARTS, kind === "reader" ? l.reader : l.analyzer));
  if (kind === "reader") return { command: l.command, args: [...l.pre, script, native(file)] };
  const extra = op === "self-impl" ? [helper === undefined ? "" : String(helper)] : [];
  return { command: l.command, args: [...l.pre, script, op, native(file), ...extra] };
}

// spawn(spec) — { rc, stdout, stderr }; rc null when the command could not start.
function spawn(spec) {
  const cp = require("node:child_process");
  const exe = which(spec.command) || spec.command;
  const r = cp.spawnSync(exe, spec.args, { encoding: "utf8", env: env(), timeout: TIMEOUT_MS, windowsHide: true });
  if (r.error && r.error.code === "ENOENT") return { rc: null, stdout: "", stderr: "" };
  return { rc: r.error ? 1 : r.status === null ? 1 : r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

// An in-memory file reaches the child as a temp copy (S.diskCopy, the reported exception to D7's
// no-temp-file rule), only once the runtime is known to be on PATH.
function reader(file, ctx = {}) {
  if (!which(LAUNCH[ctx.id] ? LAUNCH[ctx.id].command : ctx.id)) return { rc: 79 };
  return S.diskCopy(file, (f) => {
    const r = spawn(launchSpec(ctx.id, "reader", { file: f }));
    if (r.rc === null) return { rc: 79 };
    if (r.rc !== 0) return { rc: 1 };
    return bridge(r.stdout);
  });
}

function analyzer(op, file, helper, ctx = {}) {
  if (!which(LAUNCH[ctx.id] ? LAUNCH[ctx.id].command : ctx.id)) return { rc: 69, stdout: "", stderr: "" };
  return S.diskCopy(file, (f) => {
    const r = spawn(launchSpec(ctx.id, "analyzer", { op, file: f, helper }));
    return r.rc === null ? { rc: 69, stdout: "", stderr: "" } : r;
  });
}

module.exports = { LAUNCH, launchSpec, reader, analyzer, native };
