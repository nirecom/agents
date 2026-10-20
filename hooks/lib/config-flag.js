"use strict";
// Single owner of how a config flag is classified: the five kinds behind
// bin/get-config-var --is-off and the OFF/ON/ERROR mapping behind bin/confirm-off.
// Node callers require it and resolve in-process (never starts a subprocess);
// the two bash scripts reach runCli through one node hop. Exit codes stay with
// the shell side. Value resolution itself stays with load-env's resolveConfigVar.
// classifyConfigFlag puts process.env back exactly as it found it on every path,
// so a .env value it loads never leaks into the caller's later children (#2681).
// load-env's own stderr (key names only, never values) passes through unchanged.
// Named exception (#2726/#2729): the plan-stage CONFIRM keys are read from the global config
// file only — an export, an inline env prefix or a project .env.local never decides them.

const KINDS = ["off", "on", "unset", "unrecognized", "failed"];

// isPlanStageConfirmKey(name) -> true only for a plan-stage-table confirmFlag (allowlist).
function isPlanStageConfirmKey(name) {
  const { PLAN_STAGE_TABLE } = require("../workflow-state/plan-stage-table");
  return Object.values(PLAN_STAGE_TABLE).some((row) => row.confirmFlag === name);
}

function restoreEnv(before) {
  try {
    for (const k of Object.keys(process.env)) {
      if (!Object.prototype.hasOwnProperty.call(before, k)) delete process.env[k];
    }
    for (const k of Object.keys(before)) {
      if (process.env[k] !== before[k]) process.env[k] = before[k];
    }
  } catch (_e) {
    // A failed restore must not change the answer.
  }
}

// Trailing newlines are dropped (as shell command substitution does); ASCII-only lowercase.
function kindOfValue(value) {
  const v = value.replace(/\n+$/, "");
  if (v === "") return "unset";
  const lower = v.replace(/[A-Z]/g, (c) => c.toLowerCase());
  if (lower === "off") return "off";
  if (lower === "on") return "on";
  return "unrecognized";
}

function classifyFromConfigFile(name, dflt) {
  try {
    const raw = require("./load-env").readDefaultEnvFile()[name];
    const value = raw == null || String(raw) === "" ? dflt : String(raw);
    return { kind: kindOfValue(value), value, cause: null };
  } catch (_e) {
    return { kind: "failed", value: dflt, cause: "exception" };
  }
}

// -> { kind, value, cause }; cause is null, "load-failed" or "exception".
function classifyConfigFlag(name, defaultValue, opts) {
  const dflt = defaultValue || "";
  if (isPlanStageConfirmKey(name)) return classifyFromConfigFile(name, dflt);
  const before = Object.assign({}, process.env);
  const exported = process.env[name];
  const fallback = exported && exported.length ? exported : dflt;
  try {
    const r = require("./load-env").resolveConfigVar(name, dflt, { repoRoot: (opts && opts.repoRoot) || "" });
    const value = String(r.value == null ? "" : r.value);
    if (r.loadFailed === true) return { kind: "failed", value, cause: "load-failed" };
    return { kind: kindOfValue(value), value, cause: null };
  } catch (_e) {
    return { kind: "failed", value: fallback, cause: "exception" };
  } finally {
    restoreEnv(before);
  }
}

function verdictOfKind(kind) {
  if (kind === "off") return "OFF";
  if (kind === "on" || kind === "unset" || kind === "unrecognized") return "ON";
  return "ERROR";
}

// Writes one token to stdout, no newline: value -> the resolved value;
// kind -> <kind> or "failed <cause>"; verdict -> OFF | ON | "ERROR <cause>".
function runCli(args) {
  const a = args || {};
  const r = classifyConfigFlag(a.name, a.defaultValue, { repoRoot: a.repoRoot });
  if (a.mode === "kind") {
    if (r.kind === "unrecognized") {
      process.stderr.write("get-config-var: unrecognized value for " + a.name +
        " (value withheld; caller-dependent: exit 3 — see usage header for ON vs OFF handling)\n");
    }
    process.stdout.write(r.kind === "failed" ? "failed " + r.cause : r.kind);
    return;
  }
  if (a.mode === "verdict") {
    if (r.kind === "unrecognized") {
      process.stderr.write("confirm-off: unrecognized value for " + a.name + " (value withheld; treated as ON)\n");
    }
    const verdict = verdictOfKind(r.kind);
    process.stdout.write(verdict === "ERROR" ? "ERROR " + r.cause : verdict);
    return;
  }
  process.stdout.write(r.value);
}

module.exports = { KINDS, kindOfValue, isPlanStageConfirmKey, classifyConfigFlag, verdictOfKind, runCli };
