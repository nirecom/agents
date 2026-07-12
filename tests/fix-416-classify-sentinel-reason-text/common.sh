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
