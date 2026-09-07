"use strict";

const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
} = require("../bash-write-patterns/segment-utils");

// cmd.exe internal delete verbs that accept the recursive `/s` switch.
const CMD_DELETE_VERBS = new Set(["rmdir", "rd", "del"]);
// Same verbs at a clause head, optionally with a switch glued on (`rd/s`).
const CMD_DELETE_VERB_RE = new RegExp("^(?:" + [...CMD_DELETE_VERBS].join("|") + ")(/.*)?$", "i");

// commandBasename() splits on `/` as a path separator, so it reads `rd/s` as
// dir "rd" + file "s" and `rd.exe /s dir` slipped through as a covered builtin.
function cmdVerbBasename(tok) {
  if (typeof tok !== "string") return tok;
  const base = tok.split("\\").pop();
  return base.replace(/\.exe(?=$|\/)/i, "");
}

// A head outside this vocabulary launches another program — see
// foreignClauseBlocks. Listing a name here only skips that scan, so keep it tight.
const CMD_BUILTIN_VERBS = new Set([
  ...CMD_DELETE_VERBS, "cmd", "call", "start", "echo", "set", "setlocal", "endlocal",
  "cd", "chdir", "pushd", "popd", "dir", "copy", "xcopy", "move", "ren", "rename",
  "type", "mkdir", "md", "for", "goto", "exit", "pause", "rem", "title", "cls",
  "ver", "vol", "verify", "path", "prompt", "assoc", "ftype", "date", "time",
  "color", "break", "shift", "attrib", "find", "findstr", "more", "sort", "tree",
]);

// cmd.exe quoting is not bash quoting: `"` is the only quote and there is no
// backslash escape, so bash's tokenizer must not be reused. `^` escapes: non-goal.
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

// A `/`-leading token can cluster several switches glued together, which an
// exact `/s` compare missed.
function splitCmdSwitches(tok) {
  return tok.split("/").filter((p) => p !== "").map((p) => "/" + p);
}

// Matched by PREFIX: the outer bash tokenizer can glue the switch and its
// quoted payload into a single token.
function cmdPayloadFrom(toks) {
  const idx = toks.findIndex((t) => typeof t === "string" && /^\/[ck]/i.test(t));
  if (idx === -1) return null;
  const fragments = [];
  if (toks[idx].length > 2) fragments.push(toks[idx].slice(2));
  for (let i = idx + 1; i < toks.length; i++) fragments.push(String(toks[i]));
  return fragments.join(" ");
}

// true = a delete verb carries an independent `/s`; null = a `/`-leading switch
// carries `%VAR%` or `!VAR!` that could expand to it. A bare token is never a
// switch (cmd.exe reserves `/` for those), so judging those over-blocked `rd %F% dir`.
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

// Consume `if`'s fixed-shape condition to reach the BODY, where the real command
// sits. An `a==b` comparison may arrive as one token or as three.
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

// `@` and `if`/`else` sit AHEAD of the verb, so toks[0] read `@rd` or `if` and
// approved the clause.
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

// A non-builtin head launches another program whose recursion spelling cmd.exe
// knows nothing about, so hand the clause back to the top-level dispatcher. The
// require is lazy: recursive-delete-scan.js requires THIS module.
function foreignClauseBlocks(toks, depth) {
  // Same normalizer as clauseVerdict — disagreeing ones let a path-qualified or
  // glued-switch verb read builtin here and foreign there, and slip past both.
  const base = cmdVerbBasename(toks[0]).toLowerCase().split("/")[0];
  if (base === null || base === "" || CMD_BUILTIN_VERBS.has(base)) return false;
  const { scanCommandTextForRecursiveDelete } = require("./recursive-delete-scan");
  return scanCommandTextForRecursiveDelete(toks.join(" "), depth + 1) === true;
}

// `call CMD` and `start [/wait] [/b] ["TITLE"] CMD` run CMD inside the SAME clause,
// which a toks[0] verb check never sees. `start`'s optional TITLE is an ordinary
// word once quotes are gone, so every suffix position becomes its own candidate
// rather than guessing where CMD starts.
const CMD_LAUNCHER_VERBS = new Set(["call", "start"]);

// Each candidate triggers a full foreignClauseBlocks rescan, so an unbounded
// candidate list was O(N^2). Past the cap a launcher clause is DENIED outright.
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

// A HEAD is fail-closed only for `!VAR!`: cmd.exe substitutes `%VAR%` once at
// PARSE time, so `set CMD=rd& %CMD% ...` cannot pick up its own same-line `set`,
// while delayed expansion resolves per-command and can.
const DELAYED_VAR_RE = /![^!\s]+!/;

function hasDynamicHead(tok) {
  return typeof tok === "string" && DELAYED_VAR_RE.test(tok);
}

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

// Three-valued: true = the payload deletes recursively; null = it cannot be
// resolved statically, so the caller fails closed. Contract: detail.md Step 3.
function hasRecursiveCmdExeFlag(seg) {
  if (!seg) return false;
  if (commandBasename(resolveEffectiveCommand(seg)) !== "cmd") return false;

  const innerText = cmdPayloadFrom(resolveEffectiveArgv(seg));
  if (innerText === null) return false;
  if (/[$`(]/.test(innerText)) return null;
  return scanCmdExeText(innerText, 0);
}

module.exports = { hasRecursiveCmdExeFlag };
