#!/usr/bin/env bash
# Tests: hooks/lib/shell-snapshot-path.js, hooks/lib/shell-snapshot-repair.js, hooks/lib/hook-deadline.js, hooks/postuse-shell-snapshot-repair.js, hooks/postuse-shell-snapshot-repair/session-check.js, hooks/session-start.js, settings.json
# Tags: hook, shell-snapshot, windows-path, session-start, posttooluse, scope:issue-specific, TL1, TL2
# Issue #2221 mode B (Windows-form PATH in the shell snapshot, so every Bash call exits 127): the
# repair hook family classifies, repairs, never rewrites the unrepairable, never deletes, and warns.
# Sweep side: T22 in tests/bin/feature-sweep-shell-snapshots/classifier-tables.sh. One case per part;
# snap_js runs heredoc node bodies under a shared prelude and counts their PASS:/FAIL:/SKIP: lines.
# TL3 gap (what this test does NOT catch):
# - Real CC firing PostToolUseFailure (error "Exit code 127\n…") after a Bash exit 127, and SessionStart.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

SNAP_TMP_ROOT_RAW="$(make_tmp)"
readonly SNAP_TMP_ROOT_RAW
trap 'rm -rf "$SNAP_TMP_ROOT_RAW"' EXIT
SNAP_TMP="$(np "$SNAP_TMP_ROOT_RAW")"

# Isolation: both workflow dirs, both home variables (Windows os.homedir() reads
# USERPROFILE — leaving it live would let a case rewrite the real
# ~/.claude/shell-snapshots), no inherited session, an empty transcript base.
harness_isolate "$SNAP_TMP"
export HOME="$SNAP_TMP/home-default"
export USERPROFILE="$HOME"
mkdir -p "$HOME"
export CLAUDE_TRANSCRIPT_BASE_DIR="$SNAP_TMP/transcripts-empty"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_CODE_SESSION_ID CLAUDECODE 2>/dev/null || true
export SNAP_ROOT
SNAP_ROOT="$(np "$SCRIPT_CHECKOUT_ROOT")"
export SNAP_JS_TMP="$SNAP_TMP/js"
mkdir -p "$SNAP_JS_TMP"
cd "$SNAP_TMP" || exit 1

PART_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-shell-snapshot-windows-path"
POSTUSE_HOOK="$SNAP_ROOT/hooks/postuse-shell-snapshot-repair.js"
SESSION_START_HOOK="$SNAP_ROOT/hooks/session-start.js"

# The exact confirmed-exit-127 sentence (plan section on notice wording). Shared by the
# notice, postuse and session-start parts so a wording drift fails everywhere.
export SNAP_CONFIRMED_SENTENCE='The previous Bash command exited with code 127 (command not found). PATH has been repaired and takes effect for subsequent Bash calls. Before re-running the previous command, check whether it changed any state before exiting 127; re-run it only if needed. This hook did not re-run it.'

