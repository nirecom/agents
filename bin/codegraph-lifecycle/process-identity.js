#!/usr/bin/env node
// process-identity.js — answer one question: is PID N the CodeGraph daemon
// serving THIS root? Nothing else. It never kills and never waits; stopping is
// the caller's job (bin/codegraph-lifecycle.js `stop`).
//
// Every predicate here fails closed. A command line we cannot read, cannot
// tokenize, or cannot match exactly yields false, because killing the wrong
// process is unrecoverable while failing to kill costs one retry.

process.removeAllListeners("warning");

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const QUERY_TIMEOUT_MS = 10000;
const NUL = String.fromCharCode(0);

// tokenizeCommandLine turns an OS-reported command-line STRING back into argv.
// Rules: whitespace separates; a `"` opens a region only when a matching
// unescaped `"` follows, otherwise it is an ordinary character; a run of N
// backslashes immediately before a `"` collapses to floor(N/2) literal
// backslashes, and the quote itself is literal only when N is odd (otherwise
// it is a real delimiter) — the same rule CommandLineToArgvW uses, and the
// one a doubled trailing backslash before a closing quote (`"C:\repo\\"`)
// relies on to still close the string. `""` yields an empty token.
// Reconstructing real argument boundaries is what lets the matcher below
// refuse substring lookalikes.
function tokenizeCommandLine(commandLine) {
  const text = typeof commandLine === "string" ? commandLine : "";
  const tokens = [];
  let current = "";
  let started = false;
  let i = 0;

  while (i < text.length) {
    const ch = text[i];
    if (ch === "\\") {
      const scan = scanBackslashRun(text, i);
      current += "\\".repeat(scan.backslashes);
      if (scan.quoteConsumed) current += '"';
      started = true;
      i = scan.nextIndex;
    } else if (ch === '"') {
      const close = findClosingQuote(text, i + 1);
      if (close < 0) {
        current += '"';
        started = true;
        i += 1;
      } else {
        current += unescapeQuoted(text, i + 1, close);
        started = true;
        i = close + 1;
      }
    } else if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
      if (started) tokens.push(current);
      current = "";
      started = false;
      i += 1;
    } else {
      current += ch;
      started = true;
      i += 1;
    }
  }
  if (started) tokens.push(current);
  return tokens;
}

// scanBackslashRun measures the run of backslashes starting at text[i] and
// classifies what follows it, per the CommandLineToArgvW rule: 2n backslashes
// before a `"` fold to n literal backslashes with the quote left as a real
// delimiter (quoteConsumed: false, nextIndex sits ON the quote); 2n+1
// backslashes fold to n literal backslashes plus one literal `"` (consumed
// here — quoteConsumed: true, nextIndex sits PAST the quote); a run not
// followed by `"` is simply that many literal backslashes.
function scanBackslashRun(text, i) {
  let n = 0;
  while (text[i + n] === "\\") n += 1;
  if (text[i + n] !== '"') return { backslashes: n, quoteConsumed: false, nextIndex: i + n };
  if (n % 2 === 1) return { backslashes: (n - 1) / 2, quoteConsumed: true, nextIndex: i + n + 1 };
  return { backslashes: n / 2, quoteConsumed: false, nextIndex: i + n };
}

function findClosingQuote(text, from) {
  let i = from;
  while (i < text.length) {
    if (text[i] === "\\") {
      i = scanBackslashRun(text, i).nextIndex;
      continue;
    }
    if (text[i] === '"') return i;
    i += 1;
  }
  return -1;
}

// unescapeQuoted walks the ORIGINAL text over [from, to) rather than a
// pre-sliced copy so that a backslash run ending exactly at `to` still sees
// the real closing quote at text[to] (findClosingQuote only ever lands `to`
// on an even run, so this boundary case always folds, never consumes it as
// a literal `"`). Slicing first would hide that quote and under-fold the
// trailing run — the doubled-backslash-before-close bug this file now avoids.
function unescapeQuoted(text, from, to) {
  let out = "";
  let i = from;
  while (i < to) {
    if (text[i] === "\\") {
      const scan = scanBackslashRun(text, i);
      out += "\\".repeat(scan.backslashes);
      if (scan.quoteConsumed) out += '"';
      i = scan.nextIndex;
    } else {
      out += text[i];
      i += 1;
    }
  }
  return out;
}

// normalizeRootForCompare applies one rule set to BOTH sides of every path
// comparison. The win32-only branches are a deliberate, named exception
// (CPR-UNV): backslash is a legal filename character on POSIX and /repo/A is
// not /repo/a there, so folding either one off-Windows would invent matches.
// UNC and 8.3 forms are left unexpanded — they simply fail to match, which
// lands on "do not kill".
function normalizeRootForCompare(candidate) {
  if (typeof candidate !== "string" || candidate.length === 0) return "";
  const windows = process.platform === "win32";
  let value = path.resolve(candidate);
  if (windows) value = value.replace(/\\/g, "/");
  const isFilesystemRoot = value === "/" || /^[A-Za-z]:\/$/.test(value);
  if (!isFilesystemRoot) value = value.replace(windows ? /[/\\]+$/ : /\/+$/, "");
  return windows ? value.toLowerCase() : value;
}

