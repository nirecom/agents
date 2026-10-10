#!/usr/bin/env node
"use strict";
// Builds the root decoy: a tree of stubs mirroring this checkout's tracked bin/hooks/skills
// paths. Every script stub records one hit under <tree>/hits/ and exits non-zero, so a test
// that resolves code or settings through the wrong root fails loudly instead of silently
// running the developer's real checkout.
// Usage:
//   root-decoy-build.js --out <dir>                    build <dir>/main and <dir>/old (atomic, no-op when present)
//   root-decoy-build.js --single <dir> --marker <v>    build one tree directly under <dir>
//   root-decoy-build.js --print-retired-env-names [--retired-names-from <file>]
//   root-decoy-build.js --cache-key
// Exit: 0 ok, 1 build failure, 2 usage error or unreadable retired-name list.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const MIRRORED_PREFIXES = ["bin", "hooks", "skills"];
const RETIRED_NAMES_FILE = path.join(SCRIPT_CHECKOUT_ROOT, "tests", "bin", "feature-2561-root-names-residue.sh");
const REGION_BEGIN = "# retired-names:begin";
const REGION_END = "# retired-names:end";
const STUB_TAG = "ROOT-DECOY-STUB";
const STUB_EXIT = 97;
const HITS_DIRNAME = "hits";
const MARKER_KEY = "ROOT_DECOY_MARKER";

function die(code, msg) {
  process.stderr.write(`root-decoy-build: ${msg}\n`);
  process.exit(code);
}

// Git Bash hands over /c/... paths that fs.* cannot open on Windows.
function toNative(p) {
  if (process.platform !== "win32") return p;
  const m = /^\/([A-Za-z])(\/.*)?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
}

