"use strict";
// Extracts the destination output path from a shell command that invokes
// skills/_shared/assemble-mandatory.sh. Returns the resolved 3rd positional
// after any optional --source-kind switch, or null when the command does not
// execute the script (a mere argument, e.g. `cat` of it, does not count).
//
// Backslash line continuation: SKILL.md authors split the invocation across
// 4 lines using POSIX `\<newline>` continuation. Claude Code may record the
// command either as the literal multi-line string (preserving the `\`s) or
// as the shell-collapsed single-line form. We normalize the former by
// joining continuation lines before tokenizing.

const SCRIPT_NAME = "assemble-mandatory.sh";

// Join POSIX backslash-continuation lines: a backslash at end-of-line
// (optionally followed by trailing whitespace before the newline) plus the
// newline (LF or CRLF) collapses to a single space.
function joinContinuations(s) {
  return s.replace(/\\[ \t]*\r?\n[ \t]*/g, " ");
}

function tokenize(s) {
  // Minimal POSIX-like tokenizer: splits on whitespace honoring single/double
  // quotes. Backslash-escapes inside paths (e.g. Windows `C:\foo`) are kept
  // literal — continuation backslashes have already been removed by
  // joinContinuations.
  const out = [];
  let cur = "";
  let q = null; // '\'' or '"' or null
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === q) { q = null; continue; }
      cur += c;
    } else if (c === '"' || c === "'") {
      q = c;
    } else if (/\s/.test(c)) {
      if (cur) { out.push(cur); cur = ""; }
    } else {
      cur += c;
    }
  }
  if (cur) out.push(cur);
  return out;
}

const SEPARATORS = new Set(["&&", "||", ";", "|"]);
const TRAILING_SEPARATOR = /(&&|\|\||;|\|)$/;
const INTERPRETERS = new Set(["bash", "sh", "bash.exe", "sh.exe"]);

function isScriptToken(t) {
  return t.endsWith("/" + SCRIPT_NAME) || t.endsWith("\\" + SCRIPT_NAME) || t === SCRIPT_NAME;
}

function isInterpreterToken(t) {
  return INTERPRETERS.has(t.split(/[\\/]/).pop().toLowerCase());
}

// splitSeparator(token) -> {word, sep}: a separator glued to the end of a word (`hi;`) ends
// the command segment just like a standalone separator token.
function splitSeparator(t) {
  if (SEPARATORS.has(t)) return { word: "", sep: true };
  const m = t.match(TRAILING_SEPARATOR);
  return m ? { word: t.slice(0, -m[1].length), sep: true } : { word: t, sep: false };
}

// findExecutedScript(tokens) -> index of the first script token that executes: the command
// word of a segment (after VAR=value assignments), or the script operand of a bash/sh
// interpreter in command position (after its -options). A mere argument never counts.
function findExecutedScript(tokens) {
  let cmdPos = true;
  let afterInterp = false;
  for (let i = 0; i < tokens.length; i++) {
    const { word, sep } = splitSeparator(tokens[i]);
    if (word) {
      if (cmdPos && /^[A-Za-z_][A-Za-z0-9_]*=/.test(word)) {
        // assignment prefix (its value is never the command): still in command position
      } else if (!sep && isScriptToken(word) && (cmdPos || afterInterp)) {
        return i;
      } else if (cmdPos && isInterpreterToken(word)) {
        cmdPos = false;
        afterInterp = true;
      } else if (!(afterInterp && word.startsWith("-"))) {
        cmdPos = false;
        afterInterp = false;
      }
    }
    if (sep) {
      cmdPos = true;
      afterInterp = false;
    }
  }
  return -1;
}

// scriptArgs(tokens, i) -> the script's arguments, up to the end of its command segment.
function scriptArgs(tokens, i) {
  const args = [];
  for (let k = i + 1; k < tokens.length; k++) {
    const { word, sep } = splitSeparator(tokens[k]);
    if (word) args.push(word);
    if (sep) break;
  }
  return args;
}

function extractAssembleDest(cmd) {
  if (typeof cmd !== "string" || cmd.length === 0) return null;
  if (cmd.indexOf(SCRIPT_NAME) === -1) return null;
  const tokens = tokenize(joinContinuations(cmd));
  const i = findExecutedScript(tokens);
  if (i < 0) return null;
  const args = scriptArgs(tokens, i);
  // Optional --source-kind <kind>, then 3 positionals: source, planner-out, out
  const j = args[0] === "--source-kind" ? 2 : 0;
  const dest = args[j + 2];
  // Defensive: reject lone backslash (would indicate continuation handling
  // failed) and flag-looking tokens.
  if (!dest || dest === "\\" || dest.startsWith("-")) return null;
  return dest;
}

module.exports = { extractAssembleDest, tokenize, joinContinuations };
