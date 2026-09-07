"use strict";

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
} = require("../bash-write-patterns/segment-utils");

// cmd.exe internal delete verbs that accept the recursive /s switch (#2210).
const CMD_DELETE_VERBS = new Set(["rmdir", "rd", "del"]);
// Same verbs at a clause head, optionally with a switch glued on (`rd/s`).
const CMD_DELETE_VERB_RE = new RegExp("^(?:" + [...CMD_DELETE_VERBS].join("|") + ")(/.*)?$", "i");

// cmd.exe reserves `/` for switches (`rd/s`), so the generic commandBasename()
// — which also splits on `/` as a path separator — would read "rd/s" as
// directory "rd", file "s" and misclassify a plain builtin as foreign. This
// normalizer strips only a backslash-delimited directory prefix and a
// trailing `.exe`, so `C:\Windows\System32\rd.exe/s` still reads as `rd/s`.
// Without it, `rd.exe /s dir` matched neither CMD_DELETE_VERB_RE (which only
// recognizes the bare verb) nor foreignClauseBlocks's builtin set (whose
// commandBasename-normalized `rd` incorrectly marks it as an already-covered
// builtin), so the whole clause silently approved (#2210 round8 N5).
function cmdVerbBasename(tok) {
  if (typeof tok !== "string") return tok;
  const base = tok.split("\\").pop();
  return base.replace(/\.exe(?=$|\/)/i, "");
}

// cmd.exe's own vocabulary. A clause head OUTSIDE it launches another program,
// whose recursion cmd.exe's switch table can say nothing about — see
// foreignClauseBlocks below. Kept deliberately wide: a name wrongly listed here
// only skips the extra scan, so anything uncertain is left off.
const CMD_BUILTIN_VERBS = new Set([
  ...CMD_DELETE_VERBS, "cmd", "call", "start", "echo", "set", "setlocal", "endlocal",
  "cd", "chdir", "pushd", "popd", "dir", "copy", "xcopy", "move", "ren", "rename",
  "type", "mkdir", "md", "for", "goto", "exit", "pause", "rem", "title", "cls",
  "ver", "vol", "verify", "path", "prompt", "assoc", "ftype", "date", "time",
  "color", "break", "shift", "attrib", "find", "findstr", "more", "sort", "tree",
]);

/**
 * tokenizeCmdClause(text) — split ONE cmd.exe clause into tokens.
 * cmd.exe quoting is not bash quoting: `"` is the only quote character and
 * there is no backslash escape, so bash's tokenizer must not be reused here.
 * `^` escapes are a documented non-goal (detail.md Step 3 / Out of scope).
 */
function tokenizeCmdClause(text) {
  const out = [];
  let cur = "";
  let started = false;
  let inQuote = false;
  for (const ch of text) {
    if (ch === '"') { inQuote = !inQuote; started = true; continue; }
    if (!inQuote && /\s/.test(ch)) {
      if (started) { out.push(cur); cur = ""; started = false; }
      continue;
    }
    cur += ch;
    started = true;
  }
  if (started) out.push(cur);
  return out;
}

// Nesting budget for `cmd /c cmd /c ...`; past it the payload fails closed.
const MAX_CMD_NEST = 8;

// A `/`-leading token can CLUSTER several switches (e.g. "/s" + "/q" glued
// together), so an exact `/s` compare missed them (#2210 round-4 C2).
// The glued form splits into ["/s", "/q"].
function splitCmdSwitches(tok) {
  return tok.split("/").filter((p) => p !== "").map((p) => "/" + p);
}

// The text cmd.exe would run: everything after the `/c` / `/k` switch. Matched
// by PREFIX because the outer bash tokenizer glues `/c"rd /s dir"` into one token.
function cmdPayloadFrom(toks) {
  const idx = toks.findIndex((t) => typeof t === "string" && /^\/[ck]/i.test(t));
  if (idx === -1) return null;
  const fragments = [];
  if (toks[idx].length > 2) fragments.push(toks[idx].slice(2));
  for (let i = idx + 1; i < toks.length; i++) fragments.push(String(toks[i]));
  return fragments.join(" ");
}

