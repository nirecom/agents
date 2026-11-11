"use strict";
// The pester / pytest parts (#2507 D7): their readers and analyzers stay child processes of their
// own runtime. The registry owns their launch: `childLaunch` holds the arguments and the reader /
// analyzer paths, `launch.requires` the command; this file only reads it and starts the child.
// reader(file, { id }) -> { rc, g } (79 when the runtime is not on PATH); analyzer(op, file, helper,
// { id }) -> { rc, stdout, stderr } as the child answers (69 when the runtime is not on PATH).

const path = require("path");
const { REPO_ROOT, which, env, entryById, fieldValue } = require("../registry");
const S = require("../source");
const { bridge } = require("./reader-records");
const { toWindowsPath } = require("../../branch-diff");

const TIMEOUT_MS = 120000;

// native(p) — the path a non-shell child opens (cygpath -m form).
const native = (p) => toWindowsPath(String(p)).replace(/\\/g, "/");

const repoPath = (rel) => path.join(REPO_ROOT, ...rel.split("/"));

// launchOf(id) -> { command, pre, reader, analyzer } from the registry; null without childLaunch.
function launchOf(id) {
  const e = entryById(id);
  const c = e && e.childLaunch;
  if (!c) return null;
  return { command: fieldValue(e, "launch.requires"), pre: c.args, reader: repoPath(c.reader), analyzer: repoPath(c.analyzer) };
}

// launchSpec(id, kind, { op, file, helper }) -> { command, args }; helper is passed for self-impl only.
function launchSpec(id, kind, { op, file, helper } = {}) {
  const l = launchOf(id);
  if (!l) throw new Error(`external-runtime: no launch for ${id}`);
  const script = native(kind === "reader" ? l.reader : l.analyzer);
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

const commandOf = (id) => {
  const lo = launchOf(id);
  return lo ? lo.command : id;
};

// An in-memory file reaches the child as a temp copy (S.diskCopy, the reported exception to D7's
// no-temp-file rule), only once the runtime is known to be on PATH.
function reader(file, ctx = {}) {
  if (!which(commandOf(ctx.id))) return { rc: 79 };
  return S.diskCopy(file, (f) => {
    const r = spawn(launchSpec(ctx.id, "reader", { file: f }));
    if (r.rc === null) return { rc: 79 };
    if (r.rc !== 0) return { rc: 1 };
    return bridge(r.stdout);
  });
}

function analyzer(op, file, helper, ctx = {}) {
  if (!which(commandOf(ctx.id))) return { rc: 69, stdout: "", stderr: "" };
  return S.diskCopy(file, (f) => {
    const r = spawn(launchSpec(ctx.id, "analyzer", { op, file: f, helper }));
    return r.rc === null ? { rc: 69, stdout: "", stderr: "" } : r;
  });
}

module.exports = { launchSpec, reader, analyzer, native };
