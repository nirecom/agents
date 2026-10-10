"use strict";
// tests/fixtures/script-checkout-root-probe.js
// CLI probe over hooks/lib/script-checkout-root.js (#1630, #2561).
// Usage: node script-checkout-root-probe.js <op> [args...]
//
// Prints exactly one line and always exits 0 so the bash caller can assert on
// the text (including the `ERROR: ...` form emitted when the module cannot be
// loaded or an export is gone).
// No op writes AGENTS_MAIN_ROOT: the resolver has no env candidate, so the bash
// caller sets the variable itself whenever a row asserts that it is ignored.

const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const MODULE_PATH = path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "script-checkout-root.js");

// Keep every emission on ONE line — the bash caller compares whole-output.
const line1 = (s) => String(s).split("\n")[0];

let mod = null;
try {
  mod = require(MODULE_PATH);
} catch (e) {
  console.log("ERROR: require script-checkout-root.js: " + line1(e.message));
  process.exit(0);
}

const op = process.argv[2] || "";
const a1 = process.argv[3] || "";
const a2 = process.argv[4] || "";

function need(name) {
  if (typeof mod[name] !== "function") {
    console.log("ERROR: " + name + " is not exported");
    process.exit(0);
  }
  return mod[name];
}

// "/a/b;/a/b/bin" -> normalized lookup set (forward slashes, lowercased)
function pathSet(spec) {
  const s = new Set();
  for (const raw of spec.split(";")) {
    const t = raw.trim();
    if (t) s.add(t.replace(/\\/g, "/").toLowerCase().replace(/\/+$/, ""));
  }
  return s;
}

// "module:/a,realpath:/b" -> [{dir,source}, ...]
function parseCandidates(spec) {
  const out = [];
  for (const raw of spec.split(",")) {
    const t = raw.trim();
    if (!t) continue;
    const i = t.indexOf(":");
    out.push({ source: t.slice(0, i), dir: t.slice(i + 1) });
  }
  return out;
}

function show(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "string") return v.replace(/\\/g, "/");
  return String(v);
}

// lines=<n> stderr lines; leak=<bool> the caller's canary (a segment of its
// AGENTS_MAIN_ROOT value) appears; root_leak=<bool> the RESOLVED root appears,
// whatever its slashes or case; source=<s> the adopted source, or "none" (`env`
// stays in the pattern so adopting the variable reads source=env, not "none").
function describeDebug(text, resolved, canary) {
  const flat = (s) => String(s).replace(/\\/g, "/").toLowerCase();
  const lines = text.split("\n").filter((s) => s.trim() !== "");
  const m = text.match(/source[^A-Za-z0-9]{0,3}(env|module|realpath)/i);
  const leak = canary ? text.indexOf(canary) !== -1 : false;
  const rootLeak = resolved ? flat(text).indexOf(flat(resolved)) !== -1 : false;
  return "lines=" + lines.length + ",leak=" + leak + ",root_leak=" + rootLeak +
         ",source=" + (m ? m[1].toLowerCase() : "none");
}

