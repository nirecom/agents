"use strict";
// tests/fixtures/agents-config-dir-probe.js
// CLI probe over hooks/lib/agents-config-dir.js (#1630).
//
// Usage: node agents-config-dir-probe.js <op> [args...]
//
// Prints exactly one line and always exits 0 so the bash caller can assert on
// the text (including the `ERROR: ...` form emitted while the module is still
// missing, which is the expected RED signal before C4 lands).

const path = require("path");

const AGENTS_DIR = path.resolve(__dirname, "..", "..");
const MODULE_PATH = path.join(AGENTS_DIR, "hooks", "lib", "agents-config-dir.js");

// Keep every emission on ONE line — the bash caller compares whole-output.
const line1 = (s) => String(s).split("\n")[0];

let mod = null;
try {
  mod = require(MODULE_PATH);
} catch (e) {
  console.log("ERROR: require agents-config-dir.js: " + line1(e.message));
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

// "env:/a,module:/b,realpath:/c" -> [{dir,source}, ...]
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

try {
  switch (op) {
    // Ordered `source` labels produced by configDirCandidates().
    case "sources": {
      const f = need("configDirCandidates");
      console.log(f().map((c) => c.source).join(","));
      break;
    }
    // Absolute dir of the candidate whose source === a1 (forward-slashed).
    case "canddir": {
      const f = need("configDirCandidates");
      const hit = f().find((c) => c.source === a1);
      console.log(hit ? show(hit.dir) : "null");
      break;
    }
    // Windows-POSIX env candidate. a1 is a WINDOWS path (C:/x/y); the /c/x/y
    // form is derived HERE rather than exported from bash, because MSYS2/Git
    // Bash rewrites POSIX-looking env values back to Windows form when it
    // spawns native node.exe — exporting it would be a false green.
    case "canddir-posixenv": {
      const win = a1;
      process.env.AGENTS_CONFIG_DIR = "/" + win[0].toLowerCase() + win.slice(2);
      const f = need("configDirCandidates");
      const hit = f().find((c) => c.source === "env");
      console.log(hit ? show(hit.dir) : "null");
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
      const f = need("resolveAgentsConfigDir");
      const a = f();
      const b = f();
      console.log("same=" + (a === b) + ",null=" + (a === null || a === undefined));
      break;
    }
    // resolveAgentsConfigDir() against the real filesystem.
    case "resolve": {
      const f = need("resolveAgentsConfigDir");
      console.log(show(f()));
      break;
    }
    // Debug-fallback contract. Captures everything the resolver writes to
    // stderr during ONE resolveAgentsConfigDir() call and reports:
    //   lines=<n>   how many stderr lines were emitted
    //   leak=<bool> whether a1 (a secret canary embedded in the stale env value)
    //               appears anywhere in that output — must always be false
    //   source=<s>  the adopted source named in the message, or "none"
    // a1 is optional; when empty, leak is reported as false.
    case "debugline": {
      const f = need("resolveAgentsConfigDir");
      const chunks = [];
      const origWrite = process.stderr.write.bind(process.stderr);
      process.stderr.write = (c) => { chunks.push(String(c)); return true; };
      try { f(); } finally { process.stderr.write = origWrite; }
      const text = chunks.join("");
      const lines = text.split("\n").filter((s) => s.trim() !== "");
      const m = text.match(/source[^A-Za-z0-9]{0,3}(env|module|realpath)/i);
      const leak = a1 ? text.indexOf(a1) !== -1 : false;
      console.log("lines=" + lines.length + ",leak=" + leak +
                  ",source=" + (m ? m[1].toLowerCase() : "none"));
      break;
    }
    // Cache reset, successful resolution. a1 and a2 are two marker-valid dirs.
    // The second call must return the memoized first answer even though the env
    // changed; after _resetCacheForTest() the new env value must win.
    case "recompute": {
      const f = need("resolveAgentsConfigDir");
      const reset = need("_resetCacheForTest");
      const norm = (p) => String(p).replace(/\\/g, "/").toLowerCase().replace(/\/+$/, "");
      process.env.AGENTS_CONFIG_DIR = a1;
      const first = f();
      process.env.AGENTS_CONFIG_DIR = a2;
      const cached = f();
      reset();
      const after = f();
      console.log("first_is_a1=" + (norm(first) === norm(a1)) +
                  ",cached_same=" + (cached === first) +
                  ",after_is_a2=" + (norm(after) === norm(a2)));
      break;
    }
    // Cache reset, CACHED-NULL resolution. fs.existsSync is forced false for the
    // first call so every candidate fails validation and the resolver caches
    // null; the negative answer must be memoized too, and must be recomputed
    // after _resetCacheForTest().
    case "recompute-null": {
      const f = need("resolveAgentsConfigDir");
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
