# tests/skills/feature-2952-exit9-ledger/fixture.sh — shared setup for
# tests/skills/feature-2952-exit9-ledger*.sh (sourced, never run on its own).
# Tests: tests/skills/feature-2952-exit9-ledger/fixture.sh
# Tags: feature-2952, test-infrastructure, codex-review-loop, terminal-guard, scope:issue-specific
#
# Real stage wrappers from a throwaway checkout over a stubbed shared loop: the
# stub exits STUB_RC and, on 6, publishes <fmt>-terminal-ledger.txt holding
# STUB_LEDGER (the vs_emit hand-off of D6). About 2.3 s per wrapper run, so the
# cases are split over several files to stay inside the test-time budget.
# The caller sets SCRIPT_CHECKOUT_ROOT and sources tests/lib/harness.sh first.

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${SCRIPT_CHECKOUT_ROOT:-}" ]; then
    echo "fixture.sh is sourced by tests/skills/feature-2952-exit9-ledger*.sh; nothing to run on its own"
    exit 0
fi
# shellcheck source=tests/lib/codex-loop-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/codex-loop-fixture.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
PASS=0; FAIL=0; SKIP=0

T3_TMP="$(make_tmp)"
readonly T3_TMP
trap 'cd / 2>/dev/null; rm -rf "$T3_TMP"' EXIT
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
harness_isolate "$T3_TMP"
mkdir -p "$T3_TMP/empty-transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T3_TMP/empty-transcripts"
cd "$T3_TMP" || exit 1

P="$WORKFLOW_PLANS_DIR"
ROOT="$T3_TMP/agents"
script_checkout_fixture_copy "$ROOT" bin hooks skills
cat > "$ROOT/bin/run-codex-review-loop" <<'STUB'
#!/usr/bin/env bash
fmt=""; sid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --format) fmt="$2"; shift 2 ;;
    --session-id) sid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
rc="${STUB_RC:-1}"
if [ "$rc" = 6 ]; then
  ctl="$WORKFLOW_STATE_DIR/$sid.control"
  mkdir -p "$ctl"
  printf '%s\n' "$STUB_LEDGER" > "$ctl/$fmt-terminal-ledger.txt"
fi
exit "$rc"
STUB
chmod +x "$ROOT/bin/run-codex-review-loop"

REPO="$T3_TMP/repo"
mkdir -p "$REPO/tests"
git -C "$REPO" init -q -b main
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
printf 'init\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m init
printf 'reviewed\n' > "$REPO/reviewed.txt"
printf '#!/usr/bin/env bash\n' > "$REPO/tests/t.sh"
git -C "$REPO" add reviewed.txt tests/t.sh

ctl() { printf '%s/%s.control' "$WORKFLOW_STATE_DIR" "$1"; }
seed_sid() {
    printf '# Intent\n' > "$P/$1-intent.md"
    printf '# Outline\n' > "$P/$1-outline.md"
    printf '# Detail\n' > "$P/$1-detail.md"
    printf '# Test review\n' > "$P/$1-test-review.md"
}
# bump <fmt> <sid> — change exactly the input the format's wrapper fingerprints.
bump() {
    case "$1" in
        outline-plan) printf 'edit %s\n' "$RANDOM" >> "$P/$2-outline.md" ;;
        detail-plan|security-plan) printf 'edit %s\n' "$RANDOM" >> "$P/$2-detail.md" ;;
        *) printf 'edit %s\n' "$RANDOM" >> "$REPO/reviewed.txt"
           printf '# edit %s\n' "$RANDOM" >> "$REPO/tests/t.sh"
           git -C "$REPO" add reviewed.txt tests/t.sh ;;
    esac
}
# wrap <skill> <sid> <stub-rc> [ledger] — one real stage wrapper over the stub loop.
wrap() {
    local errf="$T3_TMP/wrap.err"
    W_RC=0
    ( cd "$REPO" || exit 1
      SESSION_ID="$2" PLANS_DIR="$P" EXTENSIONS_USED=0 STUB_RC="$3" STUB_LEDGER="${4:-}" \
          bash "$ROOT/skills/$1/scripts/run-codex-review-loop.sh" ) >/dev/null 2>"$errf" || W_RC=$?
    W_ERR="$(cat "$errf" 2>/dev/null)"
}
# ledger_open_high <file> <ledger-fmt> <sid> <id...> — a live ledger, one open HIGH per id.
ledger_open_high() {
    local f="$1" lf="$2" sid="$3" id
    shift 3
    mkdir -p "${f%/*}"
    {
        printf '#concern-ledger-v2|%s|%s|cycle=1\n' "$lf" "$sid"
        for id in "$@"; do
            printf '%s|HIGH|open|1|1|reviewed.txt#check_input:correctness|d%s|review-plan-codex|review-plan-codex|-|an unchecked input %s\n' "$id" "$id" "$id"
        done
    } > "$f"
}
# reject <ledger> <sid> <ledger-fmt> <id> — the real concern-ledger reject.
reject() {
    "$ROOT/bin/concern-ledger" reject --ledger "$1" --plans-dir "$P" --session-id "$2" \
        --format "$3" --id "$4" --reason "rejected by the user" >/dev/null 2>&1
}
# accept <sid> <fmt> — the real accept CLI. Sets A_RC / A_OUT.
accept() {
    A_RC=0
    A_OUT="$(node "$ROOT/bin/accept-exit6-residual" --session "$1" --format "$2" --reason "user accepted" 2>&1)" || A_RC=$?
}
term_line() { sed -n "${3}p" "$(ctl "$1")/$2-terminal.txt" 2>/dev/null | tr -d '\r'; }
marker_kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tr -d '\r'; }

# loop format | skill | ledger format | accept marker
FORMATS="$(cat <<'EOF'
outline-plan|make-outline-plan|outline-plan|outline-plan-exit6-accepted.txt
detail-plan|make-detail-plan|detail-plan|detail-plan-exit6-accepted.txt
security-plan|review-plan-security|security-plan|review-plan-security-exit6-accepted.txt
security-code|review-code-security|review-security-shared|security-code-exit6-accepted.txt
test-review|review-tests|test-review|review-tests-exit6-accepted.txt
EOF
)"

finish() {
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    [ "$FAIL" -eq 0 ]
}
