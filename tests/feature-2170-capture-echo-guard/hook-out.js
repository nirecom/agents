"use strict";
// Classify a PreToolUse hook's stdout into one stable token so bash asserts on a
// verdict rather than on wording. Prints one of:
//   block        - decision "block" AND hookSpecificOutput.permissionDecision "deny",
//                  with a non-empty reason in BOTH fields (the dual-field contract)
//   deny-partial - denies, but the dual-field contract is not fully satisfied
//   allow        - hookSpecificOutput.permissionDecision === "allow"
//   passthrough  - "{}" (no keys)
//   other:<...>  - anything else, or unparsable stdout

const fs = require("fs");

const file = process.argv[2];
let text;
try {
  text = fs.readFileSync(file, "utf8").trim();
} catch (_e) {
  console.log("other:UNREADABLE");
  process.exit(0);
}

let obj;
try {
  obj = JSON.parse(text);
} catch (_e) {
  console.log("other:NOT_JSON:" + text.slice(0, 120));
  process.exit(0);
}

if (!obj || typeof obj !== "object") {
  console.log("other:NOT_OBJECT");
  process.exit(0);
}

const hso = obj.hookSpecificOutput && typeof obj.hookSpecificOutput === "object" ? obj.hookSpecificOutput : {};
const denies = obj.decision === "block" || hso.permissionDecision === "deny";

if (denies) {
  const full =
    obj.decision === "block" &&
    hso.hookEventName === "PreToolUse" &&
    hso.permissionDecision === "deny" &&
    typeof obj.reason === "string" && obj.reason.trim() !== "" &&
    typeof hso.permissionDecisionReason === "string" && hso.permissionDecisionReason.trim() !== "";
  console.log(full ? "block" : "deny-partial");
  process.exit(0);
}

if (hso.permissionDecision === "allow") {
  console.log("allow");
  process.exit(0);
}

if (Object.keys(obj).length === 0) {
  console.log("passthrough");
  process.exit(0);
}

console.log("other:" + JSON.stringify(obj).slice(0, 160));
