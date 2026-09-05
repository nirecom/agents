"use strict";
// buildRemedy(hit) — the ADVISORY wording attached to a capture-echo rejection.
// It never changes WHETHER a command is rejected, only what the author is told,
// so it MUST NEVER THROW: every failure path degrades to the generic branch (c).
// SSOT matching is by absolute path identity, never basename — a basename match
// would call `bash /tmp/workflow-plans-dir` a registered entry point and hand back
// a reissue example that runs something else entirely.

const fs = require("fs");
const path = require("path");
const { resolveEffectiveSegment } = require("../lib/command-ir");
// Cross-feature import: the clearance-token scanner is the ONE sanctioned site
// enabling the preserveSubstitutionSpans option (fix-1780-round11 X1/X2).
const { parseWithSubstitutionSpans } = require("../block-clearance-token-write/bash-scan/scan");
const { peelWrappers, commandBasename } = require("../lib/bash-write-patterns/segment-utils");
const { normalizeForCompare } = require("../preuse-auto-approve.js");
const { isSecretShaped } = require("../workflow-state/complexity-routing/secret-shape");

const SSOT_REL = ["install", "settings-allow-commands.txt"];
const ENTRY_RE = /^[A-Za-z0-9._/-]+$/;
// An argument the reissue recipe may paste verbatim: a bare shell word whose
// spelling the shell cannot rewrite. Anything else degrades to the generic branch.
const SAFE_ARG_RE = /^[A-Za-z0-9._/=:@,+-]+$/;
// SAFE_ARG_RE is a SPELLING gate: `--token=<40 opaque chars>` passes it, and
// branchA reproduces every accepted argument verbatim in the rejection text. A
// secret must never be copied there, so a value that merely LOOKS like one sends
// the whole invocation to branchB, which names no argument at all.
const SECRET_NAME_RE = /(?:token|secret|password|passwd|api[_-]?key|apikey|credential|private[_-]?key)/i;
// The generic arm behind the vendor shapes: a long opaque word mixing letters and
// digits, with no path or extension separator to explain the mixture.
const OPAQUE_TOKEN_RE = /^[A-Za-z0-9_+-]{20,}$/;
const VALUE_SPLIT_RE = /[=:,]/;

function argLooksSecretBearing(arg) {
  if (isSecretShaped(arg)) return true;
  const eq = arg.indexOf("=");
  if (eq !== -1 && SECRET_NAME_RE.test(arg.slice(0, eq))) return true;
  return arg
    .split(VALUE_SPLIT_RE)
    .some((part) => OPAQUE_TOKEN_RE.test(part) && /[A-Za-z]/.test(part) && /[0-9]/.test(part));
}

function argIsQuotable(a) {
  return typeof a === "string" && SAFE_ARG_RE.test(a) && !argLooksSecretBearing(a);
}
const CONFIG_PREFIXES = ['"$AGENTS_CONFIG_DIR/', "$AGENTS_CONFIG_DIR/"];
const RULE_REF = 'See rules/shell-commands.md, "Command-Line Issuance Discipline".';

// Resolve the captured inner command to {interpreter, scriptArg, args}. This is a
// SECOND, independent parse of a DIFFERENT string, so it does not violate the
// entrypoint's parse-once-per-execution-unit contract.
function resolveInner(innerCommandText) {
  if (typeof innerCommandText !== "string" || innerCommandText.trim() === "") return null;
  const ir = parseWithSubstitutionSpans(innerCommandText);
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments) || ir.segments.length !== 1) return null;
  const eff = resolveEffectiveSegment(ir.segments[0]);
  if (!eff) return null;
  const peeled = peelWrappers(eff.cmd0, Array.isArray(eff.argv) ? eff.argv : []);
  const base = commandBasename(peeled.cmd0);
  if (base === "bash" || base === "node") {
    if (peeled.argv.length === 0) return null;
    const args = peeled.argv.slice(1);
    if (!args.every(argIsQuotable)) return null;
    return { interpreter: base, scriptArg: peeled.argv[0], args };
  }
  if (!peeled.argv.every(argIsQuotable)) return null;
  return { interpreter: null, scriptArg: peeled.cmd0, args: peeled.argv.slice() };
}

