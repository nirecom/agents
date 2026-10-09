#!/usr/bin/env bash
# Tests: bin/lib/cli-exec-guard.sh, bin/lib/codex-core.sh, bin/review-plan-codex, bin/lib/gemini-core.sh
# Tags: TL2, scope:issue-specific, codex, gemini, cli-exec-guard, input-limit, exit-127, pwsh-not-required
# #2475: codex input-size guard (1,048,576 code points) and the exit-127 diagnosis.
# Big prompts travel through fixture files read in the child via "$(<file)", never argv
# (the Windows 32,767-char argv cap / E2BIG would fail before the branch under test).
# TL3 gap: on a real Windows host, the MSYS child losing PATH once an exported PROMPT
# exceeds 2MB is not reproduced; exit 127 is simulated by a mock that exits 127.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

CEG_TMP="$(make_tmp)"
trap 'rm -rf "$CEG_TMP"' EXIT
harness_isolate "$CEG_TMP/iso"
mkdir -p "$CEG_TMP/home" "$CEG_TMP/transcripts" "$CEG_TMP/fix" "$CEG_TMP/mockbin" "$CEG_TMP/nodeonly" "$CEG_TMP/empty"
export HOME="$CEG_TMP/home"
export NO_LOG=true
export CLAUDE_TRANSCRIPT_BASE_DIR="$CEG_TMP/transcripts"
unset CODEX_TIMEOUT_SECS

GUARD_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/cli-exec-guard.sh"
FIX="$CEG_TMP/fix"
OUT="$CEG_TMP/out.txt"
PATHS_FILE="$CEG_TMP/paths.txt"
export MOCK_CALLED="$CEG_TMP/mock-called"
export GUARD_CALLED="$CEG_TMP/guard-called"
LIMIT=1048576

# Fixtures: generated once by node, read by children from disk.
cat > "$CEG_TMP/gen.js" <<'JS'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const w = (name, s) => fs.writeFileSync(path.join(dir, name), s, 'utf8');
w('big-kana-1048576.txt', 'あ'.repeat(1048576));
w('big-kana-1048577.txt', 'あ'.repeat(1048577));
w('ascii-1048577.txt', 'a'.repeat(1048577));
w('nonbmp-1048576.txt', '\u{1F600}'.repeat(1048576));
w('small.txt', 'hello');
w('plan-small.md', '# Plan\n\nsmall plan body\n');
JS
run_with_timeout 60 node "$(np "$CEG_TMP/gen.js")" "$(np "$FIX")"

# Mocks: mark the call, then exit with $MOCK_EXIT. codex drains stdin; gemini has none.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null 2>&1' ': > "$MOCK_CALLED"' \
  'echo "mock codex stderr" >&2' '[ "${MOCK_EXIT:-0}" = 0 ] && echo "APPROVED"' 'exit "${MOCK_EXIT:-0}"' \
  > "$CEG_TMP/mockbin/codex"
printf '%s\n' '#!/usr/bin/env bash' ': > "$MOCK_CALLED"' 'echo "mock gemini stderr" >&2' \
  '[ "${MOCK_EXIT:-0}" = 0 ] && echo "gemini-ok"' 'exit "${MOCK_EXIT:-0}"' > "$CEG_TMP/mockbin/gemini"
chmod +x "$CEG_TMP/mockbin/codex" "$CEG_TMP/mockbin/gemini"
printf '#!/bin/bash\nexec "%s" "$@"\n' "$(command -v node)" > "$CEG_TMP/nodeonly/node"
chmod +x "$CEG_TMP/nodeonly/node"
# A node that always fails: shadows the real one to drive the size check's rc-2 branch.
mkdir -p "$CEG_TMP/badnode"
printf '%s\n' '#!/bin/bash' 'echo "badnode stub failure" >&2' 'exit 3' > "$CEG_TMP/badnode/node"
chmod +x "$CEG_TMP/badnode/node"
MOCK_PATH="$CEG_TMP/mockbin:$PATH"
# PATH with node but no codex/gemini: the node shim plus the system tool dirs.
NO_CLI_PATH="$CEG_TMP/nodeonly:/usr/bin:/bin"

