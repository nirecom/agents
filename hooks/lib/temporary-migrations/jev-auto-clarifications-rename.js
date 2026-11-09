"use strict";
// --- BEGIN temporary: JEV_AUTO_SKIP_ASKUSER -> JEV_AUTO_CLARIFICATIONS migration added 2026-11-09 ---
// deletion-condition: no host's .env, .env.local or shell export still sets JEV_AUTO_SKIP_ASKUSER
// The only reader of the old flag name. The new name wins whenever it is set; only while it is
// unset is the old one honoured, so a user's old "off" stays off, with one stderr line per process.
const { resolveConfigVar } = require("../load-env");

const NEW_NAME = "JEV_AUTO_CLARIFICATIONS";
const OLD_NAME = "JEV_AUTO_SKIP_ASKUSER";
const DEFAULT = "on";
let warned = false;

// resolveClarificationsFlag() -> {value, source, loadFailed, name}.
function resolveClarificationsFlag() {
  const cur = resolveConfigVar(NEW_NAME, DEFAULT);
  if (cur.source !== "default") return Object.assign({ name: NEW_NAME }, cur);
  const old = resolveConfigVar(OLD_NAME, "");
  if (old.source === "default") return Object.assign({ name: NEW_NAME }, cur);
  if (!warned) {
    warned = true;
    process.stderr.write(`warning: ${OLD_NAME} is renamed to ${NEW_NAME}; set ${NEW_NAME} in .env and remove ${OLD_NAME}\n`);
  }
  return Object.assign({ name: OLD_NAME }, old);
}

module.exports = { resolveClarificationsFlag, NEW_NAME, OLD_NAME };
// --- END temporary: JEV_AUTO_SKIP_ASKUSER -> JEV_AUTO_CLARIFICATIONS migration ---
