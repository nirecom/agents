"use strict";
// Tests: tests/lib/spawn-record.sh
// Tags: scope:common, test-infra, spawn-record
// tests/fixtures/spawn-record-preload/command-words.js — the commands a child_process call would
// really start (#2590). effectiveCommands(fileOrString, args, shell) returns [{ cmd, args }]:
// a shell string is split into simple commands; leading NAME=value words, `env` and its options,
// and `command` / `exec` / `nohup` / `time` are skipped; `sh -c` / `bash -c` is followed one level.

const SHELLS = ["sh", "bash", "dash", "zsh"];
const PREFIX_WORDS = ["command", "exec", "nohup", "time"];
const ENV_VALUE_OPTIONS = ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"];
const ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

function baseName(command) {
  return String(command)
    .replace(/\\/g, "/")
    .split("/")
    .pop()
    .replace(/\.(exe|cmd)$/i, "")
    .toLowerCase();
}

// Split shell text into simple commands (arrays of unquoted words). Separators: ; && || | & and
// newline; quotes and backslashes are honoured, expansions are left as written.
function splitShell(text) {
  const commands = [];
  let words = [];
  let word = "";
  let inWord = false;
  const endWord = () => {
    if (inWord) words.push(word);
    word = "";
    inWord = false;
  };
  const endCommand = () => {
    endWord();
    if (words.length > 0) commands.push(words);
    words = [];
  };
  const s = String(text);
  for (let i = 0; i < s.length; i += 1) {
    const c = s[i];
    if (c === "'") {
      const j = s.indexOf("'", i + 1);
      const end = j < 0 ? s.length : j;
      word += s.slice(i + 1, end);
      inWord = true;
      i = end;
    } else if (c === '"') {
      inWord = true;
      for (i += 1; i < s.length && s[i] !== '"'; i += 1) {
        if (s[i] === "\\" && i + 1 < s.length && '"\\$`'.includes(s[i + 1])) i += 1;
        word += s[i];
      }
    } else if (c === "\\" && i + 1 < s.length) {
      if (s[i + 1] !== "\n") word += s[i + 1];
      inWord = true;
      i += 1;
    } else if (c === ";" || c === "|" || c === "&" || c === "\n") {
      endCommand();
    } else if (c === " " || c === "\t" || c === "\r") {
      endWord();
    } else {
      word += c;
      inWord = true;
    }
  }
  endCommand();
  return commands;
}

// The words left once assignments and prefix commands are skipped.
function stripPrefixes(words) {
  let i = 0;
  for (;;) {
    while (i < words.length && ASSIGNMENT_RE.test(words[i])) i += 1;
    if (i >= words.length) return [];
    const name = baseName(words[i]);
    if (name === "env") {
      i += 1;
      while (i < words.length) {
        const w = words[i];
        if (w === "--") {
          i += 1;
          break;
        }
        if (ENV_VALUE_OPTIONS.includes(w)) i += 2;
        else if (w === "-" || w.startsWith("-")) i += 1;
        else break;
      }
    } else if (PREFIX_WORDS.includes(name)) {
      i += 1;
      while (i < words.length && words[i].startsWith("-")) i += 1;
    } else {
      return words.slice(i);
    }
  }
}

// The -c string of a shell invocation, or null when it is not one.
function shellCommandString(words) {
  if (!SHELLS.includes(baseName(words[0]))) return null;
  for (let i = 1; i < words.length; i += 1) {
    const w = words[i];
    if (!w.startsWith("-")) return null;
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(w)) return i + 1 < words.length ? words[i + 1] : null;
  }
  return null;
}

function fromWords(words, depth) {
  const rest = stripPrefixes(words);
  if (rest.length === 0) return [];
  const inner = depth < 1 ? shellCommandString(rest) : null;
  if (inner !== null) return fromText(inner, depth + 1);
  return [{ cmd: baseName(rest[0]), args: rest.slice(1) }];
}

function fromText(text, depth) {
  return splitShell(text).flatMap((words) => fromWords(words, depth));
}

function effectiveCommands(fileOrString, args, shell) {
  const list = Array.isArray(args) ? args.map(String) : [];
  if (shell) return fromText([String(fileOrString)].concat(list).join(" "), 0);
  return fromWords([String(fileOrString)].concat(list), 0);
}

module.exports = { baseName, effectiveCommands, splitShell };
