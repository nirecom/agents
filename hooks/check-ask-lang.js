"use strict";
const { loadLangConfig } = require("./lib/lang-config");
const { hasCJK } = require("./lib/detect-cjk");

const ENGLISH_RUN_RE = /(?:\b[A-Za-z]{2,}\b[^\S\n]+){3,}\b[A-Za-z]{2,}\b/;

const policy = loadLangConfig("ask", undefined);

let raw = "";
process.stdin.on("data", d => { raw += d; });
process.stdin.on("end", () => {
  let payload;
  try { payload = JSON.parse(raw); } catch { allow(); return; }

  if (payload.tool_name !== "AskUserQuestion" || policy === "any") { allow(); return; }

  const ti = payload.tool_input || {};
  const texts = [];
  if (typeof ti.question === "string") texts.push(ti.question);
  if (Array.isArray(ti.choices)) {
    for (const c of ti.choices) if (typeof c === "string") texts.push(c);
  }

  const offending = texts.filter(t =>
    policy === "english" ? hasCJK(t) :
    policy === "japanese" ? (!hasCJK(t) && ENGLISH_RUN_RE.test(t)) :
    false
  );

  if (offending.length === 0) { allow(); return; }

  process.stdout.write(JSON.stringify({
    decision: "approve",
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext:
        `ASK_LANG=${policy}: the following AskUserQuestion text may violate the policy:\n` +
        offending.map(t => `  - "${t.slice(0, 80)}"`).join("\n") +
        "\nConsider rewriting before presenting."
    }
  }) + "\n");
  process.exit(0);
});

function allow() {
  process.stdout.write(JSON.stringify({ decision: "approve" }) + "\n");
  process.exit(0);
}
