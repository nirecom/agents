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
// unescaped `"` follows, otherwise it is an ordinary character; `\"` is a
// literal quote; `""` yields an empty token. Reconstructing real argument
// boundaries is what lets the matcher below refuse substring lookalikes.
function tokenizeCommandLine(commandLine) {
  const text = typeof commandLine === "string" ? commandLine : "";
  const tokens = [];
  let current = "";
  let started = false;
  let i = 0;

  while (i < text.length) {
    const ch = text[i];
    if (ch === "\\" && text[i + 1] === '"') {
      current += '"';
      started = true;
      i += 2;
    } else if (ch === '"') {
      const close = findClosingQuote(text, i + 1);
      if (close < 0) {
        current += '"';
        started = true;
        i += 1;
      } else {
        current += unescapeQuoted(text.slice(i + 1, close));
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

function findClosingQuote(text, from) {
  let i = from;
  while (i < text.length) {
    if (text[i] === "\\" && text[i + 1] === '"') {
      i += 2;
      continue;
    }
    if (text[i] === '"') return i;
    i += 1;
  }
  return -1;
}

function unescapeQuoted(segment) {
  let out = "";
  let i = 0;
  while (i < segment.length) {
    if (segment[i] === "\\" && segment[i + 1] === '"') {
      out += '"';
      i += 2;
    } else {
      out += segment[i];
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

function hasServeMcpPair(argv) {
  for (let i = 0; i < argv.length - 1; i += 1) {
    if (argv[i] === "serve" && argv[i + 1] === "--mcp") return true;
  }
  return false;
}

// The daemon runs as node.exe, so the image name identifies nothing; the
// `...\codegraph.js` element on its command line is the only marker.
function namesCodegraph(argv) {
  return argv.some((element) => {
    if (typeof element !== "string" || element.length === 0) return false;
    const base = element.split(/[/\\]/).pop().replace(/\.[^.]+$/, "");
    return base.toLowerCase() === "codegraph";
  });
}

function pathValueMatches(value, wanted) {
  return rootCandidates(value).some((candidate) => wanted.includes(candidate));
}

// isDaemonForRoot: true only when all three hold — a consecutive `serve`
// `--mcp` pair, a codegraph-named element, and a standalone `--path` element
// whose NEXT element normalizes to this root. Matching is whole-element
// equality, never substring or prefix, which is what keeps <root>-old and
// <root>/sub from being mistaken for <root>.
function isDaemonForRoot(argv, root) {
  if (!Array.isArray(argv) || argv.length === 0) return false;
  if (!hasServeMcpPair(argv)) return false;
  if (!namesCodegraph(argv)) return false;

  const wanted = rootCandidates(root);
  if (wanted.length === 0) return false;

  for (let i = 0; i < argv.length - 1; i += 1) {
    if (argv[i] !== "--path") continue;
    if (pathValueMatches(argv[i + 1], wanted)) return true;
  }
  return false;
}

module.exports = {
  readArgv,
  tokenizeCommandLine,
  normalizeRootForCompare,
  rootCandidates,
  isDaemonForRoot,
};
