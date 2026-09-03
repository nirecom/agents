// spawn-shimmed-cli.js — spawnSync for CLIs installed as npm global shims.
//
// On win32 a shell-less spawnSync cannot launch `codegraph.cmd`, and the
// obvious repair — a shell — is CVE-2024-27980. This reproduces the
// PATH x PATHEXT search itself and READS a `.cmd`/`.bat` shim as text to
// recover the JavaScript entry point npm wrapped, launching that with the
// current Node binary: the batch file never runs and arguments never reach a
// command interpreter. The `.cmd` and its POSIX sibling are parsed
// independently and must agree; any disagreement is "not found".
// Off win32 this is a transparent pass-through to child_process.spawnSync.

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

// Launched as-is; everything else on the list is wrapper text, never an image.
const DIRECT_EXTENSIONS = [".exe", ".com"];
const DELEGATED_EXTENSIONS = [".cmd", ".bat"];
const ALLOWED_EXTENSIONS = new Set([...DIRECT_EXTENSIONS, ...DELEGATED_EXTENSIONS]);
const DEFAULT_PATHEXT = ".COM;.EXE;.BAT;.CMD";

// A directory-count bound, not a time bound: it caps the worst-case walk over a
// pathological PATH. A caller's `timeout` covers the spawn, not this search.
const MAX_PATH_DIRS = 64;

// npm's two generated shims, each naming the same target in its own dialect.
const CMD_TARGET_PATTERN = /"%dp0%\\?([^"]+?\.[cm]?js)"\s*%\*/;
const SHIM_TARGET_PATTERN = /"\$basedir\/([^"]+?\.[cm]?js)"/;

const resolveCache = new Map();

// Windows environment names are case-insensitive but process.env keys arrive in
// whatever case the parent used, so both spellings have to be consulted.
function envValue(name) {
  for (const key of Object.keys(process.env)) {
    if (key.toLowerCase() === name.toLowerCase()) {
      const value = process.env[key];
      if (typeof value === "string" && value !== "") return value;
    }
  }
  return "";
}

// A drive-letter mapping of a network share is NOT caught here; that residual
// risk is accepted — the check skips obviously remote entries whose stat can
// stall, and is not a completeness claim about remoteness.
function isUncPath(dir) {
  return dir.startsWith("\\\\") || dir.startsWith("//");
}

function pathDirs() {
  return envValue("PATH")
    .split(path.delimiter)
    .filter(Boolean)
    .filter((dir) => !isUncPath(dir))
    .slice(0, MAX_PATH_DIRS);
}

// The ambient PATHEXT decides which extensions are candidates at all, then the
// allow-list decides which of those this module is willing to launch: a host
// PATHEXT carrying .PS1 or .VBS contributes nothing here.
function pathextList() {
  const raw = envValue("PATHEXT") || DEFAULT_PATHEXT;
  const seen = new Set();
  const list = [];
  for (const field of raw.split(";")) {
    const ext = field.trim().toLowerCase();
    if (!ext || seen.has(ext) || !ALLOWED_EXTENSIONS.has(ext)) continue;
    seen.add(ext);
    list.push(ext);
  }
  return list;
}

function isFile(candidate) {
  try {
    return fs.statSync(candidate).isFile();
  } catch (_) {
    return false;
  }
}

function isRooted(command) {
  return command.includes("\\") || command.includes("/") || /^[A-Za-z]:/.test(command);
}

function candidateFrom(basePath, ext) {
  const full = basePath + ext;
  if (!isFile(full)) return null;
  return { dir: path.dirname(full), base: path.basename(basePath), ext, fullPath: full };
}

// Directory-major, extension-minor — the order CreateProcess and cmd.exe use.
// A command that already carries a path is not searched for; only its own
// spelling is tried, once per allowed extension.
function resolveUncached(command) {
  if (!command) return null;
  const extensions = pathextList();
  if (isRooted(command)) {
    for (const ext of extensions) {
      const found = candidateFrom(path.resolve(command), ext);
      if (found) return found;
    }
    return null;
  }
  for (const dir of pathDirs()) {
    for (const ext of extensions) {
      const found = candidateFrom(path.join(dir, command), ext);
      if (found) return found;
    }
  }
  return null;
}

// Memoized on the raw command string: a lifecycle run probes the same name
// several times, and the walk is the expensive part. "Not found" is cached too.
function resolveOnPath(command) {
  if (resolveCache.has(command)) return resolveCache.get(command);
  const resolved = resolveUncached(command);
  resolveCache.set(command, resolved);
  return resolved;
}

function extractRelativeTarget(text, pattern) {
  const match = pattern.exec(text);
  return match ? match[1].split(/[\\/]/).join(path.sep) : null;
}

function readText(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (_) {
    return null;
  }
}

// Both halves are read as text and neither is ever executed. The comparison is
// case-insensitive because the two generators may spell the same file
// differently and the filesystem does not distinguish them.
function verifiedShimTarget(candidate) {
  const dir = candidate.dir;
  const siblingPath = path.join(dir, candidate.base);
  if (!isFile(siblingPath)) return null;

  const cmdText = readText(candidate.fullPath);
  const siblingText = readText(siblingPath);
  if (cmdText === null || siblingText === null) return null;

  const cmdRelative = extractRelativeTarget(cmdText, CMD_TARGET_PATTERN);
  const siblingRelative = extractRelativeTarget(siblingText, SHIM_TARGET_PATTERN);
  if (!cmdRelative || !siblingRelative) return null;

  const cmdResolved = path.join(dir, cmdRelative);
  const siblingResolved = path.join(dir, siblingRelative);
  if (cmdResolved.toLowerCase() !== siblingResolved.toLowerCase()) return null;

  return isFile(siblingResolved) ? siblingResolved : null;
}

// The single failure exit. Callers already branch on `result.error`, so every
// unresolvable input is reported in the shape spawnSync itself produces for a
// command that is not there.
function enoentResult(command) {
  const error = new Error("spawnSync " + command + " ENOENT");
  error.code = "ENOENT";
  error.errno = -4058;
  error.syscall = "spawnSync " + command;
  error.path = command;
  return {
    error,
    status: null,
    signal: null,
    output: null,
    pid: 0,
    stdout: null,
    stderr: null,
  };
}

// spawnShimmedCli(command, args, options) — spawnSync with win32 shim
// resolution. `options` is forwarded untouched on every path, so a caller's
// timeout, cwd, env, encoding and stdio reach the real call unchanged and no
// option this module did not receive is ever introduced.
function spawnShimmedCli(command, args, options) {
  if (process.platform !== "win32") return spawnSync(command, args, options);

  const candidate = resolveOnPath(command);
  if (!candidate) return enoentResult(command);

  if (DIRECT_EXTENSIONS.includes(candidate.ext)) {
    return spawnSync(candidate.fullPath, args, options);
  }
  if (!DELEGATED_EXTENSIONS.includes(candidate.ext)) return enoentResult(command);

  const target = verifiedShimTarget(candidate);
  if (!target) return enoentResult(command);
  return spawnSync(process.execPath, [target].concat(args || []), options);
}

module.exports = { spawnShimmedCli };