// Absolutize ONLY a literal $AGENTS_CONFIG_DIR prefix. A relative path is
// cwd-dependent and is never resolved against cwd; any other expansion is opaque.
function absolutizeScriptArg(scriptArg, configDir) {
  let s = scriptArg;
  for (const prefix of CONFIG_PREFIXES) {
    if (s.startsWith(prefix)) {
      s = path.join(configDir, s.slice(prefix.length).replace(/"$/, ""));
      return s.indexOf("$") === -1 ? s : null;
    }
  }
  if (s.indexOf("$") !== -1 || s.indexOf("`") !== -1) return null;
  return path.isAbsolute(s) ? s : null;
}

// The charset gate admits `..`, so containment is checked separately: an entry
// resolving outside configDir would make branchA recommend a file the SSOT list
// does not sanction.
// Lexical containment alone is not enough: an entry spelled impeccably can BE a
// symlink whose target lives outside the tree, so the resolved path is realpathed
// too. Fail-closed — an unresolvable entry is not a sanctioned entry point.
function isContainedEntry(entry, configDir) {
  const root = path.resolve(configDir);
  const abs = path.resolve(root, entry);
  if (abs !== root && !abs.startsWith(root + path.sep)) return false;
  try {
    const realRoot = fs.realpathSync(root);
    const real = fs.realpathSync(abs);
    return real === realRoot || real.startsWith(realRoot + path.sep);
  } catch (_e) {
    return false;
  }
}

// Entries of the SSOT list, or null when the file is unreadable, empty, or holds
// anything that is not a plain relative path (charset gate mirrors
// install/gen-settings-allow.js, so a corrupt file degrades instead of matching).
// Entries that escape configDir are dropped individually, so one bad line cannot
// promote an unrelated command to "registered entry point".
function readSsotEntries(configDir) {
  const raw = fs.readFileSync(path.join(configDir, ...SSOT_REL), "utf8");
  const entries = raw
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("#"));
  if (entries.length === 0) return null;
  if (!entries.every((e) => ENTRY_RE.test(e))) return null;
  return entries.filter((e) => isContainedEntry(e, configDir));
}

function shebangInterpreterOf(absPath) {
  const first = fs.readFileSync(absPath, "utf8").split("\n", 1)[0].trim();
  if (!first.startsWith("#!")) return null;
  const tokens = first.slice(2).trim().split(/\s+/).filter((t) => t.length > 0);
  const nameOf = (t) => path.posix.basename(t.split("\\").join("/"));
  let name = tokens.length > 0 ? nameOf(tokens[0]) : "";
  if (name === "env") name = tokens.length > 1 ? nameOf(tokens[1]) : "";
  return name === "bash" || name === "node" ? name : null;
}

// The SSOT entry whose absolute, normalized path is IDENTICAL to the inner
// command's script, and whose shebang agrees with the detected interpreter.
function matchSsotEntry(inner, configDir, entries) {
  const abs = absolutizeScriptArg(inner.scriptArg, configDir);
  if (abs === null) return null;
  const wanted = normalizeForCompare(abs);
  if (!wanted) return null;
  for (const entry of entries) {
    if (normalizeForCompare(path.resolve(configDir, entry)) !== wanted) continue;
    let shebang = null;
    try {
      shebang = shebangInterpreterOf(path.resolve(configDir, entry));
    } catch (_e) {
      return null;
    }
    if (inner.interpreter !== null && inner.interpreter !== shebang) return null;
    return { entry, interpreter: inner.interpreter || shebang || "bash", args: inner.args };
  }
  return null;
}

function usableConfigDir() {
  const dir = process.env.AGENTS_CONFIG_DIR;
  if (typeof dir !== "string" || dir.trim() === "") return null;
  return fs.statSync(dir).isDirectory() ? dir : null;
}

function lead(hit) {
  const names = hit && Array.isArray(hit.varNames) && hit.varNames.length > 0 ? hit.varNames.join(", ") : "a variable";
  return `Capture-then-display rejected: ${names} is assigned a command substitution and then only printed back, ` +
    "so the assignment adds nothing the command does not already print.";
}

const SCRATCHPAD_LINE =
  "Fall back to the standard procedure: put the command in a scratchpad script and invoke it as one " +
  "`bash <absolute-path>` call.";
const LABEL_LINE =
  "Decorative labels are for the reader, not the shell — write the label yourself rather than making the shell print it.";

function branchA(hit, match) {
  const args = Array.isArray(match.args) && match.args.length > 0 ? " " + match.args.join(" ") : "";
  return [
    lead(hit),
    `Reissue it as a single bare command: ${match.interpreter} "$AGENTS_CONFIG_DIR/${match.entry}"${args}`,
    LABEL_LINE,
    RULE_REF,
  ].join("\n");
}

function branchB(hit) {
  return [lead(hit), SCRATCHPAD_LINE, RULE_REF].join("\n");
}

function branchC(hit) {
  return [
    lead(hit),
    "When the inner command is a sanctioned entry point, reissue it as a single bare command; " + LABEL_LINE,
    SCRATCHPAD_LINE,
    RULE_REF,
  ].join("\n");
}

function buildRemedy(hit) {
  try {
    let configDir;
    let entries;
    try {
      configDir = usableConfigDir();
      entries = configDir === null ? null : readSsotEntries(configDir);
    } catch (_e) {
      return branchC(hit);
    }
    if (configDir === null || entries === null) return branchC(hit);

    const inner = resolveInner(hit && hit.innerCommandText);
    if (inner === null) return branchB(hit);
    const match = matchSsotEntry(inner, configDir, entries);
    return match === null ? branchB(hit) : branchA(hit, match);
  } catch (_e) {
    return branchC(hit);
  }
}

module.exports = { buildRemedy };
