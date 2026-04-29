#!/usr/bin/env node
// PreToolUse hook: show a diff preview of Edit/Write/MultiEdit/editFiles
// operations as a systemMessage. Never blocks or outputs a decision field.

"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");

const MAX_DIFF = 3000;

// ── stdin ─────────────────────────────────────────────────────────────────────

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

// ── output helpers ────────────────────────────────────────────────────────────

function noopExit() {
  process.stdout.write("");
  process.exit(0);
}

function showAndExit(header, diffText) {
  const truncated = diffText.length > MAX_DIFF;
  const displayDiff = truncated
    ? diffText.slice(0, MAX_DIFF) + "\n... (diff truncated)"
    : diffText;

  const message = `DIFF PREVIEW — ${header}\n\n${displayDiff}`;
  process.stdout.write(JSON.stringify({ systemMessage: message }));
  process.exit(0);
}

// ── test-file detection ───────────────────────────────────────────────────────

function isTestFile(filePath) {
  if (!filePath) return false;
  const p = filePath.replace(/\\/g, "/");
  const parts = p.split("/").filter(Boolean);

  // Any directory component named test, tests, spec, specs, __tests__
  for (let i = 0; i < parts.length - 1; i++) {
    if (/^tests?$|^specs?$|^__tests?__$/.test(parts[i])) return true;
  }

  // Filename patterns: foo_test.py, foo.test.ts, foo.spec.ts, test_foo.py, foo.Tests.ps1
  const base = parts[parts.length - 1] || "";
  return (
    /(_test|\.test|\.spec)\.[^.]+$/.test(base) ||
    /^test_/.test(base) ||
    /\.Tests\.ps1$/.test(base)
  );
}

// ── diff generation ───────────────────────────────────────────────────────────

function makeDiff(oldStr, newStr, label) {
  const dir = os.tmpdir();
  const ts = Date.now();
  const tmpOld = path.join(dir, `sd-old-${ts}`);
  const tmpNew = path.join(dir, `sd-new-${ts}`);
  try {
    fs.writeFileSync(tmpOld, oldStr);
    fs.writeFileSync(tmpNew, newStr);
    const r = spawnSync("diff", [
      "-u",
      "--label", `a/${label}`,
      "--label", `b/${label}`,
      tmpOld,
      tmpNew,
    ]);
    return (r.stdout || Buffer.alloc(0)).toString("utf8");
  } catch (_) {
    return "(diff failed)";
  } finally {
    try { fs.unlinkSync(tmpOld); } catch (_) {}
    try { fs.unlinkSync(tmpNew); } catch (_) {}
  }
}

// ── main ──────────────────────────────────────────────────────────────────────

if (require.main === module) {
  let input = {};
  try {
    input = JSON.parse(readStdin());
  } catch (_) {
    noopExit();
  }

  const WATCHED = new Set(["Write", "Edit", "MultiEdit", "editFiles"]);
  if (!WATCHED.has(input.tool_name)) noopExit();

  const ti = input.tool_input || {};
  const filePath = ti.file_path || "";

  if (!filePath) noopExit();
  if (isTestFile(filePath)) noopExit();

  // ── build diff text ─────────────────────────────────────────────────────────

  if (input.tool_name === "Write" || input.tool_name === "editFiles") {
    const content = ti.content || "";
    const preview = content.slice(0, 400);
    const diffText =
      `[Write ${content.length} chars to ${filePath}]\n\n` +
      preview +
      (content.length > 400 ? "\n... (truncated)" : "");
    showAndExit(filePath, diffText);
  } else if (input.tool_name === "MultiEdit") {
    const edits = Array.isArray(ti.edits) ? ti.edits : [];
    if (edits.length === 0) noopExit();
    const diffText = edits
      .map((e, i) => {
        const d = makeDiff(e.old_string || "", e.new_string || "", filePath);
        return `--- edit ${i + 1} ---\n${d}`;
      })
      .join("\n");
    showAndExit(filePath, diffText);
  } else {
    // Edit
    const oldStr = ti.old_string || "";
    const newStr = ti.new_string || "";
    const diffText = makeDiff(oldStr, newStr, filePath);
    showAndExit(filePath, diffText);
  }
}
