#!/usr/bin/env node
"use strict";
// Sibling folder named "request-off-clearance.d", not bare "request-off-clearance/",
// since the entrypoint is an extensionless file of that same name.
//
// Reads the examiner's stdout (CODEX_STDOUT) + this invocation's nonce (CODEX_NONCE),
// scans for the last JSON object whose `nonce` matches, and writes "<verdict>\t<reason>".
// Exit 0: found. Exit 1: no parseable JSON object. Exit 2: JSON found but nonce mismatch
// (unauthenticated/echoed verdict discarded).

const s = process.env.CODEX_STDOUT || "";
const want = process.env.CODEX_NONCE || "";
const objs = [];
for (let i = 0; i < s.length; i++) {
  if (s[i] !== "{") continue;
  let depth = 0, inStr = false, esc = false;
  for (let j = i; j < s.length; j++) {
    const c = s[j];
    if (inStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === "\"") inStr = false;
      continue;
    }
    if (c === "\"") { inStr = true; continue; }
    if (c === "{") { depth++; continue; }
    if (c !== "}") continue;
    depth--;
    if (depth !== 0) continue;
    try {
      const o = JSON.parse(s.slice(i, j + 1));
      if (o && typeof o === "object" && !Array.isArray(o)) objs.push(o);
    } catch (_e) { /* not JSON — skip */ }
    i = j;
    break;
  }
}
if (objs.length === 0) process.exit(1);
// Nonce binds the object to this invocation's prompt context — it does not authenticate
// examiner identity/independence. Empty `want` never matches, keeping this fail-closed.
const authentic = want === "" ? [] : objs.filter(
  (o) => Object.prototype.hasOwnProperty.call(o, "nonce") && o.nonce === want
);
if (authentic.length === 0) process.exit(2);
const last = authentic[authentic.length - 1];
const flat = (v) => (typeof v === "string" ? v.replace(/[\t\r\n]+/g, " ").trim() : "");
process.stdout.write(flat(last.verdict) + "\t" + flat(last.reason));
