# shellcheck shell=bash
# Shared helpers for fix-416-classify-sentinel-reason-text dispatcher.
# Sourced by fix-416-classify-sentinel-reason-text.sh and the case-group files in this folder.
# PASS, FAIL, TMPDIR_BASE are set in the dispatcher before sourcing this file.

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# classify() helper via Node.js
# ─────────────────────────────────────────────────────────────────────────────

CLASSIFY_HELPER="$TMPDIR_BASE/classify-helper.js"
cat > "$CLASSIFY_HELPER" <<'NODE_HELPER'
const path = require("path");
const lib = path.join(process.argv[2], "hooks", "lib", "bash-write-patterns");
const { classify } = require(lib);
process.stdout.write(classify(process.argv[3]));
NODE_HELPER

classify() {
  local cmd="$1"
  run_with_timeout 15 node "$CLASSIFY_HELPER" "$AGENTS_DIR" "$cmd"
}

assert_classify() {
  local label="$1" cmd="$2" expected="$3"
  local got
  got="$(classify "$cmd")"
  if [ "$got" = "$expected" ]; then
    pass "$label → $expected"
  else
    fail "$label → expected '$expected', got '$got' (cmd: $cmd)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Post-canary5-6git SSOT helpers: git-write and file-op-write detection moved OUT
# of classify()/WRITE_PATTERNS (#1401/#1400 retire) INTO isGitWriteIR /
# isFileOpWriteIR (IR-based). A real git/rm/cp/mv write now classifies "read";
# detection is via these predicates === true.
# ─────────────────────────────────────────────────────────────────────────────
GITWRITE_HELPER="$TMPDIR_BASE/gitwrite-helper.js"
cat > "$GITWRITE_HELPER" <<'NODE_GW'
const path = require("path");
const { isGitWriteIR } = require(path.join(process.argv[2], "hooks", "lib", "bash-write-patterns", "patterns"));
const { parse } = require(path.join(process.argv[2], "hooks", "lib", "command-ir"));
process.stdout.write(String(isGitWriteIR(parse(process.argv[3]))));
NODE_GW

FILEOP_HELPER="$TMPDIR_BASE/fileop-helper.js"
cat > "$FILEOP_HELPER" <<'NODE_FO'
const path = require("path");
const { isFileOpWriteIR } = require(path.join(process.argv[2], "hooks", "lib", "bash-write-targets"));
const { parse } = require(path.join(process.argv[2], "hooks", "lib", "command-ir"));
process.stdout.write(String(isFileOpWriteIR(parse(process.argv[3]))));
NODE_FO

# Assert a real git write: post-retire SSOT is classify=="read" + isGitWriteIR==true.
assert_git_write() {
  local label="$1" cmd="$2"
  local c g
  c="$(classify "$cmd")"
  g="$(run_with_timeout 15 node "$GITWRITE_HELPER" "$AGENTS_DIR" "$cmd")"
  if [ "$c" = "read" ] && [ "$g" = "true" ]; then
    pass "$label → git-write (classify=read + isGitWriteIR=true)"
  else
    fail "$label → expected classify=read+isGitWriteIR=true, got classify='$c' isGitWriteIR='$g' (cmd: $cmd)"
  fi
}

# Assert a real file-op (rm/cp/mv) write in a sequenced command: post-retire SSOT
# is classify=="read" (file-op retired from WRITE_PATTERNS) + isFileOpWriteIR==true.
assert_file_op_write() {
  local label="$1" cmd="$2"
  local c f
  c="$(classify "$cmd")"
  f="$(run_with_timeout 15 node "$FILEOP_HELPER" "$AGENTS_DIR" "$cmd")"
  if [ "$c" = "read" ] && [ "$f" = "true" ]; then
    pass "$label → file-op-write (classify=read + isFileOpWriteIR=true)"
  else
    fail "$label → expected classify=read+isFileOpWriteIR=true, got classify='$c' isFileOpWriteIR='$f' (cmd: $cmd)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# #1411 SSOT helpers: pkg-mgr (7 tools) and interpreter-c write detection moved
# OUT of classify()/WRITE_PATTERNS INTO isPkgMgrWriteIR
# (hooks/lib/bash-write-targets/pkg-mgr.js) and isInterpreterCWriteIR
# (hooks/lib/bash-write-targets.js). A real pkg-mgr / interpreter-c write now
# classifies "read"; detection is via these predicates === true. Pre-impl the
# module/fn is missing → helper prints ERROR:* so the assertion FAILs cleanly.
# ─────────────────────────────────────────────────────────────────────────────
PKGMGR_HELPER="$TMPDIR_BASE/pkgmgr-helper.js"
cat > "$PKGMGR_HELPER" <<'NODE_PM'
const path = require("path");
let m;
try { m = require(path.join(process.argv[2], "hooks", "lib", "bash-write-targets", "pkg-mgr")); }
catch (e) { process.stdout.write("ERROR:no-module"); process.exit(0); }
if (typeof m.isPkgMgrWriteIR !== "function") { process.stdout.write("ERROR:not-exported"); process.exit(0); }
const { parse } = require(path.join(process.argv[2], "hooks", "lib", "command-ir"));
process.stdout.write(String(m.isPkgMgrWriteIR(parse(process.argv[3]))));
NODE_PM

INTERPC_HELPER="$TMPDIR_BASE/interpc-helper.js"
cat > "$INTERPC_HELPER" <<'NODE_IC'
const path = require("path");
const m = require(path.join(process.argv[2], "hooks", "lib", "bash-write-targets"));
if (typeof m.isInterpreterCWriteIR !== "function") { process.stdout.write("ERROR:not-exported"); process.exit(0); }
const { parse } = require(path.join(process.argv[2], "hooks", "lib", "command-ir"));
process.stdout.write(String(m.isInterpreterCWriteIR(parse(process.argv[3]))));
NODE_IC

# Assert a real pkg-mgr write: post-retire SSOT is classify=="read" + isPkgMgrWriteIR==true.
assert_pkg_mgr_write() {
  local label="$1" cmd="$2"
  local c p
  c="$(classify "$cmd")"
  p="$(run_with_timeout 15 node "$PKGMGR_HELPER" "$AGENTS_DIR" "$cmd")"
  if [ "$c" = "read" ] && [ "$p" = "true" ]; then
    pass "$label → pkg-mgr-write (classify=read + isPkgMgrWriteIR=true)"
  else
    fail "$label → expected classify=read+isPkgMgrWriteIR=true, got classify='$c' isPkgMgrWriteIR='$p' (cmd: $cmd)"
  fi
}

# Assert a real interpreter-c write: post-retire SSOT is classify=="read" + isInterpreterCWriteIR==true.
assert_interpreter_c_write() {
  local label="$1" cmd="$2"
  local c i
  c="$(classify "$cmd")"
  i="$(run_with_timeout 15 node "$INTERPC_HELPER" "$AGENTS_DIR" "$cmd")"
  if [ "$c" = "read" ] && [ "$i" = "true" ]; then
    pass "$label → interpreter-c-write (classify=read + isInterpreterCWriteIR=true)"
  else
    fail "$label → expected classify=read+isInterpreterCWriteIR=true, got classify='$c' isInterpreterCWriteIR='$i' (cmd: $cmd)"
  fi
}

# classify_raw_js: pass a raw JS expression as the classify() argument.
# Used for edge-input tests (null, empty string, non-string) that cannot be
# represented as bash variables.
CLASSIFY_RAW_HELPER="$TMPDIR_BASE/classify-raw-helper.js"
cat > "$CLASSIFY_RAW_HELPER" <<'NODE_RAW'
const path = require("path");
const lib = path.join(process.argv[2], "hooks", "lib", "bash-write-patterns");
const { classify } = require(lib);
// process.argv[3] is the JS expression string, eval'd in a controlled context.
// Only literal-value expressions are expected here (null, "", 42).
// eslint-disable-next-line no-eval
const val = eval(process.argv[3]); // safe: test-only, no user input
process.stdout.write(classify(val));
NODE_RAW

assert_classify_raw() {
  local label="$1" jsexpr="$2" expected="$3"
  local got
  got="$(run_with_timeout 15 node "$CLASSIFY_RAW_HELPER" "$AGENTS_DIR" "$jsexpr")"
  if [ "$got" = "$expected" ]; then
    pass "$label → $expected"
  else
    fail "$label → expected '$expected', got '$got' (js: $jsexpr)"
  fi
}
