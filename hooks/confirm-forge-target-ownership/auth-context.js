"use strict";

// Ownership is proven against WHOEVER gh authenticates as. So a command that
// changes the acting identity invalidates the question itself: proving that the
// current login owns a repo says nothing about the login the next command will
// use. The guard therefore refuses to probe at all once the auth context is in
// motion — probing would spend the budget on an answer about the wrong identity
// and, worse, could report it as proof. GH_HOST is deliberately NOT here: it
// changes the FORGE, not the identity, and is handled by the host gate.
const { ASSIGN_RE, WRAPPER_SPECS, commandBasename, isAttachedShortValue } = require("../lib/bash-write-patterns/segment-utils");
const { readJsonState, writeJsonState, removeState, sessionStatePath } = require("./gh-env-state");

const AUTH_VAR_RE = /^(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|GH_CONFIG_DIR)$/;
const AUTH_FP_VARS = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];
const DIRTY_TTL_MS = 4 * 60 * 60 * 1000;
const MAX_ENV_CHAIN = 16;

function assignName(tok) {
  if (typeof tok !== "string") return null;
  const eq = tok.indexOf("=");
  return eq > 0 ? tok.slice(0, eq) : null;
}

function stripAssignments(cmd0, argv) {
  let head = cmd0;
  let rest = Array.isArray(argv) ? argv.slice() : [];
  while (typeof head === "string" && ASSIGN_RE.test(head) && rest.length > 0) head = rest.shift();
  return { head, rest };
}

// Every auth-relevant option on a chain of `env` wrappers. `-C DIR` changes the
// directory, not the identity, so it deliberately produces no tag.
function envAuthOptions(seg) {
  const tags = [];
  if (!seg || typeof seg !== "object") return tags;
  const spec = WRAPPER_SPECS.env;
  let { head, rest } = stripAssignments(seg.cmd0, seg.argv);
  for (let depth = 0; depth < MAX_ENV_CHAIN; depth++) {
    if (commandBasename(head) !== "env") break;
    let i = 0;
    while (i < rest.length) {
      const tok = rest[i];
      if (typeof tok !== "string") { tags.push("env-ambiguous"); i += 1; continue; }
      if (ASSIGN_RE.test(tok)) {
        const name = assignName(tok);
        if (AUTH_VAR_RE.test(name || "")) tags.push("env-assign:" + name);
        i += 1;
        continue;
      }
      if (tok === "--") { i += 1; break; }
      if (tok === "" || tok[0] !== "-") break;
      if (tok === "-" || tok === "-i" || tok === "--ignore-environment") { tags.push("env-clear"); i += 1; continue; }
      if (tok === "-S" || tok === "--split-string") { tags.push("env-split-string"); i += 2; continue; }
      if (tok.indexOf("--split-string=") === 0) { tags.push("env-split-string"); i += 1; continue; }
      if (tok === "-u" || tok === "--unset") {
        const name = rest[i + 1];
        if (AUTH_VAR_RE.test(typeof name === "string" ? name : "")) tags.push("env-unset:" + name);
        i += 2;
        continue;
      }
      if (tok.indexOf("--unset=") === 0) {
        const name = tok.slice("--unset=".length);
        if (AUTH_VAR_RE.test(name)) tags.push("env-unset:" + name);
        i += 1;
        continue;
      }
      if (tok.indexOf("-u") === 0 && tok.length > 2) {
        const name = tok.slice(2);
        if (AUTH_VAR_RE.test(name)) tags.push("env-unset:" + name);
        i += 1;
        continue;
      }
      if (spec.valueFlags.has(tok)) { i += 2; continue; }
      if (spec.booleanFlags.has(tok)) { i += 1; continue; }
      if (tok.indexOf("=") !== -1) { i += 1; continue; }
      if (isAttachedShortValue(tok, spec)) { i += 1; continue; }
      tags.push("env-ambiguous");
      i += 1;
    }
    if (i >= rest.length) break;
    head = rest[i];
    rest = rest.slice(i + 1);
  }
  return tags;
}