try {
  switch (op) {
    // Ordered `source` labels produced by scriptCheckoutRootCandidates().
    case "sources": {
      const f = need("scriptCheckoutRootCandidates");
      console.log(f().map((c) => c.source).join(","));
      break;
    }
    // Absolute dir of the candidate whose source === a1 (forward-slashed).
    case "canddir": {
      const f = need("scriptCheckoutRootCandidates");
      const hit = f().find((c) => c.source === a1);
      console.log(hit ? show(hit.dir) : "null");
      break;
    }
    // Whether a1 is the dir of ANY candidate. Both sides go through normDir so
    // a slash or drive-letter-case difference cannot hide a match.
    case "canddir-present": {
      const f = need("scriptCheckoutRootCandidates");
      const n = need("normDir");
      const key = (p) => String(n(p)).toLowerCase();
      console.log(String(f().some((c) => key(c.dir) === key(a1))));
      break;
    }
    // normDir(a1) verbatim.
    case "normdir": {
      console.log(show(need("normDir")(a1)));
      break;
    }
    // normDir on the Windows-POSIX form. a1 is a WINDOWS path (C:/x/y); the
    // /c/x/y form is derived HERE rather than passed from bash, because
    // MSYS2/Git Bash rewrites POSIX-looking values back to Windows form when it
    // spawns native node.exe — passing it would be a false green.
    case "normdir-posix": {
      const posix = "/" + a1[0].toLowerCase() + a1.slice(2);
      console.log(show(need("normDir")(posix)));
      break;
    }
    // _resolveFromCandidates(candidates, opts) with an injected existsSync.
    // a1 = candidate spec, a2 = ';'-separated set of paths that "exist".
    case "pick": {
      const f = need("_resolveFromCandidates");
      const set = pathSet(a2);
      const existsSync = (p) =>
        set.has(String(p).replace(/\\/g, "/").toLowerCase().replace(/\/+$/, ""));
      console.log(show(f(parseCandidates(a1), { existsSync })));
      break;
    }
    // Process memoization: two calls must return the identical string.
    case "memo": {
      const f = need("resolveScriptCheckoutRoot");
      const a = f();
      const b = f();
      console.log("same=" + (a === b) + ",null=" + (a === null || a === undefined));
      break;
    }
    // resolveScriptCheckoutRoot() against the real filesystem.
    case "resolve": {
      const f = need("resolveScriptCheckoutRoot");
      console.log(show(f()));
      break;
    }
    // Debug-line contract: everything the resolver writes to stderr during ONE
    // resolveScriptCheckoutRoot() call, reported by describeDebug() below.
    case "debugline": {
      const f = need("resolveScriptCheckoutRoot");
      const chunks = [];
      const origWrite = process.stderr.write.bind(process.stderr);
      process.stderr.write = (c) => { chunks.push(String(c)); return true; };
      let got;
      try { got = f(); } finally { process.stderr.write = origWrite; }
      console.log(describeDebug(chunks.join(""), got, a1));
      break;
    }
    // Anti-vacuity for root_leak: the same report over a synthetic line that DOES
    // carry the resolved root (backslashed and upper-cased) must answer true.
    case "debugline-selfcheck": {
      const got = need("resolveScriptCheckoutRoot")();
      const leaky = "[x] resolved from source=module dir=" +
        String(got).replace(/\//g, "\\").toUpperCase() + "\n";
      console.log(describeDebug(leaky, got, a1));
      break;
    }
    // Cache reset, successful resolution. a1 is the expected checkout root.
    // fs.existsSync is forced false AFTER the first call: the second call must
    // still return the memoized first answer, and only after
    // _resetCacheForTest() may the recomputed (now null) answer appear.
    case "recompute": {
      const f = need("resolveScriptCheckoutRoot");
      const reset = need("_resetCacheForTest");
      const fs = require("fs");
      const norm = (p) => String(p).replace(/\\/g, "/").toLowerCase().replace(/\/+$/, "");
      const first = f();
      const origExists = fs.existsSync;
      fs.existsSync = () => false;
      let cached, after;
      try {
        cached = f();
        reset();
        after = f();
      } finally {
        fs.existsSync = origExists;
      }
      console.log("first_is_a1=" + (norm(first) === norm(a1)) +
                  ",cached_same=" + (cached === first) +
                  ",after_null=" + (after === null || after === undefined));
      break;
    }
    // Cache reset, CACHED-NULL resolution. fs.existsSync is forced false for the
    // first call so every candidate fails validation and the resolver caches
    // null; the negative answer must be memoized too, and must be recomputed
    // after _resetCacheForTest().
    case "recompute-null": {
      const f = need("resolveScriptCheckoutRoot");
      const reset = need("_resetCacheForTest");
      const fs = require("fs");
      const origExists = fs.existsSync;
      fs.existsSync = () => false;
      let first;
      try { first = f(); } finally { fs.existsSync = origExists; }
      const cached = f();
      reset();
      const after = f();
      console.log("first=" + show(first) + ",cached=" + show(cached) +
                  ",after_null=" + (after === null || after === undefined));
      break;
    }
    default:
      console.log("ERROR: unknown op " + JSON.stringify(op));
  }
} catch (e) {
  console.log("ERROR: threw " + line1(e.message));
}
