#!/usr/bin/env bash
# tests/tests/feature-2513-code-stub-lib.sh
# Tests: tests/lib/code-stub.sh
# Tags: scope:issue-specific, plan-sync, vscode, stub
# The `code` stub guard must pass when a spawned child resolves the stub (even when the
# stub dir is spelled with an 8.3 short name, as a short-form TEMP produces) and must
# refuse when another `code` / `code.cmd` resolves first.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0 FAIL=0 SKIP=0
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/code-stub.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/code-stub.sh"
unset CLAUDE_CODE_ENTRYPOINT TERM_PROGRAM 2>/dev/null || true

T_ROOT="$(make_tmp)"
trap 'rm -rf "$T_ROOT"' EXIT
harness_isolate "$T_ROOT/iso"
IS_WIN=0
code_stub_is_windows && command -v cygpath >/dev/null 2>&1 && IS_WIN=1

echo "=== C1: stub dir spelled with an 8.3 short name — probe passes, spawn recorded once ==="
LONG_DIR="$T_ROOT/LongDirectoryNameForShortForm"
mkdir -p "$LONG_DIR"
STUB_BASE="$(np "$LONG_DIR")"
if [[ "$IS_WIN" -eq 1 ]]; then
  SHORT_DIR="$(cygpath -m "$(cygpath -s -w "$LONG_DIR")")"
  if [[ "${SHORT_DIR,,}" == "${STUB_BASE,,}" ]]; then
    skip "C1-short-form (8.3 names disabled on this volume; long form used)"
  else
    STUB_BASE="$SHORT_DIR"
  fi
fi
C1_OUT="$(
  setup_code_stub "$STUB_BASE/code-stub" || { echo "setup-fail"; exit 0; }
  if code_stub_probe; then echo "probe-ok count=$(code_stub_count)"; else echo "probe-fail count=$(code_stub_count)"; fi
)"
assert_eq "$C1_OUT" "probe-ok count=0"

# c2_run <suffix> [unset-os] — prints the C2 verdicts; "unset-os" drops OS as the worker does.
c2_run() {
  (
    [[ "${2:-}" == "unset-os" ]] && unset OS
    setup_code_stub "$T_ROOT/stub2$1" || { echo "setup-fail"; exit 0; }
    OTHER="$T_ROOT/other-code$1"
    mkdir -p "$OTHER"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$OTHER/code"
    chmod +x "$OTHER/code"
    printf '%s\r\n' '@echo off' 'exit /b 0' > "$OTHER/code.cmd"
    OTHER_ENTRY="$OTHER"
    [[ "$IS_WIN" -eq 1 ]] && OTHER_ENTRY="$(cygpath -u "$OTHER")"
    PATH="$OTHER_ENTRY:$PATH"
    if code_stub_resolves; then echo "resolves"; else echo "refused"; fi
    if code_stub_probe; then echo "probe-ok"; else echo "probe-refused"; fi
  )
}

echo "=== C2: another code/code.cmd dir ahead on PATH — code_stub_resolves refuses ==="
assert_eq "$(c2_run "")" "refused
probe-refused"

echo "=== C2-noOS: same refusal with OS unset (worker env) ==="
assert_eq "$(c2_run "-noos" unset-os)" "refused
probe-refused"

echo "=== C3: code_stub_count is 0 when the log is missing ==="
C3_OUT="$(
  CODE_STUB_LOG="$T_ROOT/no-such-dir/code-stub.log"
  code_stub_count
)"
assert_eq "$C3_OUT" "0"

echo "=== C4: OS unset (worker env) — probe passes, spawn recorded once ==="
C4_OUT="$(
  unset OS
  setup_code_stub "$(np "$T_ROOT")/stub4" || { echo "setup-fail"; exit 0; }
  if code_stub_probe; then echo "probe-ok count=$(code_stub_count)"; else echo "probe-fail count=$(code_stub_count)"; fi
)"
assert_eq "$C4_OUT" "probe-ok count=0"

echo "=== C5: env -i with only the worker allowlist vars — code_stub_resolves passes ==="
C5_OUT="$(
  env -i PATH="$PATH" PATHEXT="${PATHEXT:-}" HOME="${HOME:-}" USERPROFILE="${USERPROFILE:-}" \
    SYSTEMROOT="${SYSTEMROOT:-}" COMSPEC="${COMSPEC:-}" TEMP="${TEMP:-}" TMP="${TMP:-}" \
    bash -c '. "$1/tests/lib/code-stub.sh"; setup_code_stub "$2" || { echo setup-fail; exit 0; }
      if code_stub_resolves; then echo resolves; else echo refused; fi' c5 "$SCRIPT_CHECKOUT_ROOT" "$(np "$T_ROOT")/stub5" 2>&1
)"
assert_eq "$C5_OUT" "resolves"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
