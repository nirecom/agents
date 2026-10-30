#!/usr/bin/env node
"use strict";
// Builds the command guard (#2590): bin/ answers for git, gh, glab and codex; each guard binary
// reads ../guard.conf, so the cached bin is copied into each run's instance. Windows gets one
// csc-built launcher copied to <tool>.exe. Design: docs/architecture/claude-code/test-command-guard.md
// Usage:
//   command-guard-build.js --cache-dir                     print <cache base>/command-guard/<key>
//   command-guard-build.js --out <dir>                     build <dir>/bin (atomic, no-op when present)
//   command-guard-build.js --instance <dir> --allowed <root> --realgit <git>
// Exit: 0 ok, 1 build failure, 2 usage error.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { testCacheBase, toNative } = require("./test-cache-base");
const {
  GUARD_EXIT, NETWORK_TOOLS, READ_VERBS, VALUE_GLOBALS, FAST_WRITE_VERBS, FAST_DENY_PREFIXES, FAST_DENY_ENV,
} = require("./command-guard/classify");

const GUARD_SRC = path.join(__dirname, "command-guard");
const LAUNCHER_CS = path.join(GUARD_SRC, "launcher.cs");
const MAIN_JS = path.join(GUARD_SRC, "main.js");
// The ssh stub of this tree: the one ssh command the guard trusts (command-guard/ssh-stub.js).
const SSH_STUB = path.join(__dirname, "git-ssh-stub.sh");
const TOOLS = ["git", ...NETWORK_TOOLS];
const IS_WIN = process.platform === "win32";
const EXE = IS_WIN ? ".exe" : "";

function die(code, msg) {
  process.stderr.write(`command-guard-build: ${msg}\n`);
  process.exit(code);
}

const mixed = (p) => (IS_WIN ? p.replace(/\\/g, "/") : p);
const msysForm = (p) => (IS_WIN ? mixed(p).replace(/^([A-Za-z]):/, (_, d) => `/${d.toLowerCase()}`) : p);

function cacheKey() {
  const h = crypto.createHash("sha256");
  for (const f of [__filename, LAUNCHER_CS, path.join(GUARD_SRC, "classify.js")]) {
    h.update(fs.readFileSync(f));
    h.update("\0");
  }
  h.update(process.platform);
  return h.digest("hex").slice(0, 16);
}

function cacheDir() {
  return `${testCacheBase()}/command-guard/${cacheKey()}`;
}