// One clause's verdict: true = a delete verb carries an independent `/s`;
// null = a `/`-leading switch carries `%VAR%` / `!VAR!` that could expand to it.
// The verb may have its switch GLUED to it (`rd/s`), which the whitespace-only
// tokenizer keeps in one token. A bare (non-`/`-leading) token is always
// TARGET/verb position, never a switch — cmd.exe reserves `/` to introduce
// one, so a bare token is left approved even when it is wholly `%VAR%`/`!VAR!`
// (round-3 review: the round-4 bare-token rule this replaced over-blocked
// `rd %F% dir` / `rd dir !F!`, #2210 round9).
function clauseVerdict(toks) {
  const m = CMD_DELETE_VERB_RE.exec(cmdVerbBasename(toks[0]));
  if (!m) return false;
  const rest = m[1] ? [m[1], ...toks.slice(1)] : toks.slice(1);
  let sawUnresolvable = false;
  for (const tok of rest) {
    if (typeof tok !== "string" || !tok.startsWith("/")) continue;
    for (const sw of splitCmdSwitches(tok)) {
      if (sw.toLowerCase() === "/s") return true;
      if (sw.includes("%") || sw.includes("!")) sawUnresolvable = true;
    }
  }
  return sawUnresolvable ? null : false;
}

// `if`'s condition has a fixed shape — `[/i] [not] exist PATH`, `... defined
// NAME`, `... errorlevel N`, or a `a==b` comparison the tokenizer may deliver as
// one token or as three. Consuming it leaves the conditional's BODY, which is
// where the real command sits.
function stripIfCondition(toks) {
  let i = 0;
  while (i < toks.length && typeof toks[i] === "string" &&
         (toks[i].toLowerCase() === "not" || toks[i].startsWith("/"))) i += 1;
  const kw = typeof toks[i] === "string" ? toks[i].toLowerCase() : "";
  if (kw === "exist" || kw === "defined" || kw === "errorlevel" || kw === "cmdextversion") {
    return toks.slice(i + 2);
  }
  return toks.slice(toks[i + 1] === "==" ? i + 3 : i + 1);
}

// `@` (echo suppression) and `if`/`else` sit AHEAD of the verb, so reading
// toks[0] saw `@rd` or `if` where the real command was `rd` — both approved
// (#2210 round-6). Stripped before any verdict is taken.
function stripClausePrefixes(toks) {
  let out = toks;
  for (let depth = 0; depth < 8 && out.length > 0; depth++) {
    const head = out[0];
    if (typeof head !== "string" || head === "") break;
    if (head === "@") { out = out.slice(1); continue; }
    if (head.startsWith("@")) { out = [head.slice(1), ...out.slice(1)]; continue; }
    const low = head.toLowerCase();
    if (low === "else") { out = out.slice(1); continue; }
    if (low === "if") { out = stripIfCondition(out.slice(1)); continue; }
    break;
  }
  return out;
}

// A clause whose head is no cmd.exe builtin launches ANOTHER program, and
// cmd.exe's switch table says nothing about how that one spells recursion:
// `cmd /c "pwsh -Command Remove-Item -Recurse d"` hid a whole PowerShell delete
// behind a cmd head (#2210 round-6). Hand the clause back to the top-level
// dispatcher so every other net judges it. The require is lazy because
// recursive-delete-scan.js requires THIS module — a top-level one closes the cycle.
function foreignClauseBlocks(toks, depth) {
  // Normalized the same way as clauseVerdict (#2210 security-scanner C29) —
  // commandBasename() alone splits on `/` as a path separator, so a
  // path-qualified verb (`C:\Windows\System32\rd.exe`) or a glued switch
  // (`rd.exe/s`) could read as builtin under one normalizer and foreign
  // under the other, letting the clause slip past whichever check disagreed.
  const base = cmdVerbBasename(toks[0]).toLowerCase().split("/")[0];
  if (base === null || base === "" || CMD_BUILTIN_VERBS.has(base)) return false;
  const { scanCommandTextForRecursiveDelete } = require("./recursive-delete-scan");
  return scanCommandTextForRecursiveDelete(toks.join(" "), depth + 1) === true;
}

// `call CMD` and `start [/wait] [/b] ["TITLE"] CMD` both run CMD inside the SAME
// clause, so a verb check on toks[0] alone never sees it (#2210 round-5) — and
// neither does the nested-`cmd` check below. Their own switches are `/`-leading
// but `start`'s optional TITLE is an ordinary word, indistinguishable from the
// command once quotes are gone, so every suffix position is offered as its own
// candidate clause instead of guessing where CMD starts. Scoped to clauses that
// actually BEGIN with a launcher verb, so no ordinary clause gains candidates.
const CMD_LAUNCHER_VERBS = new Set(["call", "start"]);

