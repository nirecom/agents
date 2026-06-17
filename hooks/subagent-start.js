#!/usr/bin/env node
// Claude Code SubagentStart hook: inject conversation language directive into subagent context

const fs = require("fs");
const { getConvLangInjection } = require("./lib/conv-lang");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

try {
  JSON.parse(readStdin());
} catch (e) {
  // fail-open: treat parse errors as {}
}

const lines = [];
try {
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
} catch (_e) { /* fail-open */ }

if (lines.length === 0) {
  console.log("{}");
} else {
  console.log(JSON.stringify({ additionalContext: lines.join("\n") }));
}
