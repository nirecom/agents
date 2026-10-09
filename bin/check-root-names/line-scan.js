"use strict";

// Shared line reading for the root-name checks (#2561): the language of a file, its
// lines without comments, and the simple commands of a shell line. Text is read, never run.

const JS_EXT = /\.(?:js|cjs|mjs|jsx|ts|tsx)$/;
const PS_EXT = /\.(?:ps1|psm1|psd1)$/;
const PROSE_EXT = /\.(?:md|markdown|txt|rst)$/;
const YAML_EXT = /\.ya?ml$/;
const OTHER_EXT = /\.(?:py|rb|toml|ini|cfg|html|css|svg|tsv|csv|lock|xml)$/;

// A file of an unknown kind is read as shell: a renamed copy of a script stays covered.
function langOf(rel, text) {
  const first = text.slice(0, 200).split("\n", 1)[0];
  if (/^#!.*\bnode\b/.test(first)) return "js";
  if (/^#!.*\bpwsh\b/.test(first)) return "ps";
  if (/^#!.*\bpython/.test(first)) return "other";
  if (/^#!.*\b(?:ba|z|da)?sh\b/.test(first)) return "sh";
  if (JS_EXT.test(rel)) return "js";
  if (PS_EXT.test(rel)) return "ps";
  if (PROSE_EXT.test(rel)) return "prose";
  if (YAML_EXT.test(rel)) return "yaml";
  if (/\.json$/.test(rel)) return "json";
  if (OTHER_EXT.test(rel)) return "other";
  return "sh";
}

// jsLines(raw) → { code, bare }: comments removed; `bare` also blanks string contents.
function jsLines(raw) {
  const code = [];
  const bare = [];
  let block = false;
  let quote = "";
  for (const line of raw) {
    let c = "";
    let b = "";
    if (quote !== "`") quote = "";
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (block) {
        if (ch === "*" && line[i + 1] === "/") {
          block = false;
          i++;
        }
      } else if (quote) {
        c += ch;
        if (ch === "\\") {
          c += line[i + 1] || "";
          b += "  ";
          i++;
        } else if (ch === quote) {
          quote = "";
          b += ch;
        } else b += " ";
      } else if (ch === "/" && line[i + 1] === "/") break;
      else if (ch === "/" && line[i + 1] === "*") {
        block = true;
        i++;
      } else {
        if (ch === '"' || ch === "'" || ch === "`") quote = ch;
        c += ch;
        b += ch;
      }
    }
    code.push(c);
    bare.push(b);
  }
  return { code, bare };
}

function psLines(raw) {
  const code = [];
  let block = false;
  for (const line of raw) {
    let c = "";
    let quote = "";
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (block) {
        if (ch === "#" && line[i + 1] === ">") {
          block = false;
          i++;
        }
      } else if (quote) {
        c += ch;
        if (ch === quote) quote = "";
      } else if (ch === "<" && line[i + 1] === "#") {
        block = true;
        i++;
      } else if (ch === "#") break;
      else {
        if (ch === '"' || ch === "'") quote = ch;
        c += ch;
      }
    }
    code.push(c);
  }
  return code;
}

const SEPARATORS = new Set([";", "&", "|", "(", ")"]);
const BREAK_WORDS = new Set(["{", "}", "then", "do", "else", "elif", "if", "while", "until", "!", "time", "fi", "done"]);
// Words that open or close a compound command when they stand where a command starts.
const OPEN_WORDS = new Set(["if", "do", "case", "{"]);
const CLOSE_WORDS = new Set(["fi", "done", "esac", "}"]);

function skipSingle(s, i) {
  const end = s.indexOf("'", i + 1);
  return end < 0 ? s.length : end + 1;
}

function skipTick(s, i, subs) {
  let j = i + 1;
  while (j < s.length && s[j] !== "`") j += s[j] === "\\" ? 2 : 1;
  subs.push(s.slice(i + 1, j));
  return Math.min(j + 1, s.length);
}

// skipParen — s[i] is "("; the text up to the matching ")" becomes one more piece to read.
function skipParen(s, i, subs) {
  let depth = 0;
  let j = i;
  while (j < s.length) {
    const ch = s[j];
    if (ch === "\\") j += 2;
    else if (ch === "'") j = skipSingle(s, j);
    else if (ch === '"') j = skipDouble(s, j, []);
    else {
      if (ch === "(") depth++;
      else if (ch === ")" && --depth === 0) {
        subs.push(s.slice(i + 1, j));
        return j + 1;
      }
      j++;
    }
  }
  subs.push(s.slice(i + 1));
  return s.length;
}

function skipBrace(s, i, subs) {
  let depth = 0;
  let j = i;
  while (j < s.length) {
    const ch = s[j];
    if (ch === "\\") j += 2;
    else if (ch === '"') j = skipDouble(s, j, subs);
    else if (ch === "$" && s[j + 1] === "(") j = skipParen(s, j + 1, subs);
    else {
      if (ch === "{") depth++;
      else if (ch === "}" && --depth === 0) return j + 1;
      j++;
    }
  }
  return s.length;
}

function skipDouble(s, i, subs) {
  let j = i + 1;
  while (j < s.length) {
    const ch = s[j];
    if (ch === "\\") j += 2;
    else if (ch === '"') return j + 1;
    else if (ch === "$" && s[j + 1] === "(") j = skipParen(s, j + 1, subs);
    else if (ch === "$" && s[j + 1] === "{") j = skipBrace(s, j + 1, subs);
    else if (ch === "`") j = skipTick(s, j, subs);
    else j++;
  }
  return s.length;
}

function skipWord(s, i, subs) {
  let j = i;
  while (j < s.length) {
    const ch = s[j];
    if (ch === " " || ch === "\t") break;
    if (SEPARATORS.has(ch)) {
      // ">&2" and "&>" belong to a redirection, not to a command boundary.
      if (ch === "&" && j > i && (s[j - 1] === ">" || s[j - 1] === "<")) j++;
      else break;
    } else if (ch === "\\") j += 2;
    else if (ch === "'") j = skipSingle(s, j);
    else if (ch === '"') j = skipDouble(s, j, subs);
    else if (ch === "`") j = skipTick(s, j, subs);
    else if (ch === "$" && s[j + 1] === "(") j = skipParen(s, j + 1, subs);
    else if (ch === "$" && s[j + 1] === "{") j = skipBrace(s, j + 1, subs);
    else j++;
  }
  return Math.min(j, s.length);
}

// shLine(line) → { cmds, code, marks }: cmds is one word list per simple command, including
// the commands inside $( ) and backticks; code is the line without its trailing comment;
// marks is the line's own block structure in order: "+" / "-" for a compound command opened
// or closed, "(+" for a subshell paren, "(" for any other paren, ")" for a closing paren.
function shLine(line) {
  const cmds = [];
  const marks = [];
  const queue = [line];
  let commentAt = -1;
  for (let q = 0; q < queue.length; q++) {
    const text = queue[q];
    let words = [];
    const flush = () => {
      if (words.length > 0) cmds.push(words);
      words = [];
    };
    let i = 0;
    while (i < text.length) {
      const ch = text[i];
      if (ch === " " || ch === "\t") i++;
      else if (ch === "#") {
        if (q === 0) commentAt = i;
        break;
      } else if (SEPARATORS.has(ch)) {
        if (q === 0 && ch === "(") marks.push(words.length === 0 ? "(+" : "(");
        else if (q === 0 && ch === ")") marks.push(")");
        flush();
        i++;
      } else {
        const end = Math.max(skipWord(text, i, queue), i + 1);
        const word = text.slice(i, end);
        // `function name {` keeps its brace behind two words; every other opener starts a command.
        if (q === 0 && (words.length === 0 || words[0] === "function")) {
          if (OPEN_WORDS.has(word)) marks.push("+");
          else if (words.length === 0 && CLOSE_WORDS.has(word)) marks.push("-");
        }
        if (BREAK_WORDS.has(word)) flush();
        else words.push(word);
        i = end;
      }
    }
    flush();
  }
  return { cmds, marks, code: commentAt < 0 ? line : line.slice(0, commentAt) };
}

const ASSIGN_RE = /^([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\+?=/;

// splitCommand(words) → { assigns, word, args }: leading NAME=value words, the command
// word (null for a bare assignment), and the words after it.
function splitCommand(words) {
  const assigns = [];
  let i = 0;
  for (; i < words.length; i++) {
    const m = ASSIGN_RE.exec(words[i]);
    if (!m) break;
    assigns.push(m[1]);
  }
  return { assigns, word: i < words.length ? words[i] : null, args: words.slice(i + 1) };
}

// declared(args) → the variable names a declaration builtin (export, local, ...) is given.
function declared(args) {
  const names = [];
  for (const arg of args) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)(?:\+?=.*)?$/s.exec(arg);
    if (m) names.push({ name: m[1], assigned: arg.includes("=") });
  }
  return names;
}

// view(file) → { lang, raw, code, bare, cmds, marks } for a { rel, text } file, cached on it.
function view(file) {
  if (file.view) return file.view;
  if (file.text === null) {
    file.view = { lang: "binary", raw: [], code: [], bare: [], cmds: null, marks: null };
    return file.view;
  }
  const lang = langOf(file.rel, file.text);
  const raw = file.text.split(/\r?\n/);
  let code = raw;
  let bare = raw;
  let cmds = null;
  let marks = null;
  if (lang === "js") ({ code, bare } = jsLines(raw));
  else if (lang === "ps") bare = code = psLines(raw);
  else if (lang === "sh") {
    const scanned = raw.map(shLine);
    bare = code = scanned.map((s) => s.code);
    cmds = scanned.map((s) => s.cmds);
    marks = scanned.map((s) => s.marks);
  }
  file.view = { lang, raw, code, bare, cmds, marks };
  return file.view;
}

const isTest = (rel) => rel.startsWith("tests/");
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

module.exports = { view, langOf, shLine, splitCommand, declared, isTest, escapeRe };
