#!/usr/bin/env node
"use strict";
// bin/request-off-clearance.d/parse-verdict.js — extracted from bin/request-off-clearance
// under the file-split HARD limit (rules/coding/file-split.md). Sibling folder is
// named "request-off-clearance.d" (not the bare "request-off-clearance/" the rule's
// pattern would otherwise use) because the entrypoint itself is an extensionless file
// named "request-off-clearance" — a same-named directory cannot coexist with it.
//
// Reads the examiner's stdout (CODEX_STDOUT) and this invocation's nonce (CODEX_NONCE)
// from env, and writes "<verdict>\t<reason>" to stdout when a JSON verdict object bound
// to that nonce is found.
//
// Structured parse (never regex-scraping): scans for the last NONCE-BOUND JSON object in
// stdout — one whose `nonce` equals this invocation's — and reads .verdict / .reason from
// it. Exit 0: parsed a nonce-bound verdict (stdout carries it). Exit 1: no parseable JSON
// object found. Exit 2: JSON objects found but none carried this invocation's nonce — an
// unauthenticated/echoed verdict was discarded (see the codex HIGH-3 note in
// ../request-off-clearance for what "nonce-bound" does and does not guarantee).

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
// The nonce is the ONLY thing that separates an answer produced by a process that read
// THIS prompt from a verdict-shaped object echoed out of the request text, so it is
// checked before anything else is read off the object. It binds the object to this
// invocation's prompt context — it does NOT authenticate the examiner's identity or
// independence (see the codex HIGH-3 note in ../request-off-clearance). An empty `want`
// can never match, which keeps this fail-closed if the nonce ever fails to reach this
// process.
const authentic = want === "" ? [] : objs.filter(
  (o) => Object.prototype.hasOwnProperty.call(o, "nonce") && o.nonce === want
);
if (authentic.length === 0) process.exit(2);
const last = authentic[authentic.length - 1];
const flat = (v) => (typeof v === "string" ? v.replace(/[\t\r\n]+/g, " ").trim() : "");
process.stdout.write(flat(last.verdict) + "\t" + flat(last.reason));
