#!/usr/bin/env node
// shim-resolve-reference.js — test-only stand-in for the win32 PATH x PATHEXT
// resolution + npm-cmd-shim cross-check hooks/lib/spawn-shimmed-cli.js will do.
// SSOT for the semantics reproduced here: detail plan ST-1 (pathextList /
// resolveOnPath / verifiedShimTarget). It exists because that module is not
// written yet and it is the only way the WS/WC suites can OBSERVE that their
// PATHEXT pin is load-bearing (C4) instead of assuming it. Never require it
// from production code. Reduced on purpose: it answers "which file would be
// spawned" and spawns nothing.

// Usage: node tests/lib/shim-resolve-reference.js <command> — prints one line:
// "resolved <target.js>" | "direct <file>" | "unresolved". Exports decide().

const fs = require("fs");
const path = require("path");

const DIRECT_EXTENSIONS = [".exe", ".com"];
const DELEGATED_EXTENSIONS = [".cmd", ".bat"];
const ALLOWED_EXTENSIONS = new Set([...DIRECT_EXTENSIONS, ...DELEGATED_EXTENSIONS]);
const DEFAULT_PATHEXT = ".COM;.EXE;.BAT;.CMD";
const MAX_PATH_DIRS = 64;

function isUncPath(dir) {
  return dir.startsWith("\\\\") || dir.startsWith("//");
}

function pathDirs() {
  const raw = process.env.PATH || process.env.Path || "";
  return raw
    .split(path.delimiter)
    .filter(Boolean)
    .filter((dir) => !isUncPath(dir))
    .slice(0, MAX_PATH_DIRS);
}

// The load-bearing line for the C4 cases: the ambient PATHEXT decides which
// extensions are candidates at all, so a host value omitting .CMD makes the
// whole delegated branch unreachable.
function pathextList() {
  const raw = process.env.PATHEXT || DEFAULT_PATHEXT;
  return raw
    .split(";")
    .filter(Boolean)
    .map((ext) => ext.toLowerCase())
    .filter((ext) => ALLOWED_EXTENSIONS.has(ext));
}

function isFile(candidate) {
  try {
    return fs.statSync(candidate).isFile();
  } catch (_) {
    return false;
  }
}

// Directory-major, extension-minor — the order CreateProcess/cmd.exe use.
function resolveOnPath(command) {
  for (const dir of pathDirs()) {
    for (const ext of pathextList()) {
      const candidate = path.join(dir, command + ext);
      if (isFile(candidate)) return candidate;
    }
  }
  return null;
}

const SHIM_TARGET_PATTERN = /"\$basedir\/([^"]+?\.[cm]?js)"/;
const CMD_TARGET_PATTERN = /"%dp0%\\?([^"]+?\.[cm]?js)"\s*%\*/;

function extractRelativeTarget(text, pattern) {
  const match = pattern.exec(text);
  return match ? match[1].split(/[\\/]/).join(path.sep) : null;
}

// Both files are read as text and never executed; a mismatch is "not found" (C2).
function verifiedShimTarget(cmdPath) {
  const dir = path.dirname(cmdPath);
  const base = path.basename(cmdPath, path.extname(cmdPath));
  const siblingPath = path.join(dir, base);
  if (!isFile(siblingPath)) return null;

  let cmdText;
  let siblingText;
  try {
    cmdText = fs.readFileSync(cmdPath, "utf8");
    siblingText = fs.readFileSync(siblingPath, "utf8");
  } catch (_) {
    return null;
  }

  const cmdRelative = extractRelativeTarget(cmdText, CMD_TARGET_PATTERN);
  const siblingRelative = extractRelativeTarget(siblingText, SHIM_TARGET_PATTERN);
  if (!cmdRelative || !siblingRelative) return null;

  const cmdResolved = path.join(dir, cmdRelative);
  const siblingResolved = path.join(dir, siblingRelative);
  if (cmdResolved.toLowerCase() !== siblingResolved.toLowerCase()) return null;

  return isFile(siblingResolved) ? siblingResolved : null;
}

// decide(command) — the whole classifier as one value, so a caller can compare
// it against the real module instead of against a printed sentence.
// null = nothing launchable; {kind:"direct"} = launch the resolved file as-is;
// {kind:"node"} = the batch shim was parsed and its verified target wins.
function decide(command) {
  if (!command) return null;
  const resolved = resolveOnPath(command);
  if (!resolved) return null;
  const ext = path.extname(resolved).toLowerCase();
  if (DIRECT_EXTENSIONS.includes(ext)) return { kind: "direct", file: resolved };
  if (!DELEGATED_EXTENSIONS.includes(ext)) return null;
  const target = verifiedShimTarget(resolved);
  return target ? { kind: "node", file: target } : null;
}

function main() {
  const command = process.argv[2];
  if (!command) {
    process.stderr.write("usage: node tests/lib/shim-resolve-reference.js <command>\n");
    process.exit(64);
  }
  const d = decide(command);
  if (!d) {
    process.stdout.write("unresolved\n");
    return;
  }
  const verb = d.kind === "direct" ? "direct " : "resolved ";
  process.stdout.write(verb + path.basename(d.file) + "\n");
}

module.exports = { decide };

if (require.main === module) main();
