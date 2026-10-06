"use strict";

// Per-file isolation facts and the violation rules (#2512 stage 4).
// A permanent pin is a top-level `export WORKFLOW_STATE_DIR` (or plans) or a
// top-level harness_isolate call; an inline pin is the assignment on an exec line.
// The first exec line E counts a function body at its definition line.

const CMD = "(?:^|[\\s;&|(`{!])";
const EXEC_RES = [
  new RegExp(CMD + "node\\s[\\s\\S]*?\\b(?:hooks|bin)/"),
  new RegExp(CMD + "node\\s+(?:-{1,2}[\\w-]+\\s+)*\"?\\$\\{?[A-Za-z0-9_]*(?:HOOK|BIN|SCRIPT)[A-Za-z0-9_]*", "i"),
  new RegExp(CMD + "bash\\s+(?:-\\S+\\s+)*[\"']?[^\\s\"']*\\bbin/"),
];
const VAR_TAIL = "(?=[=\\s;&|)]|$)";
const exportRe = (name) => new RegExp(CMD + "export\\s+(?:[^;&|]*?\\s)?" + name + VAR_TAIL);
const PIN_RES = { state: exportRe("WORKFLOW_STATE_DIR"), plans: exportRe("WORKFLOW_PLANS_DIR") };
const HARNESS_RE = new RegExp(CMD + "harness_isolate(?=\\s|;|$)(?!\\s*\\(\\s*\\))");
const INLINE_STATE_RE = /(?:^|[\s;&|(`])WORKFLOW_STATE_DIR=/;
const SUPERVISOR_EMIT_RE = /workflow-gate|workflow-mark|supervisor-emit|reportSentinel|reportBlock|reportFallback|reportRetrospective/;

// position(line, idx) — ordering key inside a file.
const pos = (line, idx) => ({ line, idx });
const before = (a, b) => a.line < b.line || (a.line === b.line && a.idx < b.idx);

function firstMatch(res, s) {
  let best = -1;
  for (const re of res) {
    const m = re.exec(s);
    if (m && (best < 0 || m.index < best)) best = m.index;
  }
  return best;
}

// firstExec(text, code) → index of the first exec signal whose command word is code,
// not quoted text (`echo "run: bash bin/x"` is no exec). Arguments match on `text`
// so a quoted `"$BIN/x"` still counts.
function firstExec(text, code) {
  let best = -1;
  for (const re of EXEC_RES) {
    const g = new RegExp(re.source, re.flags + "g");
    let m;
    while ((m = g.exec(text)) !== null) {
      const k = m.index + m[0].search(/node|bash/i);
      if (code.slice(k, k + 4) === text.slice(k, k + 4)) {
        if (best < 0 || m.index < best) best = m.index;
        break;
      }
      g.lastIndex = m.index + 1;
    }
  }
  return best;
}

// execPos(l) → position of the first exec signal on logical line l, or null.
function execPos(l) {
  if (l.heredoc || l.comment) return null;
  const idx = firstExec(l.text, l.execCode);
  if (idx < 0) return null;
  return l.fnStart !== null ? pos(l.fnStart, -1) : pos(l.line, idx);
}

// pinPos(l, kind) → position of a permanent pin of kind on line l, or null.
function pinPos(l, kind) {
  if (l.heredoc || l.comment || l.inString || l.fnStart !== null) return null;
  const idx = firstMatch([PIN_RES[kind], HARNESS_RE], l.code);
  return idx < 0 ? null : pos(l.line, idx);
}

// analyze(lines, text) → { exec, own: { state, plans }, inlineState, emit }.
function analyze(lines, text) {
  const facts = { exec: null, own: { state: null, plans: null }, inlineState: false, emit: SUPERVISOR_EMIT_RE.test(text) };
  for (const l of lines) {
    const e = execPos(l);
    if (e) {
      if (!facts.exec || before(e, facts.exec)) facts.exec = e;
      if (INLINE_STATE_RE.test(l.text)) facts.inlineState = true;
    }
    for (const kind of ["state", "plans"]) {
      const p = pinPos(l, kind);
      if (p && (!facts.own[kind] || before(p, facts.own[kind]))) facts.own[kind] = p;
    }
  }
  return facts;
}

// verdict(rel, facts, pinAt) → output lines. pinAt(kind) folds in inheritance.
function verdict(rel, facts, pinAt) {
  const E = facts.exec;
  if (!E) return [];
  const state = pinAt("state");
  const plans = pinAt("plans");
  if (!state) {
    if (plans) return [`HALF-PIN-REVERSE: ${rel}`];
    return [facts.inlineState ? `STATE-INLINE-ONLY: ${rel}` : `STATE-UNPINNED: ${rel}`];
  }
  if (!before(state, E)) return [`STATE-PIN-LATE: ${rel}:${E.line}`];
  if (!plans) return [facts.emit ? `W-candidate: ${rel}` : `N-candidate: ${rel}`];
  if (!before(plans, E)) return [`STATE-PIN-LATE: ${rel}:${E.line} plans`];
  return [];
}

const isViolation = (line) => !line.startsWith("N-candidate:");

module.exports = { analyze, verdict, before, pos, isViolation };