# ---------------------------------------------------------------- JS prelude
cat > "$SNAP_TMP/prelude.js" <<'JS'
'use strict';
const assert = require('assert').strict;
const path = require('path');
const fs = require('fs');
const ROOT = process.env.SNAP_ROOT;
const TMP = process.env.SNAP_JS_TMP;
const SKIP = Symbol('skip');
const _cases = [];
function T(name, fn) { _cases.push([name, fn]); }
function load(rel) { return require(path.join(ROOT, rel)); }
async function _run() {
  for (const [n, f] of _cases) {
    try {
      const r = await f();
      console.log((r === SKIP ? 'SKIP: ' : 'PASS: ') + n);
    } catch (e) {
      console.log('FAIL: ' + n + ' :: ' + String((e && e.message) || e).split('\n')[0]);
    }
  }
}
function mkd(name) { return fs.mkdtempSync(path.join(TMP, name + '-')); }
function snapDir(home) { const d = path.join(home, '.claude', 'shell-snapshots'); fs.mkdirSync(d, { recursive: true }); return d; }
function snapText(value, opts = {}) {
  const eol = opts.eol || '\n';
  return ['# Snapshot file', '# Unset all aliases to avoid conflicts with functions', 'unalias -a 2>/dev/null || true',
    'shopt -s expand_aliases', "export PATH='" + value + "'", "alias ll='ls -l'"].join(eol) + eol;
}
// Epochs start at 1800000000000 so no generated name contains "127".
let _seq = 0;
function snapName(ms, rand) { return 'snapshot-bash-' + ms + '-' + (rand || ('r' + (++_seq))) + '.sh'; }
function writeSnap(dir, name, value, opts) { const f = path.join(dir, name); fs.writeFileSync(f, snapText(value, opts)); return f; }
function pathValue(text) { const m = /^export PATH='([^'\n]*)'\r?$/m.exec(text); return m ? m[1] : null; }
function reachesCore(value) { return String(value).split(':').map((e) => e.replace(/\/+$/, '')).some((e) => e === '/usr/bin' || e === '/bin'); }
function tmpLeft(dir) { return fs.readdirSync(dir).filter((n) => /\.repair\.tmp$/.test(n)); }
function count(x) { if (Array.isArray(x)) return x.length; return typeof x === 'number' ? x : 0; }
function noticeText(x) { if (Array.isArray(x)) return x.join('\n'); return x == null ? '' : String(x); }
const DEFAULT_HEADS = ['/mingw64/bin', '/usr/local/bin', '/usr/bin', '/bin'];
// Stub converter: mimics `cygpath -u -p` (drive letter -> /<letter>/..., the Git for Windows
// mount points -> their MSYS names) and records each call.
const MOUNTS = [['c:/program files/git/usr/bin', '/usr/bin'], ['c:/program files/git/mingw64/bin', '/mingw64/bin'], ['c:/program files/git/bin', '/usr/bin']];
function stubToPosixOne(el) {
  const fwd = el.replace(/\\/g, '/');
  for (const [w, p] of MOUNTS) if (fwd.toLowerCase().replace(/\/+$/, '') === w) return p;
  const d = /^([A-Za-z]):\/(.*)$/.exec(fwd);
  if (d) return '/' + d[1].toLowerCase() + '/' + d[2].replace(/\/+$/, '');
  return fwd;
}
function makeStubDeps(opts = {}) {
  const calls = { toPosixList: [], msysHeadExisting: 0 };
  return {
    calls,
    toPosixList(list) {
      calls.toPosixList.push(list);
      if (opts.onConvert) opts.onConvert();
      if (opts.convert) return opts.convert(list);
      return list.split(';').filter((s) => s.trim() !== '').map((s) => stubToPosixOne(s.trim())).join(':');
    },
    msysHeadExisting() { calls.msysHeadExisting++; return (opts.heads || DEFAULT_HEADS).slice(); },
  };
}
function fakeDeadline(ms) { const left = ms == null ? 60000 : ms; return { remainingMs: () => left, sliceMs: (cap, reserve) => { const v = Math.min(cap, left - (reserve || 0)); return v < 100 ? 0 : v; } }; }
JS

# snap_js <label> — runs the heredoc body on stdin under the prelude; one
# harness count per PASS:/FAIL:/SKIP: line the script prints.
snap_js() {
  local label="$1" f out rc line seen=0
  f="$SNAP_JS_TMP/case-$RANDOM-$RANDOM.js"
  {
    cat "$SNAP_TMP/prelude.js"
    cat
    printf '\n_run();\n'
  } > "$f"
  out="$(run_with_timeout 120 node "$f" 2>&1)"
  rc=$?
  while IFS= read -r line; do
    case "$line" in
      "PASS: "*) pass "$label: ${line#PASS: }"; seen=1 ;;
      "FAIL: "*) fail "$label: ${line#FAIL: }"; seen=1 ;;
      "SKIP: "*) skip "$label: ${line#SKIP: }"; seen=1 ;;
    esac
  done <<< "$out"
  if [ "$seen" = "0" ]; then
    fail "$label: node printed no case lines (rc=$rc)" "$(printf '%s' "$out" | head -n 5)"
  fi
}

# ------------------------------------------------------- bash fixture helpers
now_ms() { node -p 'Date.now()'; }
iso_of_ms() { node -p "new Date(Number(process.argv[1])).toISOString()" "$1"; }

# snap_write <dir> <name> <path-value> — same preamble shape as a real snapshot.
snap_write() {
  mkdir -p "$1"
  {
    printf '%s\n' '# Snapshot file' 'unalias -a 2>/dev/null || true' 'shopt -s expand_aliases'
    printf "export PATH='%s'\n" "$3"
    printf '%s\n' "alias ll='ls -l'"
  } > "$1/$2"
}

# snap_value <file> — the value of the first export PATH='...' line.
snap_value() { sed -n "s/^export PATH='\\([^']*\\)'\$/\\1/p" "$1" | head -n 1; }

# snap_is_ok <file> — PATH reaches /usr/bin or /bin when split on ':'.
snap_is_ok() {
  local v e
  v="$(snap_value "$1")"
  local IFS=':'
  for e in $v; do
    e="${e%/}"
    if [ "$e" = "/usr/bin" ] || [ "$e" = "/bin" ]; then return 0; fi
  done
  return 1
}

# set_mtime_ms <file> <epoch-ms>
set_mtime_ms() { node -e "const s=Number(process.argv[2])/1000;require('fs').utimesSync(process.argv[1],s,s)" "$(np "$1")" "$2"; }

