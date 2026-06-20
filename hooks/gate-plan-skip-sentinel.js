#!/usr/bin/env node
"use strict";
const fs = require("fs");
try { require("./lib/load-env").loadDefaultEnv(); } catch (_e) { /* fail-open */ }
const { OUTLINE_NOT_NEEDED_RE_DQ, DETAIL_NOT_NEEDED_RE_DQ } =
  require("./lib/sentinel-patterns");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function passThrough() { console.log("{}"); process.exit(0); }

function allow(reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

const OFF_LITERALS = new Set(["off"]);

function isOff(name) {
  const raw = process.env[name];
  return raw != null && OFF_LITERALS.has(String(raw).trim().toLowerCase());
}

let input;
try { input = JSON.parse(readStdin()); } catch (_e) { passThrough(); }
if (!input || input.tool_name !== "Bash") passThrough();
const cmd = ((input.tool_input && input.tool_input.command) || "").trim();
if (!cmd) passThrough();

if (OUTLINE_NOT_NEEDED_RE_DQ.test(cmd) && isOff("CONFIRM_OUTLINE"))
  allow("CONFIRM_OUTLINE=off — outline skip auto-approved.");
if (DETAIL_NOT_NEEDED_RE_DQ.test(cmd) && isOff("CONFIRM_DETAIL"))
  allow("CONFIRM_DETAIL=off — detail skip auto-approved.");

passThrough();
