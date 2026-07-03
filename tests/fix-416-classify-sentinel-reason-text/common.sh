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
