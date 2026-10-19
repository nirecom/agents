"use strict";
// Test-only scaffolding for tests/hooks/feature-2681-config-flag.js (#2681): fixture trees that
// hold a copy of hooks/ with an optional load-env stub, a guarded loader, scoped env changes,
// and stdout/stderr capture. Holds no cases of its own.
//
// A stub keeps every load-env export and swaps resolveConfigVar only (the copied original is
// renamed load-env-real.js), so other modules that read load-env keep working. Each variant
// lives in its own directory, so require caches never cross between variants.

const fs = require("node:fs");
const path = require("node:path");

const REPO = path.resolve(__dirname, "..", "..", "..");

const HEAD = '"use strict";\nconst real = require("./load-env-real");\n';
const swap = (fn) => `${HEAD}module.exports = Object.assign({}, real, { resolveConfigVar: ${fn} });\n`;
const MUTATE = 'process.env.CF_NEW = "added"; process.env.CF_MOD = "changed"; delete process.env.CF_DEL;';
const SLEEP = "Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);";

const STUBS = {
  "throw-on-require": '"use strict";\nthrow new Error("stub: load-env throws on require");\n',
  "throw-on-call": swap('function () { throw new Error("stub: resolveConfigVar throws"); }'),
  "load-failed": swap('function () { return { value: "off", loadFailed: true, source: "env-file" }; }'),
  "inject-then-throw": swap(`function () { ${MUTATE} throw new Error("stub: throws after mutating env"); }`),
  "inject-then-load-failed": swap(`function () { ${MUTATE} return { value: "", loadFailed: true, source: "default" }; }`),
  slow: swap(`function (n, d, o) { ${SLEEP} return real.resolveConfigVar(n, d, o); }`),
  "slow-load-failed": swap(`function () { ${SLEEP} return { value: "off", loadFailed: true, source: "env-file" }; }`),
  "throw-for-CONFIRM_CODE": swap(
    'function (n, d, o) { if (n === "CONFIRM_CODE") throw new Error("stub: CONFIRM_CODE throws"); return real.resolveConfigVar(n, d, o); }'
  ),
};

// mkTree(base, variant) -> <base>/<variant>, a directory holding a copy of hooks/.
function mkTree(base, variant) {
  const tree = path.join(base, variant);
  fs.cpSync(path.join(REPO, "hooks"), path.join(tree, "hooks"), { recursive: true });
  if (variant !== "real") {
    if (!STUBS[variant]) throw new Error(`mkTree: unknown variant ${variant}`);
    const lib = path.join(tree, "hooks", "lib");
    fs.renameSync(path.join(lib, "load-env.js"), path.join(lib, "load-env-real.js"));
    fs.writeFileSync(path.join(lib, "load-env.js"), STUBS[variant]);
  }
  return tree;
}

// load(tree, rel) -> the module, or {__loadError} so a missing module fails the case, not the file.
function load(tree, rel) {
  try {
    return require(path.join(tree, ...rel.split("/")));
  } catch (e) {
    return { __loadError: String(e && e.message).split("\n")[0] };
  }
}

// need(mod, name) -> the export, or a thrown error naming what is missing.
function need(mod, name) {
  if (mod && typeof mod[name] !== "undefined") return mod[name];
  const why = mod && mod.__loadError ? `module did not load: ${mod.__loadError}` : "export is absent";
  throw new Error(`missing ${name} (${why})`);
}

// withEnv(vars, fn): set (string) or delete (undefined) each var around fn, then put them back.
function withEnv(vars, fn) {
  const saved = {};
  for (const k of Object.keys(vars)) {
    saved[k] = process.env[k];
    if (vars[k] === undefined) delete process.env[k];
    else process.env[k] = vars[k];
  }
  try {
    return fn();
  } finally {
    for (const k of Object.keys(saved)) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
}

// capture(fn) -> {ret, out, err, exits}: stdout/stderr writes collected, process.exit recorded
// instead of ending the run.
function capture(fn) {
  const out = [];
  const err = [];
  const exits = [];
  const ow = process.stdout.write;
  const ew = process.stderr.write;
  const ox = process.exit;
  process.stdout.write = (c) => { out.push(String(c)); return true; };
  process.stderr.write = (c) => { err.push(String(c)); return true; };
  process.exit = (code) => { exits.push(code); };
  let ret;
  try {
    ret = fn();
  } finally {
    process.stdout.write = ow;
    process.stderr.write = ew;
    process.exit = ox;
  }
  return { ret, out: out.join(""), err: err.join(""), exits };
}

// envSnapshot() -> a canonical string of the whole process.env, for before/after equality.
function envSnapshot() {
  const e = Object.assign({}, process.env);
  return JSON.stringify(Object.keys(e).sort().map((k) => [k, e[k]]));
}

module.exports = { REPO, mkTree, load, need, withEnv, capture, envSnapshot };
