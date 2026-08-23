"use strict";

// GH_REPO and GH_HOST decide where a bare `gh issue create` lands, so the guard
// has to see them the way the shell does — STRUCTURALLY. A command that merely
// contains the string "GH_REPO" (a grep, a commit message) assigns nothing, and
// treating it as an assignment would make the guard prompt on ordinary work.
// Only three shapes actually set the variable: an inline prefix, an `env`
// wrapper, and an `export`/`declare -x`/`typeset -x` that outlives the command.
// The first two die with their segment; the third is remembered for the session,
// which is why it — and only it — is written to disk.
const fs = require("fs");
const path = require("path");
const { ASSIGN_RE, commandBasename } = require("../lib/bash-write-patterns/segment-utils");
const { getWorkflowDir } = require("../workflow-state/state-io/core");
const { normalizeCwd } = require("../lib/path-normalize");

const GH_ENV_NAMES = ["GH_REPO", "GH_HOST"];
const SESSION_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;
const ENV_TTL_MS = 4 * 60 * 60 * 1000;

// The state dir is READ from the environment, never invented. An empty
// CLAUDE_WORKFLOW_DIR means "no state directory for this run", not "fall back to
// the developer's home" — a guard that writes into $HOME because a test or a
// sandbox blanked the variable has escaped the boundary it was given.
function stateDir() {
  const raw = process.env.CLAUDE_WORKFLOW_DIR;
  if (raw === undefined) {
    try { return normalizeCwd(getWorkflowDir()); } catch (_e) { return null; }
  }
  if (typeof raw !== "string" || raw.trim() === "") return null;
  return normalizeCwd(raw);
}

function sessionStatePath(sid, kind) {
  if (typeof sid !== "string" || !SESSION_ID_RE.test(sid)) return null;
  const dir = stateDir();
  if (!dir) return null;
  try {
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return null;
  } catch (_e) {
    return null;
  }
  return path.join(dir, sid + "." + kind);
}

function readJsonState(sid, kind) {
  const file = sessionStatePath(sid, kind);
  if (!file) return null;
  try {
    const raw = fs.readFileSync(file, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    return parsed;
  } catch (_e) {
    return null;
  }
}

// Atomic, and LOUD on failure: a half-written or unwritten record reads back as
// "nothing recorded", which silently forgets an auth change the next command
// would have been asked about. Only the path and the errno are reported — the
// record itself can carry auth state and never goes to a log.
function writeJsonState(sid, kind, value) {
  const file = sessionStatePath(sid, kind);
  if (!file) return false;
  // `<file>.tmp` exactly: that spelling is the one protected-basenames.js
  // guards, so the staged copy is no easier to forge than the real record.
  const tmp = file + ".tmp";
  try {
    try {
      fs.writeFileSync(tmp, JSON.stringify(value), { encoding: "utf8", flag: "wx", mode: 0o600 });
    } catch (e) {
      if (e && e.code === "EEXIST") {
        fs.unlinkSync(tmp);
        fs.writeFileSync(tmp, JSON.stringify(value), { encoding: "utf8", flag: "wx", mode: 0o600 });
      } else { throw e; }
    }
    fs.renameSync(tmp, file);
    return true;
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_u) { /* nothing to clean up */ }
    try {
      process.stderr.write(
        "confirm-forge-target-ownership: could not record " + kind + " state at " + file +
        " (" + ((e && e.code) || "write failed") + "); the next command will be re-asked\n"
      );
    } catch (_w) { /* stderr closed */ }
    return false;
  }
}

// Returns whether the record is GONE afterwards. "Already absent" counts as
// gone; a file that survives an unlink error does not — a stale record left on
// disk is a target the next invocation would still believe.
function removeState(sid, kind) {
  const file = sessionStatePath(sid, kind);
  if (!file) return true;
  try {
    fs.unlinkSync(file);
    return true;
  } catch (e) {
    if (e && e.code === "ENOENT") return true;
    try {
      process.stderr.write(
        "confirm-forge-target-ownership: could not clear " + kind + " state at " + file +
        " (" + ((e && e.code) || "unlink failed") + ")\n"
      );
    } catch (_w) { /* stderr closed */ }
    return false;
  }
}

function fresh(entry) {
  if (!entry || typeof entry !== "object") return false;
  const setAt = typeof entry.setAt === "number" ? entry.setAt : 0;
  return Date.now() - setAt < ENV_TTL_MS;
}