# Child scripts: CEG_CHILD_PATH (when set) replaces PATH after sourcing.
cat > "$CEG_TMP/run-guard.sh" <<'SH'
source "$1" >/dev/null 2>&1 || { echo "SOURCE_FAILED"; exit 99; }
[ -n "${CEG_CHILD_PATH:-}" ] && PATH="$CEG_CHILD_PATH"
if [ "$2" = diagnose ]; then
  cli_exec_guard_diagnose_127 "$3"
else
  cli_exec_guard_input_size "$2" "$3"
fi
echo "RC=$?"
SH
cat > "$CEG_TMP/run-core.sh" <<'SH'
source "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 || { echo "SOURCE_FAILED"; exit 99; }
codex_core_init "Probe" >/dev/null 2>&1
NO_LOG=true
[ -n "${CEG_CHILD_PATH:-}" ] && PATH="$CEG_CHILD_PATH"
codex_core_run "$(<"$2")"
printf '%s\n%s\n' "$TMPFILE" "$CODEX_STDERR" > "$3"
SH
cat > "$CEG_TMP/run-gemini.sh" <<'SH'
source "$1/bin/lib/gemini-core.sh" >/dev/null 2>&1 || { echo "SOURCE_FAILED"; exit 99; }
gemini_core_init "GemProbe" >/dev/null 2>&1
NO_LOG=true
if [ "${CEG_OVERRIDE_GUARD:-}" = 1 ]; then
  cli_exec_guard_input_size() { : > "$GUARD_CALLED"; return 0; }
fi
[ -n "${CEG_CHILD_PATH:-}" ] && PATH="$CEG_CHILD_PATH"
gemini_core_run "$(<"$2")"
printf 'GEMINI_OUTPUT=%s\n' "${GEMINI_OUTPUT:-}"
SH

# guard <file|diagnose> <limit|cli> [child-path]
guard() {
  CEG_CHILD_PATH="${3:-}" run_with_timeout 60 bash "$CEG_TMP/run-guard.sh" "$GUARD_LIB" "$1" "$2" > "$OUT" 2>&1
}
# core <prompt-file> <mock-exit> [child-path]
core() {
  rm -f "$MOCK_CALLED" "$PATHS_FILE"
  PATH="$MOCK_PATH" MOCK_EXIT="$2" CEG_CHILD_PATH="${3:-}" \
    run_with_timeout 60 bash "$CEG_TMP/run-core.sh" "$SCRIPT_CHECKOUT_ROOT" "$1" "$PATHS_FILE" > "$OUT" 2>&1
}
# gem <prompt-file> <mock-exit> [child-path] [override-guard]
gem() {
  rm -f "$MOCK_CALLED" "$GUARD_CALLED"
  PATH="$MOCK_PATH" MOCK_EXIT="$2" CEG_CHILD_PATH="${3:-}" CEG_OVERRIDE_GUARD="${4:-}" \
    run_with_timeout 60 bash "$CEG_TMP/run-gemini.sh" "$SCRIPT_CHECKOUT_ROOT" "$1" > "$OUT" 2>&1 </dev/null
}
has() { # <label> <needle>
  if grep -qF -- "$2" "$OUT"; then pass "$1"; else fail "$1" "missing '$2' in: $(head -c 400 "$OUT")"; fi
}
lacks() { # <label> <needle>
  if grep -qF -- "$2" "$OUT"; then fail "$1" "unexpected '$2' in: $(head -c 400 "$OUT")"; else pass "$1"; fi
}
called() { # <label> <file> <yes|no>
  local got=no; [ -e "$2" ] && got=yes
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "want marker=$3 got=$got"; fi
}
tmpfiles_gone() { # <label>
  local p s; p="$(sed -n '1p' "$PATHS_FILE" 2>/dev/null)"; s="$(sed -n '2p' "$PATHS_FILE" 2>/dev/null)"
  if [ -z "$p" ] || [ -z "$s" ]; then fail "$1" "codex_core_run did not report its tmpfile paths"; return; fi
  if [ -e "$p" ] || [ -e "$s" ]; then fail "$1" "tmpfile survived: $p $s"; else pass "$1"; fi
}

