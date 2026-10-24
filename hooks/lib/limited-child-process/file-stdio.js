"use strict";
// hooks/lib/limited-child-process/file-stdio.js — spawnSync / execSync / execFileSync with file-backed
// stdio, used while the decision time limit is armed (#2676). On Windows a timeout kills only the
// direct child; a grandchild it started (bin/scan-outbound.sh's `< <(dd ...)`) can hold a stdin or
// stdout pipe open and keep spawnSync from returning for minutes (measured: 302 s against a 2 s timeout).
// With file stdio the call returns as soon as the direct child exits or is killed.
// maxBuffer still bounds what is read back: a larger output is truncated and raises ENOBUFS as spawnSync does.

const fs = require("fs");
const os = require("os");
const path = require("path");
// Called through the module object at call time, so a patched child_process is honoured.
const childProcess = require("child_process");

const PIPE_ENTRIES = new Set(["pipe", "overlapped"]);
const STREAM_NAMES = ["stdin", "stdout", "stderr"];
const TEMP_PREFIX = "limited-child-process-";

let tempDir = null;
let callCount = 0;

// Best-effort: a grandchild that outlived the call may still hold the file on Windows (EBUSY/EPERM).
function removeQuietly(target, recursive = false) {
  try { fs.rmSync(target, { force: true, recursive }); } catch { /* left for the OS temp cleanup */ }
}

function closeQuietly(fd) {
  try { fs.closeSync(fd); } catch { /* already closed */ }
}

// The files can hold staged blob contents. A hook killed mid-call (its 15 s timeout) never reaches
// the exit cleanup, so the first use in a process removes what such a process left behind.
// STALE_AFTER_MS is far above any armed hook's lifetime, so a live sibling's directory is never taken.
const STALE_AFTER_MS = 10 * 60 * 1000;

function sweepStaleDirs(root) {
  let names = [];
  try { names = fs.readdirSync(root); } catch { return; }
  const cutoff = Date.now() - STALE_AFTER_MS;
  for (const name of names) {
    if (!name.startsWith(TEMP_PREFIX)) continue;
    const dir = path.join(root, name);
    try {
      if (fs.statSync(dir).mtimeMs < cutoff) removeQuietly(dir, true);
    } catch { /* gone or unreadable: leave it */ }
  }
}

function processTempDir() {
  if (tempDir === null) {
    sweepStaleDirs(os.tmpdir());
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), TEMP_PREFIX));
    process.once("exit", () => removeQuietly(dir, true));
    tempDir = dir;
  }
  return tempDir;
}

// A string stdio applies to all three streams; unset entries default to a pipe.
function stdioEntries(stdio) {
  if (typeof stdio === "string") return [stdio, stdio, stdio];
  const entries = Array.isArray(stdio) ? [...stdio] : [];
  while (entries.length < STREAM_NAMES.length) entries.push(undefined);
  return entries;
}

const isPipeEntry = (entry) => entry == null || PIPE_ENTRIES.has(entry);

function inputBytes(input, encoding) {
  if (input == null) return Buffer.alloc(0);
  if (typeof input === "string") return Buffer.from(input, Buffer.isEncoding(encoding) ? encoding : "utf8");
  if (ArrayBuffer.isView(input)) return Buffer.from(input.buffer, input.byteOffset, input.byteLength);
  return Buffer.from(input);
}

// openFiles(options) -> { options, files }: the caller's options with every pipe entry of the three
// streams replaced by a file descriptor. An empty stdin file stands in for Node's closed stdin pipe.
function openFiles(options) {
  const { input, ...rest } = options;
  const stdio = stdioEntries(options.stdio);
  callCount += 1;
  const files = [];
  try {
    const stem = path.join(processTempDir(), String(callCount));
    STREAM_NAMES.forEach((name, index) => {
      if (!isPipeEntry(stdio[index])) return;
      const file = `${stem}.${name}`;
      // Recorded before it exists, so a failed open still removes the file holding the input.
      const entry = { index, file, fd: null };
      files.push(entry);
      if (index === 0) fs.writeFileSync(file, inputBytes(input, options.encoding));
      entry.fd = fs.openSync(file, index === 0 ? "r" : "w");
      stdio[index] = entry.fd;
    });
  } catch (error) {
    releaseFiles(files);
    throw Object.assign(error, { stdioSetupFailed: true });
  }
  return { options: { ...rest, stdio }, files };
}