// Bounds the launcher fan-out (#2210 N1): each candidate triggers a full
// foreignClauseBlocks rescan, so an unbounded N candidates over an N-token
// clause was O(N^2). Past this cap, fail closed instead of continuing to scan.
// Intentional precision/performance tradeoff: a pathological-length launcher
// clause is DENIED outright rather than analyzed, benign content included.
const MAX_CLAUSE_CANDIDATES = 32;

function clauseCandidates(toks) {
  const candidates = [toks];
  if (!CMD_LAUNCHER_VERBS.has(commandBasename(toks[0]))) return { candidates, overflow: false };
  for (let i = 1; i < toks.length; i++) {
    const tok = toks[i];
    if (typeof tok !== "string" || tok === "" || tok.startsWith("/")) continue;
    if (candidates.length >= MAX_CLAUSE_CANDIDATES) return { candidates, overflow: true };
    candidates.push(toks.slice(i));
  }
  return { candidates, overflow: false };
}

// A `/`-leading switch position treats BOTH `%VAR%` (always-on expansion) and
// `!VAR!` (delayed expansion) as unresolvable, since either can carry `/s`.
const DYNAMIC_VAR_RE = /%[^%\s]+%|![^!\s]+!/;

// A clause HEAD is different: cmd.exe substitutes `%VAR%` at PARSE time, once,
// before any command on the line runs — so `set CMD=rd& %CMD% /s dir` still
// expands `%CMD%` to whatever it was BEFORE this line, never to "rd" (that
// same-line set-then-use only works via delayed expansion). A head is
// therefore fail-closed only for `!VAR!` (`setlocal enabledelayedexpansion` /
// `cmd /v:on`), which resolves per-command and CAN pick up a same-line `set`
// (`cmd /v:on /c "set CMD=rd& !CMD! /s dir"`, #2210 round8 item 8 / round9 C4).
// Neither clauseVerdict nor foreignClauseBlocks can judge such a head safely.
const DELAYED_VAR_RE = /![^!\s]+!/;

function hasDynamicHead(tok) {
  return typeof tok === "string" && DELAYED_VAR_RE.test(tok);
}

// Scan one cmd.exe payload's clauses, recursing into a nested `cmd /c ...`.
function scanCmdExeText(innerText, depth) {
  if (depth > MAX_CMD_NEST) return true;
  let sawUnresolvable = false;
  for (const clause of innerText.split(/\s*(?:&&|\|\||&|\|)\s*/)) {
    const toks = stripClausePrefixes(tokenizeCmdClause(clause));
    if (toks.length === 0) continue;
    const { candidates, overflow } = clauseCandidates(toks);
    if (overflow) return true;
    for (const cand of candidates) {
      if (hasDynamicHead(cand[0])) { sawUnresolvable = true; continue; }
      const nested = commandBasename(cand[0]) === "cmd" ? cmdPayloadFrom(cand.slice(1)) : null;
      const verdict = nested === null ? clauseVerdict(cand) : scanCmdExeText(nested, depth + 1);
      if (verdict === true) return true;
      if (verdict === null) sawUnresolvable = true;
      if (nested === null && foreignClauseBlocks(cand, depth)) return true;
    }
  }
  return sawUnresolvable ? null : false;
}

/**
 * hasRecursiveCmdExeFlag(seg) — does this `cmd /c ...` payload delete recursively?
 * true = a rmdir/rd/del clause carries an independent `/s`; null = the payload
 * cannot be resolved statically (shell expansion, or a `/`-leading flag-position
 * token carrying `%VAR%` / `!VAR!` that could expand to `/s`); false otherwise.
 * Contract: detail.md Step 3.
 */
function hasRecursiveCmdExeFlag(seg) {
  if (!seg) return false;
  if (commandBasename(resolveEffectiveCommand(seg)) !== "cmd") return false;

  const innerText = cmdPayloadFrom(resolveEffectiveArgv(seg));
  if (innerText === null) return false;
  if (/[$`(]/.test(innerText)) return null;
  return scanCmdExeText(innerText, 0);
}

module.exports = { hasRecursiveCmdExeFlag };
