"use strict";
// Section E driver: read the REAL settings.json and report registration facts.
//   --expected-matcher        COMMAND_TOOL_NAMES.join("|") from the SSOT module
//   --matcher-for <substr>    matcher of the PreToolUse entry whose hooks[].command
//                             contains <substr>, or NOT_REGISTERED
//   --covers-command-tools <substr>
//                             yes|no: does that entry's matcher contain every
//                             COMMAND_TOOL_NAMES element as a "|"-delimited token
//   --timeout-for <substr>    the entry's timeout value, or NOT_REGISTERED

const fs = require("fs");
const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || "";
const { COMMAND_TOOL_NAMES } = require(path.join(AGENTS_DIR, "hooks", "lib", "tool-command-text.js"));

const mode = process.argv[2];
if (mode === "--expected-matcher") {
  console.log(COMMAND_TOOL_NAMES.join("|"));
  process.exit(0);
}

let settings;
try {
  settings = JSON.parse(fs.readFileSync(path.join(AGENTS_DIR, "settings.json"), "utf8"));
} catch (e) {
  console.log("SETTINGS_UNREADABLE:" + (e && e.message ? e.message : String(e)));
  process.exit(0);
}

const pre = settings && settings.hooks && Array.isArray(settings.hooks.PreToolUse) ? settings.hooks.PreToolUse : [];
const needle = process.argv[3] || "";
const entry = pre.find((e) =>
  e && Array.isArray(e.hooks) && e.hooks.some((h) => h && typeof h.command === "string" && h.command.indexOf(needle) !== -1));

if (!entry) {
  console.log("NOT_REGISTERED");
  process.exit(0);
}

if (mode === "--matcher-for") {
  console.log(String(entry.matcher));
} else if (mode === "--timeout-for") {
  const h = entry.hooks.find((x) => x && typeof x.command === "string" && x.command.indexOf(needle) !== -1);
  console.log(String(h.timeout));
} else if (mode === "--covers-command-tools") {
  const tokens = String(entry.matcher).split("|");
  console.log(COMMAND_TOOL_NAMES.every((n) => tokens.indexOf(n) !== -1) ? "yes" : "no");
} else {
  console.log("BAD_MODE");
}