echo "=== #2475 cli-exec-guard ==="

case_begin "guard-counts-code-points-not-bytes" "bin/lib/cli-exec-guard.sh"
guard "$FIX/big-kana-1048576.txt" "$LIMIT"
assert_eq "$(cat "$OUT")" "RC=0"
guard "$FIX/nonbmp-1048576.txt" "$LIMIT"
assert_eq "$(cat "$OUT")" "RC=0"
case_end

case_begin "guard-rejects-over-limit" "bin/lib/cli-exec-guard.sh"
guard "$FIX/big-kana-1048577.txt" "$LIMIT"
assert_eq "$(cat "$OUT")" "input too large: 1048577 chars > limit 1048576
RC=1"
guard "$FIX/ascii-1048577.txt" "$LIMIT"
has "ascii over limit names the count" "1048577 chars > limit 1048576"
has "ascii over limit returns 1" "RC=1"
case_end

case_begin "guard-fails-closed" "bin/lib/cli-exec-guard.sh"
guard "$FIX/no-such-file.txt" "$LIMIT"
has "missing file -> input size check failed" "input size check failed"
has "missing file returns 2" "RC=2"
guard "$FIX/small.txt" "$LIMIT" "$CEG_TMP/empty"
has "node absent -> input size check failed" "input size check failed"
has "node absent returns 2" "RC=2"
case_end

case_begin "diagnose-127-direct" "bin/lib/cli-exec-guard.sh"
PATH="$MOCK_PATH" guard diagnose codex
has "cli present -> resolves in parent" "exit 127: 'codex' resolves in parent ("
has "cli present -> child environment likely broken" "child environment likely broken (exported env "
guard diagnose nosuchcli-2475 "$NO_CLI_PATH"
has "cli absent -> not found at exec time" "exit 127: 'nosuchcli-2475' executable not found on PATH at exec time"
guard diagnose codex "$CEG_TMP/nodeonly"
has "timeout absent -> timeout not found" "exit 127: 'timeout' not found on PATH"
case_end

case_begin "codex-core-input-limit" "bin/lib/codex-core.sh"
core "$FIX/big-kana-1048577.txt" 0
has "over limit -> FAILED input too large" "## Probe: FAILED — input too large: 1048577 chars > limit 1048576"
called "over limit -> codex not invoked" "$MOCK_CALLED" no
tmpfiles_gone "over limit -> prompt/stderr tmpfiles removed"
core "$FIX/big-kana-1048576.txt" 0
has "at limit -> PERFORMED" "## Probe: PERFORMED"
called "at limit -> codex invoked" "$MOCK_CALLED" yes
case_end

case_begin "codex-core-size-check-fails-closed" "bin/lib/codex-core.sh"
core "$FIX/small.txt" 0 "$CEG_TMP/badnode:$MOCK_PATH"
has "node failing -> FAILED input size check failed" "## Probe: FAILED — input size check failed"
lacks "node failing -> not PERFORMED" "## Probe: PERFORMED"
called "node failing -> codex not invoked" "$MOCK_CALLED" no
tmpfiles_gone "node failing -> prompt/stderr tmpfiles removed"
case_end

