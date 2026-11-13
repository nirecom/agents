// bin/lib/run-tests-baseline-compare/normalize.js — the #2956 S4 normalization: one function both
// sides of a comparison go through, so a value that changes per run (time, duration, temp path,
// checkout root, line number, pid, uuid, hash, host, user, home) never reads as a new failure line.
// Also the fold of a fail-details.tsv record (the rule itself: test-result-contract.md).
"use strict";

const os = require("node:os");

// Extensions whose `<path>.<ext>:<n>[:<n>]` loses its line number; the contract doc refers here.
const LINE_NO_EXTS = Object.freeze(["sh", "bash", "js", "mjs", "cjs", "ts", "py", "ps1", "psm1", "md", "json", "tsv"]);
// Windows paths compare without regard to case; nowhere else.
const FOLD_PATH_CASE = process.platform === "win32";
const PATH_TAIL = "(?:[\\\\/][^\\s\"'`:;,()<>\\[\\]|]*)?";

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function unfold(text) {
  return text.replace(/\\([\\tn])/g, (_m, c) => (c === "t" ? "\t" : c === "n" ? "\n" : "\\"));
}
function fold(text) {
  return text.replace(/\\/g, "\\\\").replace(/\t/g, "\\t").replace(/\n/g, "\\n");
}

// pathForms(p) — native, forward-slash, backslash and MSYS drive-letter spellings of one path.
function pathForms(p) {
  if (!p) return [];
  let fwd = String(p).replace(/\\/g, "/").replace(/\/+$/, "");
  const msys = /^\/([A-Za-z])\/(.*)$/.exec(fwd);
  if (msys) fwd = `${msys[1].toUpperCase()}:/${msys[2]}`;
  const forms = [fwd, fwd.replace(/\//g, "\\")];
  const drive = /^([A-Za-z]):\/(.*)$/.exec(fwd);
  if (drive) forms.push(`/${drive[1].toLowerCase()}/${drive[2]}`);
  return forms.filter((f) => f.length > 1);
}

function alternation(values) {
  const uniq = [...new Set(values.filter(Boolean))].sort((a, b) => b.length - a.length);
  return uniq.length ? uniq.map(esc).join("|") : null;
}

function nameRule(names, token) {
  const alt = alternation(names.filter((n) => n && n.length >= 2));
  return alt ? [new RegExp(`(?<![A-Za-z0-9_])(?:${alt})(?![A-Za-z0-9_])`, "gi"), token] : null;
}

function safe(fn) {
  try { return fn(); } catch { return ""; }
}

// foldedForms(p) — pathForms plus the fold's doubled-backslash spelling of each.
const foldedForms = (p) => pathForms(p).flatMap((f) => [f, f.replace(/\\/g, "\\\\")]);

const apply = (rules, text) => rules.reduce((acc, [re, to]) => acc.replace(re, to), text);

// makeNormalizer({ root, baseWt }) — (folded, renames) => normalized folded detail. Paths are
// replaced on the folded text first: a native `C:\x\nire` path must not unfold into a newline.
function makeNormalizer({ root, baseWt }) {
  const pf = FOLD_PATH_CASE ? "gi" : "g";
  const roots = alternation([...foldedForms(root), ...foldedForms(baseWt)]);
  const tmps = alternation(foldedForms(os.tmpdir()));
  const homes = alternation([os.homedir(), process.env.HOME, process.env.USERPROFILE].flatMap(foldedForms));
  const exts = LINE_NO_EXTS.join("|");
  // Order matters: the root may sit in the temp area, and on Windows the temp area sits in home.
  const pathRules = [
    roots && [new RegExp(roots, pf), "<root>"],
    tmps && [new RegExp(`(?:${tmps})${PATH_TAIL}`, pf), "<tmp>"],
    [new RegExp(`(?<![A-Za-z0-9_.\\/-])\\/tmp(?=[\\\\/])${PATH_TAIL}`, "g"), "<tmp>"],
    homes && [new RegExp(homes, pf), "<home>"],
  ].filter(Boolean);
  const textRules = [
    nameRule([os.hostname(), process.env.HOSTNAME, process.env.COMPUTERNAME], "<host>"),
    nameRule([safe(() => os.userInfo().username), process.env.USER, process.env.USERNAME], "<user>"),
    [/\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/g, "<time>"],
    [/\b\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\b/g, "<time>"],
    [/\b\d+(?:\.\d+)?(?:ms|s)\b/g, "<dur>"],
    [new RegExp(`\\.(${exts}):\\d+(:\\d+)?(?!\\d)`, "g"), (_m, ext, two) => `.${ext}:<n>${two ? ":<n>" : ""}`],
    [/\bline \d+\b/gi, "line <n>"],
    [/\b(pid[ =:])\d+\b/gi, "$1<pid>"],
    [/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "<uuid>"],
    [/\b(?=[0-9a-f]*[a-f])[0-9a-f]{7,64}\b/gi, "<hex>"],
  ].filter(Boolean);
  return (folded, renames = []) => fold(apply(textRules, applyRenames(unfold(apply(pathRules, folded)), renames)));
}

// applyRenames(text, pairs) — every branch-side path `new` of [old, new] reads as its base name `old`.
function applyRenames(text, pairs) {
  let out = text;
  for (const [oldPath, newPath] of pairs) {
    const re = new RegExp(`(?<![A-Za-z0-9_.-])${esc(newPath)}(?![A-Za-z0-9_/-]|\\.[A-Za-z0-9_])`, "g");
    out = out.replace(re, oldPath);
  }
  return out;
}

module.exports = { LINE_NO_EXTS, fold, unfold, pathForms, makeNormalizer, applyRenames };
