"use strict";
// hooks/lib/bash-write-targets/detection-expand.js
// Detection-direction expansion of one shell word (#2417, #2434 D7a): resolves the
// HOME / workflow-dir / plans-dir aliases a write target can be spelled with, so a
// guard sees the real path. It never approves anything; the allow direction keeps
// expandStaticShellTokens. Result: { path, aliasRef, aliasUnresolved, dynamicTail, tail }.
const path = require("path");
const { expandStaticShellTokens } = require("./helpers");

const DEFAULT_OPS = new Set([":-", "-", ":=", "="]);
const OP_RE = /^(?::-|:=|:\+|:\?|-|=|\+|\?|%%|%|##|#|\/\/|\/|\^\^|\^|,,|,|:)/;
const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*/;

// Bash expands $HOME from the environment; os.homedir() differs from it on Windows.
function homeValue() {
  const env = process.env.HOME;
  if (env && path.isAbsolute(env)) return env.replace(/\\/g, "/");
  return expandStaticShellTokens("~");
}

const KNOWN_ALIASES = {
  HOME: homeValue,
  WORKFLOW_STATE_DIR: () => require("../../workflow-state/state-io/core").getWorkflowDir(),
  WORKFLOW_PLANS_DIR: () => require("../workflow-plans-dir").getWorkflowPlansDir(),
};

function unquote(tok) {
  if (tok.length >= 2 && tok[0] === "'" && tok[tok.length - 1] === "'" && !tok.slice(1, -1).includes("'")) {
    return { text: tok.slice(1, -1), literal: true };
  }
  return { text: tok.replace(/["']/g, ""), literal: false };
}

// One `$NAME` / `${NAME<op><arg>}` reference starting at s[i] === "$", or null.
function readRef(s, i) {
  if (s[i + 1] !== "{") {
    const m = NAME_RE.exec(s.slice(i + 1));
    return m ? { name: m[0], op: "", arg: "", end: i + 1 + m[0].length } : null;
  }
  let depth = 1;
  let j = i + 2;
  for (; j < s.length && depth > 0; j++) {
    if (s[j] === "{" && s[j - 1] === "$") depth++;
    else if (s[j] === "}") depth--;
  }
  if (depth !== 0) return null;
  const inner = s.slice(i + 2, j - 1);
  const m = NAME_RE.exec(inner);
  if (!m) return null;
  const rest = inner.slice(m[0].length);
  const om = OP_RE.exec(rest);
  if (rest.length > 0 && !om) return null;
  return { name: m[0], op: om ? om[0] : "", arg: om ? rest.slice(om[0].length) : "", end: j };
}

function staticDefault(arg) {
  if (!/[$~`]/.test(arg)) return arg;
  return expandStaticShellTokens(arg, { fromQuotedContext: "unquoted" });
}

// { value } resolved, { value: null } dynamic, { unresolved: true } a known alias we cannot place.
function resolveRef(ref) {
  const resolver = KNOWN_ALIASES[ref.name];
  if (!resolver) {
    const env = process.env[ref.name];
    return { value: !ref.op && env ? env : null };
  }
  const viaResolver = () => {
    try {
      const v = resolver();
      return v ? { value: v } : { unresolved: true };
    } catch (_) {
      return { unresolved: true };
    }
  };
  if (!ref.op) return viaResolver();
  if (!DEFAULT_OPS.has(ref.op)) return { unresolved: true };
  if (process.env[ref.name]) return viaResolver();
  const d = staticDefault(ref.arg);
  return d === null ? { unresolved: true } : { value: d };
}

function expandForDetection(token, _opts) {
  const out = { path: null, aliasRef: null, aliasUnresolved: false, dynamicTail: false, tail: "" };
  if (typeof token !== "string" || token === "") return out;
  const { text: s, literal } = unquote(token);
  if (literal) { out.path = s; return out; }
  let acc = "";
  let i = 0;
  if (s === "~" || s.startsWith("~/") || s.startsWith("~\\")) {
    acc = homeValue();
    out.aliasRef = "HOME";
    i = 1;
  }
  while (i < s.length) {
    const ch = s[i];
    if (ch === "`" || s.startsWith("$(", i)) { out.dynamicTail = true; break; }
    if (ch !== "$") { acc += ch; i++; continue; }
    const ref = readRef(s, i);
    if (!ref) {
      // `${#ALIAS}` or an unterminated `${ALIAS…` still names a known alias we cannot place.
      const peek = /^\$\{#?([A-Za-z_][A-Za-z0-9_]*)/.exec(s.slice(i));
      if (peek && KNOWN_ALIASES[peek[1]]) {
        out.aliasUnresolved = true;
        if (!out.aliasRef) out.aliasRef = peek[1];
        out.tail = s.slice(i);
      }
      out.dynamicTail = true;
      break;
    }
    const r = resolveRef(ref);
    if (KNOWN_ALIASES[ref.name] && !out.aliasRef) out.aliasRef = ref.name;
    if (r.unresolved) { out.aliasUnresolved = true; out.tail = s.slice(ref.end); break; }
    if (r.value === null) { out.dynamicTail = true; break; }
    acc += r.value;
    i = ref.end;
  }
  out.path = acc;
  return out;
}

module.exports = { expandForDetection, KNOWN_ALIASES: Object.freeze(Object.keys(KNOWN_ALIASES)) };