function releaseFiles(files) {
  for (const { fd, file } of files) {
    closeQuietly(fd);
    removeQuietly(file);
  }
}

// Node's spawnSync default; reading past it would make the read time unbounded by the caller.
const DEFAULT_MAX_BUFFER = 1024 * 1024;

function maxBufferOf(options) {
  const value = options.maxBuffer;
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_MAX_BUFFER;
}

// readBounded(file, maxBuffer) -> { data, overflow, error }: reads at most maxBuffer bytes.
// A failed read returns its error, so the caller never takes it for an empty, successful output.
function readBounded(file, maxBuffer) {
  let fd = null;
  try {
    fd = fs.openSync(file, "r");
    const size = fs.fstatSync(fd).size;
    const data = Buffer.alloc(Math.min(size, maxBuffer));
    let offset = 0;
    while (offset < data.length) {
      const read = fs.readSync(fd, data, offset, data.length - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return { data: data.subarray(0, offset), overflow: size > maxBuffer, error: null };
  } catch (error) {
    return { data: Buffer.alloc(0), overflow: false, error };
  } finally {
    if (fd !== null) closeQuietly(fd);
  }
}

function noBufferError() {
  return Object.assign(new Error("spawnSync ENOBUFS"), { code: "ENOBUFS", errno: "ENOBUFS", syscall: "spawnSync" });
}

// collectOutput(result, files, options): fills stdout / stderr / output the way spawnSync would.
// A child that never started (result.output null with an error) keeps spawnSync's null output.
function collectOutput(result, files, options) {
  for (const { fd } of files) closeQuietly(fd);
  const started = !(result.error && result.output == null);
  const { encoding } = options;
  const decode = Boolean(encoding) && encoding !== "buffer";
  const maxBuffer = maxBufferOf(options);
  for (const { index, file } of files) {
    if (index > 0 && started) {
      const { data, overflow, error } = readBounded(file, maxBuffer);
      if (error && !result.error) result.error = error;
      if (overflow && !result.error) result.error = noBufferError();
      result[STREAM_NAMES[index]] = decode ? data.toString(encoding) : data;
    }
  }
  if (started) result.output = [null, result.stdout, result.stderr];
  releaseFiles(files);
  return result;
}

// Each wrapper takes (command, args, options); args is undefined when the caller gave none.
function spawnSync(command, args, options = {}) {
  const opened = openFiles(options);
  let result = null;
  try {
    result = args === undefined
      ? childProcess.spawnSync(command, opened.options)
      : childProcess.spawnSync(command, args, opened.options);
  } finally {
    if (result === null) releaseFiles(opened.files);
  }
  return collectOutput(result, opened.files, options);
}

// checkedOutput(result, options, commandText) — Node's exec* contract on a spawnSync result.
function checkedOutput(result, options, commandText) {
  const hasStderr = result.stderr != null && result.stderr.length > 0;
  if (!options.stdio && hasStderr) process.stderr.write(result.stderr);
  const { status, signal, output, pid, stdout, stderr } = result;
  const fields = { status, signal, output, pid, stdout, stderr };
  if (result.error) throw Object.assign(result.error, fields);
  if (status !== 0) {
    const message = `Command failed: ${commandText}${hasStderr ? `\n${result.stderr.toString()}` : ""}`;
    throw Object.assign(new Error(message), fields);
  }
  return stdout;
}

function execFileSync(file, args, options = {}) {
  const commandText = [file, ...(args || [])].join(" ");
  return checkedOutput(spawnSync(file, args, options), options, commandText);
}

function execSync(command, _args, options = {}) {
  const result = spawnSync(command, undefined, { ...options, shell: options.shell || true });
  return checkedOutput(result, options, command);
}

module.exports = { spawnSync, execSync, execFileSync };