// The value of an assignment token, or null when it cannot be READ literally.
// Unreadable is a distinct answer from absent: `GH_REPO=$VAR` proves a target
// was chosen and proves the guard cannot say which one.
function assignmentValue(tok, rawTok) {
  if (typeof tok !== "string") return { name: null };
  const eq = tok.indexOf("=");
  if (eq <= 0) return { name: null };
  const name = tok.slice(0, eq);
  if (GH_ENV_NAMES.indexOf(name) === -1) return { name: null };
  const raw = typeof rawTok === "string" ? rawTok : tok;
  const rawEq = raw.indexOf("=");
  const rawValue = rawEq >= 0 ? raw.slice(rawEq + 1) : "";
  if (/[$`]/.test(rawValue)) return { name, value: null, readable: false };
  return { name, value: tok.slice(eq + 1), readable: true };
}

function pushSet(out, name, value, readable, persist) {
  out.sets.push({ name, value: readable ? value : null, readable, persist });
}

function inlinePrefixAssignments(seg, out) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : argv;
  const heads = [{ tok: seg.cmd0, raw: seg.cmd0Raw }];
  if (typeof seg.cmd0 === "string" && ASSIGN_RE.test(seg.cmd0)) {
    for (let i = 0; i < argv.length; i++) {
      if (!ASSIGN_RE.test(argv[i])) break;
      heads.push({ tok: argv[i], raw: argvRaw[i] });
    }
  }
  for (const h of heads) {
    if (typeof h.tok !== "string" || !ASSIGN_RE.test(h.tok)) continue;
    const a = assignmentValue(h.tok, h.raw);
    if (a.name) pushSet(out, a.name, a.value, a.readable, false);
  }
}

function envWrapperAssignments(seg, out) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : argv;
  if (commandBasename(seg.cmd0) !== "env") return;
  for (let i = 0; i < argv.length; i++) {
    const a = assignmentValue(argv[i], argvRaw[i]);
    if (a.name) pushSet(out, a.name, a.value, a.readable, false);
  }
}

function declarationAssignments(seg, out) {
  const head = commandBasename(seg.cmd0);
  if (head !== "export" && head !== "declare" && head !== "typeset" && head !== "unset") return;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : argv;
  const unsetting = head === "unset" || argv.indexOf("+x") !== -1;
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (typeof tok !== "string" || tok === "" || tok[0] === "-" || tok[0] === "+") continue;
    if (unsetting && GH_ENV_NAMES.indexOf(tok) !== -1) { out.unsets.push(tok); continue; }
    const a = assignmentValue(tok, argvRaw[i]);
    if (!a.name) continue;
    if (a.readable && a.value === "") { out.unsets.push(a.name); continue; }
    pushSet(out, a.name, a.value, a.readable, true);
  }
}

// Every GH_REPO / GH_HOST effect this ONE segment has.
function ghEnvOfSegment(seg) {
  const out = { sets: [], unsets: [] };
  if (!seg || typeof seg !== "object") return out;
  inlinePrefixAssignments(seg, out);
  envWrapperAssignments(seg, out);
  declarationAssignments(seg, out);
  return out;
}

function loadSessionGhEnv(sid) {
  const state = readJsonState(sid, "gh-env");
  const out = {};
  if (!state) return out;
  for (const name of GH_ENV_NAMES) {
    if (fresh(state[name])) out[name] = state[name];
  }
  return out;
}

// Returns { persisted, failed }. The two are NOT complements. `failed: true` is
// the case the caller must react to: the exported GH_REPO / GH_HOST did not land,
// so a later bare `gh issue create` resolves from the checkout while gh follows
// the override the guard forgot. Having no state directory reaches that same end
// by another road, so it fails on the same terms: whenever there was a value to
// remember. Only "nothing to record" is `persisted: false, failed: false` —
// nothing attempted, nothing lost.
function saveSessionGhEnv(sid, record) {
  const clean = {};
  for (const name of GH_ENV_NAMES) {
    if (record && record[name]) clean[name] = record[name];
  }
  if (sessionStatePath(sid, "gh-env") === null) {
    return { persisted: false, failed: Object.keys(clean).length > 0 };
  }
  const ok = Object.keys(clean).length === 0
    ? removeState(sid, "gh-env")
    : writeJsonState(sid, "gh-env", clean);
  return { persisted: ok, failed: !ok };
}

module.exports = {
  GH_ENV_NAMES,
  SESSION_ID_RE,
  ghEnvOfSegment,
  loadSessionGhEnv,
  saveSessionGhEnv,
  sessionStatePath,
  readJsonState,
  writeJsonState,
  removeState,
  stateDir,
};