// rootCandidates yields the normalized forms a path may legitimately wear:
// as written, and as the filesystem really spells it. realpathSync.native is
// what recovers the true casing on win32 and the target of a symlinked
// worktree. Both sides of the match get the same treatment.
function rootCandidates(candidate) {
  const out = [];
  const add = (value) => {
    const normalized = normalizeRootForCompare(value);
    if (normalized && !out.includes(normalized)) out.push(normalized);
  };
  add(candidate);
  try {
    add(fs.realpathSync.native(candidate));
  } catch (_) {
    /* unresolvable path: the as-written form is the only candidate */
  }
  return out;
}

function readProcArgv(pid) {
  if (process.env.CG_LIFECYCLE_FORCE_CMDLINE_STRING === "1") return null;
  let raw;
  try {
    raw = fs.readFileSync("/proc/" + String(pid) + "/cmdline", "utf8");
  } catch (_) {
    return null;
  }
  const parts = raw.split(NUL);
  while (parts.length > 0 && parts[parts.length - 1] === "") parts.pop();
  return parts.length > 0 ? parts : null;
}

// readCommandLineString is the fallback when /proc is unavailable. Defence is
// ordered: the caller's numeric PID validation is the first wall (only digits
// can reach the -Command string), and passing argv as an array with the
// default shell:false is the second. `-ww` and [Console]::Out.Write both exist
// to stop the OS from truncating or rewrapping the line we are about to parse.
function readCommandLineString(pid) {
  const id = String(pid);
  const query = process.platform === "win32"
    ? {
      command: "powershell.exe",
      args: [
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "$c=(Get-CimInstance Win32_Process -Filter 'ProcessId=" + id + "').CommandLine; if ($c) { [Console]::Out.Write($c) }",
      ],
    }
    : { command: "ps", args: ["-ww", "-o", "args=", "-p", id] };

  const result = spawnSync(query.command, query.args, { encoding: "utf8", timeout: QUERY_TIMEOUT_MS });
  if (result.error || result.status !== 0) return null;
  const text = String(result.stdout || "").trim();
  return text.length > 0 ? text : null;
}

// readArgv returns the process argv as an array, or null for "cannot tell".
// /proc is tried first on every platform (never gated on process.platform:
// WSL and containers decide that, not the OS name) because it needs no
// quoting rules at all.
function readArgv(pid) {
  const direct = readProcArgv(pid);
  if (direct) return direct;
  const line = readCommandLineString(pid);
  if (line === null) return null;
  return tokenizeCommandLine(line);
}

// serveMcpIndex returns the index of the first `serve` immediately followed by
// `--mcp`, or -1. It anchors the verb the daemon is invoked with, which is what
// lets namesCodegraph below locate the script element without scanning argv.
function serveMcpIndex(argv) {
  for (let i = 0; i < argv.length - 1; i += 1) {
    if (argv[i] === "serve" && argv[i + 1] === "--mcp") return i;
  }
  return -1;
}

function hasServeMcpPair(argv) {
  return serveMcpIndex(argv) >= 0;
}

// The daemon runs as node.exe, so the image name identifies nothing; only the
// element right before `serve` is the marker. Pinning it to a fixed argv
// index is not enough (rejects `node --flag codegraph.js serve --mcp`,
// accepts `wrapper /tmp/codegraph.js serve --mcp`): the marker is legitimate
// only as argv[0] itself, or as the first non-flag element after a node
// interpreter at argv[0] — never a decoy token behind an arbitrary program.
const INTERPRETER_BASENAMES = new Set(["node"]);

function isInterpreterImage(element) {
  if (typeof element !== "string" || element.length === 0) return false;
  const base = element.split(/[/\\]/).pop().replace(/\.[^.]+$/, "");
  return INTERPRETER_BASENAMES.has(base.toLowerCase());
}

function namesCodegraph(argv) {
  const serveAt = serveMcpIndex(argv);
  if (serveAt < 1) return false;
  const markerAt = serveAt - 1;
  const element = argv[markerAt];
  if (typeof element !== "string" || element.length === 0) return false;
  const base = element.split(/[/\\]/).pop().replace(/\.[^.]+$/, "");
  if (base.toLowerCase() !== "codegraph") return false;
  if (markerAt === 0) return true;
  if (!isInterpreterImage(argv[0])) return false;
  for (let i = 1; i < markerAt; i += 1) {
    if (typeof argv[i] !== "string" || !argv[i].startsWith("-")) return false;
  }
  return true;
}

function pathValueMatches(value, wanted) {
  return rootCandidates(value).some((candidate) => wanted.includes(candidate));
}

// isDaemonForRoot: true only when all three hold — a consecutive `serve`
// `--mcp` pair, a codegraph-named script element immediately before `serve`,
// and a standalone `--path` element whose NEXT element normalizes to this
// root. Matching is whole-element equality, never substring or prefix, which
// is what keeps <root>-old and <root>/sub from being mistaken for <root>.
// Only the LAST `--path` counts: the binary's own parseArgs is last-match-wins,
// so an earlier occurrence names a root the daemon is not serving.
function isDaemonForRoot(argv, root) {
  if (!Array.isArray(argv) || argv.length === 0) return false;
  if (!hasServeMcpPair(argv)) return false;
  if (!namesCodegraph(argv)) return false;

  const wanted = rootCandidates(root);
  if (wanted.length === 0) return false;

  const lastPathAt = argv.lastIndexOf("--path");
  if (lastPathAt < 0) return false;
  return pathValueMatches(argv[lastPathAt + 1], wanted);
}

module.exports = {
  readArgv,
  tokenizeCommandLine,
  normalizeRootForCompare,
  rootCandidates,
  isDaemonForRoot,
};
