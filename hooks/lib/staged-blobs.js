"use strict";
// hooks/lib/staged-blobs.js — reads every staged blob of a commit scan with one
// `git cat-file --batch` instead of one `git show :<path>` per file (#2676); shared by the
// scan-outbound hook and the pre-commit snapshot (#2507).

const { spawnSync } = require("./limited-child-process");

const READ_TIMEOUT_MS = 10000;
const MAX_BUFFER_BYTES = 256 * 1024 * 1024;
const LINE_FEED = 0x0a;

// parseBatch(stdout, relFiles) -> { blobs } | { unreadable }: one "<sha> <type> <size>\n<content>\n"
// record per requested path, in request order; "<name> missing" or any other header is unreadable.
function parseBatch(stdout, relFiles) {
  const blobs = [];
  let offset = 0;
  for (const rel of relFiles) {
    const headerEnd = stdout.indexOf(LINE_FEED, offset);
    if (headerEnd === -1) return { unreadable: rel };
    const header = stdout.subarray(offset, headerEnd).toString("utf8").split(" ");
    const size = Number(header[2]);
    if (header.length !== 3 || header[1] !== "blob" || !Number.isInteger(size) || size < 0) return { unreadable: rel };
    const contentEnd = headerEnd + 1 + size;
    if (contentEnd >= stdout.length || stdout[contentEnd] !== LINE_FEED) return { unreadable: rel };
    blobs.push({ rel, content: stdout.subarray(headerEnd + 1, contentEnd) });
    offset = contentEnd + 1;
  }
  return { blobs };
}

// readStagedBlobs(repoDir, relFiles) -> { blobs: [{ rel, content: Buffer }] } | { unreadable: <rel or null> }
// null names no single file: git itself failed. A path with a newline cannot be asked for in batch mode.
function readStagedBlobs(repoDir, relFiles) {
  const withNewline = relFiles.find((rel) => rel.includes("\n"));
  if (withNewline !== undefined) return { unreadable: withNewline };
  const result = spawnSync("git", ["cat-file", "--batch"], {
    cwd: repoDir,
    input: relFiles.map((rel) => ":" + rel + "\n").join(""),
    timeout: READ_TIMEOUT_MS,
    maxBuffer: MAX_BUFFER_BYTES,
  });
  if (result.error || result.status !== 0 || !Buffer.isBuffer(result.stdout)) return { unreadable: null };
  return parseBatch(result.stdout, relFiles);
}

module.exports = { readStagedBlobs, parseBatch };