function ghSubWordsShallow(argv) {
  const words = [];
  for (const tok of Array.isArray(argv) ? argv : []) {
    if (typeof tok !== "string" || tok === "") continue;
    if (tok[0] === "-") continue;
    words.push(tok);
    if (words.length >= 3) break;
  }
  return words;
}

// The auth-context effects of ONE segment, split by how long they last.
// `segment` causes die with the command (an inline prefix, an `env` wrapper);
// `persistent` causes outlive it and are remembered for the session.
function authCausesOfSegment(seg) {
  const out = { segment: [], persistent: [], releases: [] };
  if (!seg || typeof seg !== "object") return out;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  if (typeof seg.cmd0 === "string" && ASSIGN_RE.test(seg.cmd0)) {
    const heads = [seg.cmd0].concat(argv.filter((t) => typeof t === "string" && ASSIGN_RE.test(t)));
    for (const tok of heads) {
      const name = assignName(tok);
      if (AUTH_VAR_RE.test(name || "")) out.segment.push("env-assign:" + name);
    }
  }
  for (const tag of envAuthOptions(seg)) out.segment.push(tag);
  const { head, rest } = stripAssignments(seg.cmd0, argv);
  const name = commandBasename(head);
  if (name === "gh") {
    const words = ghSubWordsShallow(rest);
    if (words[0] === "auth") out.persistent.push("gh-auth");
    if (words[0] === "config" && words[1] === "set") out.persistent.push("gh-config");
  } else if (name === "git") {
    if (ghSubWordsShallow(rest)[0] === "credential") out.persistent.push("git-credential");
  } else if (name === "source" || name === "." || head === ".") {
    out.persistent.push("source");
  } else if (name === "export" || name === "declare" || name === "typeset" || name === "unset") {
    const unsetting = name === "unset" || rest.indexOf("+x") !== -1;
    for (const tok of rest) {
      if (typeof tok !== "string" || tok === "" || tok[0] === "-" || tok[0] === "+") continue;
      const varName = assignName(tok) || tok;
      if (!AUTH_VAR_RE.test(varName)) continue;
      const eq = tok.indexOf("=");
      if (unsetting || (eq > 0 && tok.slice(eq + 1) === "")) out.releases.push("env-assign:" + varName);
      else out.persistent.push("env-assign:" + varName);
    }
  }
  return out;
}

function isAuthMutating(seg) {
  const causes = authCausesOfSegment(seg);
  return causes.segment.length > 0 || causes.persistent.length > 0;
}

function loadDirty(sid) {
  const state = readJsonState(sid, "gh-auth-dirty");
  if (!state || !Array.isArray(state.causes)) return [];
  const setAt = typeof state.setAt === "number" ? state.setAt : 0;
  if (Date.now() - setAt >= DIRTY_TTL_MS) return [];
  return state.causes.filter((c) => typeof c === "string");
}

// Only the CAUSE is recorded — never a token value, never command text. The
// state dir is readable by anything running as the user (OWASP ASVS V8).
// Returns { persisted, failed } like saveSessionGhEnv, and for the same reason:
// a dirty record that does not land reads back as "auth never moved", and the
// next invocation would prove ownership against a login that no longer acts.
// No state dir at all is `failed: false` — nothing was attempted, and every
// invocation re-asks by construction.
function saveDirty(sid, causes) {
  const unique = [];
  for (const c of causes) if (typeof c === "string" && unique.indexOf(c) === -1) unique.push(c);
  if (sessionStatePath(sid, "gh-auth-dirty") === null) return { persisted: false, failed: false };
  const ok = unique.length === 0
    ? removeState(sid, "gh-auth-dirty")
    : writeJsonState(sid, "gh-auth-dirty", { causes: unique, setAt: Date.now() });
  return { persisted: ok, failed: !ok };
}

module.exports = {
  AUTH_VAR_RE,
  AUTH_FP_VARS,
  envAuthOptions,
  authCausesOfSegment,
  isAuthMutating,
  loadDirty,
  saveDirty,
};