function listPaths() {
  let out;
  try {
    out = execFileSync("git", ["-C", SCRIPT_CHECKOUT_ROOT, "ls-files", "-z", "--", ...MIRRORED_PREFIXES], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (err) {
    die(1, `cannot list tracked files of ${SCRIPT_CHECKOUT_ROOT}: ${String(err.message).split("\n")[0]}`);
  }
  const paths = out.split("\0").filter((p) => p.length > 0);
  for (const p of paths) {
    if (path.isAbsolute(p) || p.split("/").includes("..")) die(1, `refusing a tracked path that escapes the tree: ${p}`);
  }
  return paths.sort();
}

function stubKind(rel) {
  const ext = path.extname(rel).toLowerCase();
  if (ext === ".mjs") return "node-esm";
  if (ext === ".js" || ext === ".cjs") return "node";
  if (ext === ".sh" || ext === ".bash") return "bash";
  if (ext === ".ps1" || ext === ".psm1") return "pwsh";
  if (ext === ".py") return "python";
  if (ext !== "") return "data";
  let head = "";
  try {
    const fd = fs.openSync(path.join(SCRIPT_CHECKOUT_ROOT, rel), "r");
    const buf = Buffer.alloc(160);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    head = buf.slice(0, n).toString("utf8").split("\n")[0];
  } catch (_) {
    return "data";
  }
  if (!head.startsWith("#!")) return "data";
  if (/\bnode\b/.test(head)) return "node";
  if (/\bpython[0-9.]*\b/.test(head)) return "python";
  if (/\bpwsh\b|\bpowershell\b/.test(head)) return "pwsh";
  if (/\b(ba|z|da|k)?sh\b/.test(head)) return "bash";
  return "data";
}

// The stub finds hits/ from its own location, never from the environment.
function upFromStub(rel) {
  const depth = rel.split("/").length - 1;
  return depth === 0 ? "." : new Array(depth).fill("..").join("/");
}

function oneLine(s) {
  return s.replace(/[\r\n]/g, "?");
}

function shSingleQuote(s) {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function stubBody(kind, relRaw) {
  const rel = oneLine(relRaw);
  const up = upFromStub(relRaw);
  if (kind === "node" || kind === "node-esm") {
    const head = kind === "node"
      ? '"use strict";\nconst fs = require("fs");\nconst path = require("path");\nconst here = __dirname;'
      : 'import fs from "node:fs";\nimport path from "node:path";\nimport { fileURLToPath } from "node:url";\nconst here = path.dirname(fileURLToPath(import.meta.url));';
    return [
      "#!/usr/bin/env node",
      `// ${STUB_TAG}`,
      head,
      `const rel = ${JSON.stringify(rel)};`,
      `const hits = path.join(here, ${JSON.stringify(up)}, ${JSON.stringify(HITS_DIRNAME)});`,
      'const id = String(process.env.ROOT_DECOY_TEST_ID || "").replace(/[\\r\\n]/g, "?");',
      "try {",
      "  fs.mkdirSync(hits, { recursive: true });",
      "  const name = `${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.hit`;",
      "  fs.appendFileSync(path.join(hits, name), `stub=${rel}\\ntest_id=${id}\\n`);",
      "} catch (_) {}",
      "try { fs.writeSync(2, `root-decoy: stub reached: ${rel}\\n`); } catch (_) {}",
      `process.exit(${STUB_EXIT});`,
      "",
    ].join("\n");
  }
  if (kind === "bash") {
    return [
      "#!/usr/bin/env bash",
      `# ${STUB_TAG}`,
      `_root_decoy_rel=${shSingleQuote(rel)}`,
      '_root_decoy_self="${BASH_SOURCE[0]:-$0}"',
      'case "$_root_decoy_self" in */*) _root_decoy_here="${_root_decoy_self%/*}" ;; *) _root_decoy_here="." ;; esac',
      `_root_decoy_hits="$_root_decoy_here/${up}/${HITS_DIRNAME}"`,
      '_root_decoy_id="${ROOT_DECOY_TEST_ID:-}"',
      "_root_decoy_id=\"${_root_decoy_id//$'\\n'/?}\"",
      "printf 'stub=%s\\ntest_id=%s\\n' \"$_root_decoy_rel\" \"$_root_decoy_id\" >>\"$_root_decoy_hits/${BASHPID:-$$}-$RANDOM$RANDOM.hit\" 2>/dev/null",
      "printf 'root-decoy: stub reached: %s\\n' \"$_root_decoy_rel\" >&2",
      "unset _root_decoy_rel _root_decoy_self _root_decoy_here _root_decoy_hits _root_decoy_id",
      `return ${STUB_EXIT} 2>/dev/null || exit ${STUB_EXIT}`,
      "",
    ].join("\n");
  }
  if (kind === "python") {
    return [
      "#!/usr/bin/env python3",
      `# ${STUB_TAG}`,
      "import os",
      "import random",
      "import sys",
      `_rel = ${JSON.stringify(rel)}`,
      `_hits = os.path.join(os.path.dirname(os.path.abspath(__file__)), ${JSON.stringify(up)}, ${JSON.stringify(HITS_DIRNAME)})`,
      '_id = os.environ.get("ROOT_DECOY_TEST_ID", "").replace("\\r", "?").replace("\\n", "?")',
      "try:",
      "    os.makedirs(_hits, exist_ok=True)",
      '    with open(os.path.join(_hits, "%d-%d.hit" % (os.getpid(), random.getrandbits(48))), "a", newline="\\n") as _f:',
      '        _f.write("stub=%s\\ntest_id=%s\\n" % (_rel, _id))',
      "except OSError:",
      "    pass",
      'sys.stderr.write("root-decoy: stub reached: %s\\n" % _rel)',
      `sys.exit(${STUB_EXIT})`,
      "",
    ].join("\n");
  }
  if (kind === "pwsh") {
    const q = (s) => `'${s.replace(/'/g, "''")}'`;
    return [
      `# ${STUB_TAG}`,
      `$rootDecoyRel = ${q(rel)}`,
      `$rootDecoyHits = Join-Path $PSScriptRoot ${q(`${up}/${HITS_DIRNAME}`)}`,
      "$rootDecoyId = ([string]$env:ROOT_DECOY_TEST_ID) -replace '[\\r\\n]', '?'",
      "try {",
      "  $rootDecoyFile = Join-Path $rootDecoyHits ('{0}-{1}.hit' -f $PID, [guid]::NewGuid().ToString('N'))",
      '  [System.IO.File]::AppendAllText($rootDecoyFile, "stub=$rootDecoyRel`ntest_id=$rootDecoyId`n")',
      "} catch {}",
      '[Console]::Error.WriteLine("root-decoy: stub reached: $rootDecoyRel")',
      `exit ${STUB_EXIT}`,
      "",
    ].join("\n");
  }
  return `${STUB_TAG} (not a script): ${rel}\n`;
}

function buildTree(treeDir, marker, paths) {
  fs.mkdirSync(path.join(treeDir, HITS_DIRNAME), { recursive: true });
  const made = new Set();
  for (const rel of paths) {
    const dest = path.join(treeDir, ...rel.split("/"));
    const dir = path.dirname(dest);
    if (!made.has(dir)) {
      fs.mkdirSync(dir, { recursive: true });
      made.add(dir);
    }
    const kind = stubKind(rel);
    fs.writeFileSync(dest, stubBody(kind, rel), { mode: kind === "data" ? 0o644 : 0o755 });
  }
  fs.writeFileSync(path.join(treeDir, ".env"), `${MARKER_KEY}=${marker}\n`);
}

function isComplete(outDir) {
  return fs.existsSync(path.join(outDir, "main", ".env")) && fs.existsSync(path.join(outDir, "old", ".env"));
}

function renameWithRetry(from, to) {
  let last;
  for (let i = 0; i < 5; i++) {
    try {
      fs.renameSync(from, to);
      return null;
    } catch (err) {
      last = err;
      if (fs.existsSync(to)) return err;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    }
  }
  return last;
}

function buildOut(outArg) {
  const outDir = path.resolve(toNative(outArg));
  if (isComplete(outDir)) return;
  const paths = listPaths();
  fs.mkdirSync(path.dirname(outDir), { recursive: true });
  const tmp = `${outDir}.tmp-${process.pid}-${crypto.randomBytes(6).toString("hex")}`;
  // die() exits the process and an exit skips `finally`, so the failure is carried out of the try.
  let failure = null;
  try {
    buildTree(path.join(tmp, "main"), "main", paths);
    buildTree(path.join(tmp, "old"), "old", paths);
    try {
      fs.rmdirSync(outDir);
    } catch (_) {}
    const err = renameWithRetry(tmp, outDir);
    if (err && !isComplete(outDir)) failure = `cannot publish the decoy at ${outDir}: ${err.message}`;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  if (failure !== null) die(1, failure);
}

function buildSingle(dirArg, marker) {
  if (/[\r\n]/.test(marker)) die(2, "--marker must be a single line");
  buildTree(path.resolve(toNative(dirArg)), marker, listPaths());
}

function retiredEnvNames(fileArg) {
  const file = fileArg ? path.resolve(toNative(fileArg)) : RETIRED_NAMES_FILE;
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (err) {
    die(2, `cannot read the retired-name list ${file}: ${err.code || err.message}`);
  }
  const lines = text.split(/\r?\n/);
  const begin = lines.findIndex((l) => l.trim() === REGION_BEGIN);
  const end = lines.findIndex((l, i) => i > begin && l.trim() === REGION_END);
  if (begin < 0 || end < 0) die(2, `no "${REGION_BEGIN}" … "${REGION_END}" region in ${file}`);
  const names = [];
  for (const line of lines.slice(begin + 1, end)) {
    const m = /^#\s+env\s+(\S+)\s*$/.exec(line);
    if (!m) continue;
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(m[1])) die(2, `not an environment variable name in ${file}: ${m[1]}`);
    if (!names.includes(m[1])) names.push(m[1]);
  }
  if (names.length === 0) die(2, `the retired-name region of ${file} lists no "env" entry`);
  return names;
}

function cacheKey() {
  const h = crypto.createHash("sha256");
  h.update(fs.readFileSync(__filename));
  h.update("\0");
  h.update(listPaths().join("\n"));
  return h.digest("hex").slice(0, 16);
}

function main(argv) {
  const opts = {};
  const valued = new Set(["--out", "--single", "--marker", "--retired-names-from"]);
  const flags = new Set(["--print-retired-env-names", "--cache-key"]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (valued.has(a)) {
      if (i + 1 >= argv.length || argv[i + 1] === "") die(2, `option ${a} requires a value`);
      opts[a] = argv[++i];
    } else if (flags.has(a)) {
      opts[a] = true;
    } else {
      die(2, `unknown argument: ${a}`);
    }
  }
  const modes = ["--out", "--single", "--print-retired-env-names", "--cache-key"].filter((m) => m in opts);
  if (modes.length !== 1) die(2, "give exactly one of --out, --single, --print-retired-env-names, --cache-key");
  if (modes[0] === "--out") return buildOut(opts["--out"]);
  if (modes[0] === "--single") {
    if (!("--marker" in opts)) die(2, "--single requires --marker <value>");
    return buildSingle(opts["--single"], opts["--marker"]);
  }
  if (modes[0] === "--cache-key") return void process.stdout.write(`${cacheKey()}\n`);
  return void process.stdout.write(`${retiredEnvNames(opts["--retired-names-from"]).join("\n")}\n`);
}

main(process.argv.slice(2));