case_begin "codex-core-exit-127" "bin/lib/codex-core.sh"
core "$FIX/small.txt" 127
has "127 with codex on PATH -> resolves in parent" "resolves in parent"
has "127 with codex on PATH -> child environment likely broken" "child environment likely broken"
tmpfiles_gone "127 -> prompt/stderr tmpfiles removed"
core "$FIX/small.txt" 0 "$NO_CLI_PATH"
has "codex absent at exec -> not found at exec time" "'codex' executable not found on PATH at exec time"
core "$FIX/small.txt" 7
has "exit 7 unchanged" "exit code 7"
lacks "exit 7 carries no 127 diagnosis" "resolves in parent"
case_end

RPC_DIR="$CEG_TMP/rpc"
mkdir -p "$RPC_DIR/bin/lib" "$CEG_TMP/rpc-log"
cp "$SCRIPT_CHECKOUT_ROOT/bin/review-plan-codex" "$RPC_DIR/bin/review-plan-codex"
for _lib in codex-core.sh codex-timeout.sh cli-exec-guard.sh; do
  if [ -f "$SCRIPT_CHECKOUT_ROOT/bin/lib/$_lib" ]; then cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/$_lib" "$RPC_DIR/bin/lib/$_lib"; fi
done
# rpc <sid> <input> <mock-exit>
rpc() {
  rm -f "$MOCK_CALLED"
  PATH="$MOCK_PATH" MOCK_EXIT="$3" \
    run_with_timeout 120 bash "$RPC_DIR/bin/review-plan-codex" --format detail-plan \
    --session-id "$1" --log-dir "$CEG_TMP/rpc-log" --input "$2" --round 1 > "$OUT" 2>&1
}
round_log_has() { # <label> <sid> <verdict>
  if grep -qF -- "\"verdict\":\"$3\"" "$CEG_TMP/rpc-log/$2-plan.jsonl" 2>/dev/null; then pass "$1"
  else fail "$1" "round log lacks verdict $3: $(cat "$CEG_TMP/rpc-log/$2-plan.jsonl" 2>/dev/null)"; fi
}

case_begin "review-plan-codex-input-limit" "bin/review-plan-codex"
if command -v jq >/dev/null 2>&1; then
  rpc sid-big "$FIX/ascii-1048577.txt" 0
  _n="$(sed -n 's/.*FAILED — input too large: \([0-9][0-9]*\) chars > limit 1048576.*/\1/p' "$OUT" | head -n 1)"
  if [ -n "$_n" ] && [ "$_n" -gt "$LIMIT" ]; then pass "review-plan-codex over limit -> FAILED input too large ($_n)"
  else fail "review-plan-codex over limit -> FAILED input too large" "got: $(head -c 400 "$OUT")"; fi
  round_log_has "review-plan-codex over limit -> round log FAILED-input-too-large" sid-big FAILED-input-too-large
  called "review-plan-codex over limit -> codex not invoked" "$MOCK_CALLED" no
else
  skip "review-plan-codex input limit (jq not installed)"
fi
case_end

case_begin "review-plan-codex-exit-127" "bin/review-plan-codex"
if command -v jq >/dev/null 2>&1; then
  rpc sid-127 "$FIX/plan-small.md" 127
  has "review-plan-codex 127 -> resolves in parent" "resolves in parent"
  round_log_has "review-plan-codex 127 -> round log FAILED-exec" sid-127 FAILED-exec
else
  skip "review-plan-codex exit 127 (jq not installed)"
fi
case_end

case_begin "gemini-core-exit-127" "bin/lib/gemini-core.sh"
gem "$FIX/small.txt" 127
has "gemini 127 with gemini on PATH -> resolves in parent" "resolves in parent"
gem "$FIX/small.txt" 0 "$NO_CLI_PATH"
has "gemini absent -> not found at exec time" "'gemini' executable not found"
case_end

case_begin "gemini-core-skips-size-guard" "bin/lib/gemini-core.sh"
gem "$FIX/small.txt" 0 "" 1
has "gemini success -> GEMINI_OUTPUT set" "GEMINI_OUTPUT=gemini-ok"
called "gemini never calls the input-size guard" "$GUARD_CALLED" no
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