# json_get <file> <dotted.path> — prints the value, __EMPTY__ for an empty file,
# __INVALID__ when the file is not JSON, __MISSING__ when the key is absent.
cat > "$SNAP_TMP/jget.js" <<'JS'
const fs = require('fs');
const raw = fs.existsSync(process.argv[2]) ? fs.readFileSync(process.argv[2], 'utf8') : '';
if (raw.trim() === '') { console.log('__EMPTY__'); process.exit(0); }
let v;
try { v = JSON.parse(raw); } catch (e) { console.log('__INVALID__'); process.exit(0); }
for (const k of (process.argv[3] || '').split('.').filter(Boolean)) { v = (v == null) ? undefined : v[k]; }
if (v === undefined) console.log('__MISSING__');
else console.log(typeof v === 'string' ? v : JSON.stringify(v));
JS
json_get() {
  if [ -z "$1" ]; then echo "__MISSING__"; return 0; fi
  node "$SNAP_TMP/jget.js" "$(np "$1")" "$2"
}

# marker_file <sid> — wherever the state layer put <sid>.shell-snapshot-checked.
marker_file() { find "$WORKFLOW_STATE_DIR" -name "$1.shell-snapshot-checked" -type f 2>/dev/null | head -n 1; }

# write_transcript <file> <epoch-ms> — first JSON line carries the timestamp.
write_transcript() {
  local iso; iso="$(iso_of_ms "$2")"
  printf '{"type":"queue-operation","timestamp":"%s"}\n{"type":"user","timestamp":"%s"}\n' "$iso" "$iso" > "$1"
}

# have_cygpath_host — the hook can only repair where the real cygpath resolves.
have_cygpath_host() {
  case "${OSTYPE:-}" in msys*|cygwin*) command -v cygpath >/dev/null 2>&1 ;; *) return 1 ;; esac
}

# run_no_cygpath <home> <hook.js> — runs a hook where resolveCygpath finds nothing on any host:
# PATH and CLAUDE_CODE_GIT_BASH_PATH point into an empty tree, node by absolute path. Windows
# re-derives %ProgramFiles% at process start (an env override is lost, measured), so a preload
# hides <ProgramFiles>\Git\usr\bin\cygpath.exe from existsSync instead.
NOCYG_ROOT="$SNAP_TMP/no-cygpath"
mkdir -p "$NOCYG_ROOT/bin" "$NOCYG_ROOT/Git/bin"
NODE_ABS="$(command -v node)"
cat > "$SNAP_TMP/hide-pf-cygpath.js" <<'JS'
const fs = require('fs');
const path = require('path');
const orig = fs.existsSync;
const pf = process.env.ProgramFiles;
const hidden = pf ? path.win32.join(pf, 'Git', 'usr', 'bin', 'cygpath.exe').toLowerCase() : null;
fs.existsSync = function (p) { return (hidden && String(p).toLowerCase() === hidden) ? false : orig.apply(this, arguments); };
JS
run_no_cygpath() {
  HOME="$1" USERPROFILE="$1" run_with_timeout 30 env PATH="$NOCYG_ROOT/bin" \
    CLAUDE_CODE_GIT_BASH_PATH="$NOCYG_ROOT/Git/bin/bash.exe" NODE_OPTIONS="--require $(np "$SNAP_TMP/hide-pf-cygpath.js")" \
    "$NODE_ABS" "$2"
}

case_begin "predicate-classify-table" "hooks/lib/shell-snapshot-path.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/predicate-table.sh
. "$PART_DIR/predicate-table.sh"
case_end

case_begin "repair-plan-conversion" "hooks/lib/shell-snapshot-path.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/repair-plan.sh
. "$PART_DIR/repair-plan.sh"
case_end

case_begin "repair-file-compare-and-swap" "hooks/lib/shell-snapshot-repair.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/repair-file-cas.sh
. "$PART_DIR/repair-file-cas.sh"
case_end

case_begin "scan-and-repair-directory" "hooks/lib/shell-snapshot-repair.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/scan-and-repair.sh
. "$PART_DIR/scan-and-repair.sh"
case_end

case_begin "deadline-and-budget" "hooks/lib/hook-deadline.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/deadline-budget.sh
. "$PART_DIR/deadline-budget.sh"
case_end

case_begin "repair-notice-wording" "hooks/lib/shell-snapshot-repair.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/repair-notice.sh
. "$PART_DIR/repair-notice.sh"
case_end

case_begin "postuse-decide-table" "hooks/postuse-shell-snapshot-repair/session-check.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/postuse-decide.sh
. "$PART_DIR/postuse-decide.sh"
case_end

case_begin "postuse-hook-integration" "hooks/postuse-shell-snapshot-repair.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/postuse-integration.sh
. "$PART_DIR/postuse-integration.sh"
case_end

case_begin "session-start-integration" "hooks/session-start.js"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/session-start-integration.sh
. "$PART_DIR/session-start-integration.sh"
case_end

case_begin "settings-registration" "settings.json"
# shellcheck source=tests/hooks/fix-shell-snapshot-windows-path/settings-registration.sh
. "$PART_DIR/settings-registration.sh"
case_end

echo ""
echo "fix-shell-snapshot-windows-path: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