// The POSIX bin script: git reads and fast-path writes go straight to the real git; everything
// else runs main.js.
// Without node a hit is still written and the call still fails.
function bashScript(tool) {
  const lines = [
    "#!/usr/bin/env bash",
    `# command guard (#2590) for ${tool}: tests/lib/command-guard-build.js wrote this; settings in ../guard.conf.`,
    '_cg_self="${BASH_SOURCE[0]:-$0}"',
    'case "$_cg_self" in */*) _cg_dir="${_cg_self%/*}/.." ;; *) _cg_dir=".." ;; esac',
    '_cg_node="" _cg_main="" _cg_git="" _cg_reads="" _cg_fast="" _cg_deny="" _cg_denyenv="" _cg_allowed=()',
    'while IFS= read -r _cg_l || [[ -n "$_cg_l" ]]; do',
    '  case "$_cg_l" in',
    '    node=*) [[ -n "$_cg_node" ]] || _cg_node="${_cg_l#node=}" ;;',
    '    main=*) [[ -n "$_cg_main" ]] || _cg_main="${_cg_l#main=}" ;;',
    '    realgit=*) [[ -n "$_cg_git" ]] || _cg_git="${_cg_l#realgit=}" ;;',
    '    readverbs=*) [[ -n "$_cg_reads" ]] || _cg_reads="${_cg_l#readverbs=}" ;;',
    '    fastverbs=*) [[ -n "$_cg_fast" ]] || _cg_fast="${_cg_l#fastverbs=}" ;;',
    '    fastdeny=*) [[ -n "$_cg_deny" ]] || _cg_deny="${_cg_l#fastdeny=}" ;;',
    '    fastdenyenv=*) [[ -n "$_cg_denyenv" ]] || _cg_denyenv="${_cg_l#fastdenyenv=}" ;;',
    '    allowed=*) _cg_allowed+=("${_cg_l#allowed=}") ;;',
    '  esac',
    'done <"$_cg_dir/guard.conf" 2>/dev/null',
  ];
  if (tool === "git") {
    lines.push(
      "# The fast write path (classify.js FAST_WRITE_VERBS): the verb after nothing but `-C <dir>` /",
      "# `-c <name=value>` pairs, no denied argument or variable, and the git dir, common dir and work",
      "# tree the real git reports with those same pairs all under an allowed root with no link on the way.",
      "_cg_fast_ok() {",
      '  local a d t r p rp n=0 hit',
      '  local -a c=()',
      '  while [[ ( "${1:-}" == "-C" || "${1:-}" == "-c" ) && $# -ge 2 ]]; do c+=("$1" "$2"); shift 2; done',
      '  [[ "${1:-}" =~ ^[a-z][a-z-]*$ && " $_cg_fast " == *" $1 "* ]] || return 1',
      '  for a in "$@"; do for d in $_cg_deny; do [[ "$a" == "$d"* ]] && return 1; done; done',
      '  for d in $_cg_denyenv; do [[ -n "${!d:-}" ]] && return 1; done',
      '  rp="$("$_cg_git" "${c[@]}" rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel 2>/dev/null)" || return 1',
      '  while IFS= read -r t; do',
      "    t=\"${t%$'\\r'}\"",
      '    t="${t%/}"',
      '    [[ -n "$t" ]] || continue',
      '    n=$((n + 1))',
      '    [[ "$t" == /* || "$t" == [A-Za-z]:/* ]] || return 1',
      '    case "/$t/" in */./*|*/../*) return 1 ;; esac',
      '    hit=0',
      '    for r in "${_cg_allowed[@]}"; do',
      '      r="${r%/}"',
      '      [[ -n "$r" ]] && [[ "$t" == "$r" || "$t" == "$r"/* ]] || continue',
      '      p="$t"',
      '      while [[ ${#p} -gt ${#r} ]]; do',
      '        [[ -e "$p" && ! -L "$p" ]] || continue 2',
      '        p="${p%/*}"',
      '      done',
      '      hit=1',
      '      break',
      '    done',
      '    [[ "$hit" -eq 1 ]] || return 1',
      '  done <<<"$rp"',
      '  [[ "$n" -eq 3 ]]',
      "}",
    );
    lines.push(
      'if [[ -n "$_cg_git" ]]; then',
      '  _cg_verb="" _cg_skip=0 _cg_out=0',
      '  for _cg_a in "$@"; do',
      '    case "$_cg_a" in --output|--output=*|--output-directory|--output-directory=*) _cg_out=1 ;; esac',
      '    [[ -z "$_cg_verb" ]] || continue',
      '    if [[ "$_cg_skip" -eq 1 ]]; then _cg_skip=0; continue; fi',
      '    case "$_cg_a" in',
      `      ${VALUE_GLOBALS.join("|")}) _cg_skip=1 ;;`,
      '      -*) ;;',
      '      *) _cg_verb="$_cg_a" ;;',
      '    esac',
      '  done',
      '  if [[ "$_cg_out" -eq 0 ]] && { [[ -z "$_cg_verb" ]] || [[ " $_cg_reads " == *" $_cg_verb "* ]]; }; then',
      '    exec "$_cg_git" "$@"',
      '  fi',
      '  if [[ "$_cg_out" -eq 0 && -n "$_cg_fast" ]] && _cg_fast_ok "$@"; then',
      '    exec "$_cg_git" "$@"',
      '  fi',
      'fi',
    );
  }
  lines.push(
    'if [[ -z "$_cg_node" || -z "$_cg_main" || ! -x "$_cg_node" ]]; then',
    '  _cg_argv="$*"',
    '  _cg_nl=$\'\\n\'; _cg_cr=$\'\\r\'',
    '  _cg_tid="${ROOT_DECOY_TEST_ID:-}"; _cg_tid="${_cg_tid//$_cg_nl/ }"; _cg_tid="${_cg_tid//$_cg_cr/ }"',
    '  _cg_tgt="$PWD"; _cg_tgt="${_cg_tgt//$_cg_nl/ }"; _cg_tgt="${_cg_tgt//$_cg_cr/ }"',
    '  _cg_argv="${_cg_argv//$_cg_nl/ }"; _cg_argv="${_cg_argv//$_cg_cr/ }"',
    '  mkdir -p "$_cg_dir/hits" 2>/dev/null',
    `  printf 'stub=%s\\ntest_id=%s\\ntarget=%s\\nargv=%s\\n' ${tool} "$_cg_tid" "$_cg_tgt" "\${_cg_argv:0:200}" >"$_cg_dir/hits/$$-$RANDOM$RANDOM.hit" 2>/dev/null`,
    `  printf 'command guard: refused ${tool} (node or guard.conf unavailable)\\n' >&2`,
    `  exit ${GUARD_EXIT}`,
    "fi",
    'if [[ -n "${NODE_OPTIONS+x}" ]]; then',
    '  export _CG_NODE_OPTIONS_SET=1 _CG_NODE_OPTIONS="$NODE_OPTIONS"',
    "  unset NODE_OPTIONS",
    "fi",
    `exec "$_cg_node" "$_cg_main" "$_cg_dir" ${tool} "$@"`,
    "",
  );
  return lines.join("\n");
}

function findCsc() {
  const win = process.env.WINDIR || process.env.SystemRoot || "C:\\Windows";
  for (const fw of ["Framework64", "Framework"]) {
    const csc = path.join(win, "Microsoft.NET", fw, "v4.0.30319", "csc.exe");
    if (fs.existsSync(csc)) return csc;
  }
  return null;
}

