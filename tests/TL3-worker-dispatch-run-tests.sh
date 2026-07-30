#!/usr/bin/env bash
# tests/TL3-worker-dispatch-run-tests.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/emit.js, bin/worker-dispatch/spawn.js, tests/run-all.sh
# Tags: worker-dispatch, test-runner, real-environment, yaml, log-tail, sentinel, TL3, scope:common
#
# TL3 — single real seam: the real bin/worker-dispatch.js drives the real
# tests/run-all.sh through the real bash, against the real PLANS_DIR. Nothing is
# stubbed. This is what the sibling TL2 files cannot do:
#   - real run-all.sh output format feeding the failing_tests parser
#   - real PLANS_DIR resolution (bin/get-config-var / WORKFLOW_PLANS_DIR)
#   - real spawnSync env allowlist against a real PATH
#
# Deliberately NOT TL4: only the test-runner seam runs here. The full
# workflow-init → Final Report pipeline is out of scope (roadmap #1543).
#
# Gate: RUN_TL3=on. Exits 77 (SKIP in tests/run-all.sh) otherwise.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v git >/dev/null 2>&1 || exit 77

DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if [ ! -f "$DISPATCH_JS" ]; then
    fail "tl3/dispatcher-present — implementation missing: bin/worker-dispatch.js"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

# Real main worktree root (this file may run from a linked worktree).
MAIN_ROOT_RAW="$(git -C "$AGENTS_DIR" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
[ -n "$MAIN_ROOT_RAW" ] || MAIN_ROOT_RAW="$AGENTS_DIR"
MAIN_ROOT="$(nodepath "$MAIN_ROOT_RAW")"

PLANS_RAW="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
mkdir -p "$PLANS_RAW" || exit 77
PLANS="$(nodepath "$PLANS_RAW")"

TMPD="$(mktemp -d)"
STAMP="tl3wd-$$"
PAYLOAD="$PLANS_RAW/${STAMP}-worker-test-runner.json"
cleanup() { rm -f "$PAYLOAD"; rm -rf "$TMPD"; }
trap cleanup EXIT

# Sacrificial fixture suite: kept OUTSIDE tests/ so tests/run-all.sh never picks
# it up on its own, and so the real suite's runtime is not paid here.
FIXTURE="$TMPD/tl3-fixture-pass.sh"
cat > "$FIXTURE" <<'FIX'
#!/usr/bin/env bash
echo "fixture ok"
exit 0
FIX
FIXTURE_FAIL="$TMPD/tl3-fixture-fail.sh"
cat > "$FIXTURE_FAIL" <<'FIXF'
#!/usr/bin/env bash
echo "fixture deliberately failing"
exit 1
FIXF
chmod +x "$FIXTURE" "$FIXTURE_FAIL"

yaml_field() { sed -n "s/^$2: //p" "$1" | head -1; }

dispatch_test_runner() {
    local out="$1"; shift
    local args_json="$1"
    printf '{"test_args":%s,"cwd":"%s","timeout_seconds":300}' "$args_json" "$(nodepath "$AGENTS_DIR")" > "$PAYLOAD"
    run_with_timeout 420 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$(nodepath "$DISPATCH_JS")" test-runner "$MAIN_ROOT" "$(nodepath "$PAYLOAD")" > "$out" 2>"$out.err"
    return $?
}

PLANS_BEFORE="$(cd "$PLANS_RAW" && find . -type f | LC_ALL=C sort)"

# ===========================================================================
# Group A — passing suite: real YAML contract
# ===========================================================================
OUT="$TMPD/pass.yaml"
RC=0
dispatch_test_runner "$OUT" "[\"$(nodepath "$FIXTURE")\"]" || RC=$?
assert_eq "tl3/pass/exit-0" "0" "$RC"
assert_eq "tl3/pass/status" "pass" "$(yaml_field "$OUT" status)"
assert_eq "tl3/pass/exit-code" "0" "$(yaml_field "$OUT" exit_code)"
if grep -q '^failing_tests: \[\]$' "$OUT"; then pass "tl3/pass/failing-tests-empty-literal"
else fail "tl3/pass/failing-tests-empty-literal — 'failing_tests: []' absent"; fi
if grep -q '^log_tail: |$' "$OUT"; then pass "tl3/pass/log-tail-block-scalar"
else fail "tl3/pass/log-tail-block-scalar — 'log_tail: |' absent"; fi
if grep -qE '^duration_seconds: [0-9]+$' "$OUT"; then pass "tl3/pass/duration-int"
else fail "tl3/pass/duration-int — duration_seconds not an integer"; fi

TAIL_LINES="$(sed -n '/^log_tail: |$/,$p' "$OUT" | tail -n +2 | grep -c . || true)"
if [ "${TAIL_LINES:-0}" -le 40 ]; then pass "tl3/pass/log-tail-max-40"
else fail "tl3/pass/log-tail-max-40 — $TAIL_LINES lines"; fi

SUM_LEN="$(yaml_field "$OUT" summary | awk '{print length($0)}' | head -1)"
if [ "${SUM_LEN:-0}" -le 300 ]; then pass "tl3/pass/summary-max-300"
else fail "tl3/pass/summary-max-300 — $SUM_LEN chars"; fi

# ===========================================================================
# Group B — failing suite: status fail, real run-all.sh FAIL line is parsed
# ===========================================================================
OUT2="$TMPD/fail.yaml"
RC2=0
dispatch_test_runner "$OUT2" "[\"$(nodepath "$FIXTURE_FAIL")\"]" || RC2=$?
assert_eq "tl3/fail/exit-0" "0" "$RC2"
assert_eq "tl3/fail/status" "fail" "$(yaml_field "$OUT2" status)"
if grep -q '^failing_tests: \[\]$' "$OUT2"; then
    fail "tl3/fail/failing-tests-populated — empty list despite a failing test"
elif grep -qE '^\s+- ' "$OUT2"; then
    pass "tl3/fail/failing-tests-populated"
elif grep -q 'parse-degraded' "$OUT2"; then
    # The plan forbids silently returning [] — an unparsable format must say so.
    pass "tl3/fail/failing-tests-populated (parse-degraded declared)"
else
    fail "tl3/fail/failing-tests-populated — neither entries nor 'parse-degraded'"
fi

# ===========================================================================
# Group C — containment: no log files written, no sentinel leakage
# ===========================================================================
PLANS_AFTER="$(cd "$PLANS_RAW" && find . -type f | LC_ALL=C sort)"
EXTRA="$(comm -13 <(printf '%s\n' "$PLANS_BEFORE") <(printf '%s\n' "$PLANS_AFTER") | grep -v "$STAMP" || true)"
assert_eq "tl3/containment/no-new-plans-files" "" "$EXTRA"

LEAK=0
for f in "$OUT" "$OUT2" "$OUT.err" "$OUT2.err"; do
    [ -f "$f" ] || continue
    if grep -qiE '<<[[:space:]]*WORKFLOW' "$f"; then LEAK=1; fi
done
assert_eq "tl3/containment/no-sentinel-in-output" "0" "$LEAK"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
