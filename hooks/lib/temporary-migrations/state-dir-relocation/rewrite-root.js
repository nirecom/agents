"use strict";
// Temporary (#2511): deleted with this folder per the deletion-condition in state-root.js
// Rewrites absolute paths under the legacy root into the new root inside a copied file.
// Each spelling keeps its own form: native, JSON-escaped, slash, MSYS (/c/...), tilde.
// A match must end at a separator, a quote, a line end or the end of the text, so a
// sibling dir sharing the prefix (workflow2/) is never rewritten.
const path = require("path");

const TILDE = ["~/.claude/projects/workflow", "~/.workflow-state"];
const BOUNDARY = "(?=[\\\\/\"'\\r\\n]|$)";
const FOLD = process.platform === "win32";

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function spellings(root) {
  const native = path.normalize(root);
  const slash = native.replace(/\\/g, "/");
  const msys = /^[A-Za-z]:\//.test(slash) ? `/${slash[0].toLowerCase()}${slash.slice(2)}` : null;
  return [native, native.replace(/\\/g, "\\\\"), slash, msys];
}

function keyOf(s) {
  return FOLD ? s.toLowerCase() : s;
}

// buildRewriter({ oldRoot, newRoot }) -> (text) => text
function buildRewriter({ oldRoot, newRoot }) {
  const from = spellings(oldRoot);
  const to = spellings(newRoot);
  const map = new Map();
  from.forEach((f, i) => {
    if (f && to[i] && !map.has(keyOf(f))) map.set(keyOf(f), to[i]);
  });
  map.set(keyOf(TILDE[0]), TILDE[1]);
  const alts = [...map.keys()].sort((a, b) => b.length - a.length).map(escapeRe);
  const re = new RegExp(`(?:${alts.join("|")})${BOUNDARY}`, FOLD ? "gi" : "g");
  return (text) => text.replace(re, (m) => map.get(keyOf(m)));
}

// rewriteBuffer(buf, rewrite) -> the rewritten Buffer, or null when the file is binary
// (holds a NUL or is not round-trip UTF-8) and must be copied byte for byte.
function rewriteBuffer(buf, rewrite) {
  if (buf.includes(0)) return null;
  const text = buf.toString("utf8");
  if (!Buffer.from(text, "utf8").equals(buf)) return null;
  return Buffer.from(rewrite(text), "utf8");
}

module.exports = { buildRewriter, rewriteBuffer };