function buildBin(binDir, workDir) {
  fs.mkdirSync(binDir, { recursive: true });
  if (!IS_WIN) {
    for (const tool of TOOLS) fs.writeFileSync(path.join(binDir, tool), bashScript(tool), { mode: 0o755 });
    return;
  }
  const csc = findCsc();
  if (!csc) die(1, "csc.exe (.NET Framework 4) not found; the Windows guard cannot be built, refusing to run without it");
  const src = path.join(workDir, "launcher.cs");
  const exe = path.join(workDir, "launcher.exe");
  fs.writeFileSync(src, fs.readFileSync(LAUNCHER_CS, "utf8").replace("@GUARD_EXIT@", String(GUARD_EXIT)));
  const r = spawnSync(csc, ["-nologo", "-target:exe", "-optimize+", `-out:${exe}`, src], { encoding: "utf8", windowsHide: true });
  if (r.status !== 0 || !fs.existsSync(exe)) die(1, `csc failed (${r.status}): ${String(r.stdout || "").trim()} ${String(r.stderr || "").trim()}`);
  for (const tool of TOOLS) fs.copyFileSync(exe, path.join(binDir, `${tool}${EXE}`));
}

const isBuilt = (dir) => TOOLS.every((t) => fs.existsSync(path.join(dir, "bin", `${t}${EXE}`)));

function buildOut(outArg) {
  const outDir = path.resolve(toNative(outArg));
  if (isBuilt(outDir)) return outDir;
  fs.mkdirSync(path.dirname(outDir), { recursive: true });
  const tmp = `${outDir}.tmp-${process.pid}-${crypto.randomBytes(6).toString("hex")}`;
  const work = `${tmp}-work`;
  fs.mkdirSync(work, { recursive: true });
  let failure = null;
  try {
    buildBin(path.join(tmp, "bin"), work);
    try {
      fs.rmdirSync(outDir);
    } catch (_) {}
    try {
      fs.renameSync(tmp, outDir);
    } catch (err) {
      if (!isBuilt(outDir)) failure = `cannot publish the guard at ${outDir}: ${err.message}`;
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
    fs.rmSync(work, { recursive: true, force: true });
  }
  if (failure !== null) die(1, failure);
  return outDir;
}

function realGitPath(arg) {
  let git = path.resolve(toNative(arg));
  if (IS_WIN && !/\.exe$/i.test(git) && !fs.existsSync(git)) git += ".exe";
  if (!fs.existsSync(git)) die(1, `the real git does not exist: ${git}`);
  if (/[/\\]command-guard[/\\]bin[/\\]/i.test(git)) die(1, `refusing the guard's own git as the real git: ${git}`);
  return mixed(git);
}

function buildInstance(dirArg, allowedArg, realgitArg) {
  const dir = path.resolve(toNative(dirArg));
  const allowed = mixed(path.resolve(toNative(allowedArg)));
  const realgit = realGitPath(realgitArg);
  const cache = buildOut(cacheDir());
  fs.mkdirSync(path.join(dir, "bin"), { recursive: true });
  fs.mkdirSync(path.join(dir, "hits"), { recursive: true });
  for (const tool of TOOLS) {
    const name = `${tool}${EXE}`;
    fs.copyFileSync(path.join(cache, "bin", name), path.join(dir, "bin", name));
    if (!IS_WIN) fs.chmodSync(path.join(dir, "bin", name), 0o755);
  }
  const conf = [
    `node=${process.execPath}`,
    `main=${mixed(MAIN_JS)}`,
    `realgit=${realgit}`,
    `allowed=${allowed}`,
    ...(msysForm(allowed) !== allowed ? [`allowed=${msysForm(allowed)}`] : []),
    `readverbs=${READ_VERBS.join(" ")}`,
    `fastverbs=${FAST_WRITE_VERBS.join(" ")}`,
    `fastdeny=${FAST_DENY_PREFIXES.join(" ")}`,
    `fastdenyenv=${FAST_DENY_ENV.join(" ")}`,
    ...(fs.existsSync(SSH_STUB) ? [`sshstub=${mixed(SSH_STUB)}`] : []),
    "",
  ].join("\n");
  const tmp = path.join(dir, `guard.conf.tmp-${process.pid}`);
  fs.writeFileSync(tmp, conf);
  fs.renameSync(tmp, path.join(dir, "guard.conf"));
}

function main(argv) {
  const opts = {};
  const valued = new Set(["--out", "--instance", "--allowed", "--realgit"]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (valued.has(a)) {
      if (i + 1 >= argv.length || argv[i + 1] === "") die(2, `option ${a} requires a value`);
      opts[a] = argv[++i];
    } else if (a === "--cache-dir") {
      opts[a] = true;
    } else {
      die(2, `unknown argument: ${a}`);
    }
  }
  const modes = ["--cache-dir", "--out", "--instance"].filter((m) => m in opts);
  if (modes.length !== 1) die(2, "give exactly one of --cache-dir, --out, --instance");
  if (modes[0] === "--cache-dir") return void process.stdout.write(`${cacheDir()}\n`);
  if (modes[0] === "--out") return void buildOut(opts["--out"]);
  if (!opts["--allowed"] || !opts["--realgit"]) die(2, "--instance requires --allowed <root> and --realgit <git>");
  return buildInstance(opts["--instance"], opts["--allowed"], opts["--realgit"]);
}

main(process.argv.slice(2));
