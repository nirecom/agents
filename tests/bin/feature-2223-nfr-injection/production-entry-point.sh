#!/usr/bin/env bash
# tests/bin/feature-2223-nfr-injection/production-entry-point.sh
# Tests: skills/review-code-security/scripts/run-codex-review-loop.sh, bin/run-codex-review-loop, bin/review-code-codex
# Tags: scope:issue-specific, TL2, codex, nfr, e2e-path, pwsh-not-required
# Case file for tests/bin/feature-2223-nfr-injection.sh — sourced from it, never run
# standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# Every other case in this suite hands --project-root to the reviewer itself.
# That proves the plumbing works when someone supplies the flag; it says nothing
# about the real code-review entry point, which supplies no such flag. This file
# drives the production call site's own argv rather than a constructed one.
NFR_PRODUCTION_ENTRY_CASES_LOADED=1

# ---------------------------------------------------------------------------
# Part L — the argv the real code-review entry point uses.
# #2276 moved the codex security review out of run-quality-gates.sh and into the
# shared loop, so the production call site is now the skill's own wrapper. Both
# files are read rather than executed: the gate runs seven further gates plus git
# plumbing against the caller's repo, and what decides the NFR's fate is the one
# wrapper line, read from disk so a change to it changes this test's answer.
# ---------------------------------------------------------------------------
GATES_SCRIPT="$AGENTS_DIR/skills/review-code-security/scripts/run-quality-gates.sh"
LOOP_WRAPPER="$AGENTS_DIR/skills/review-code-security/scripts/run-codex-review-loop.sh"

if [ -f "$GATES_SCRIPT" ]; then
    pass "T2223L-gate-script-present"
else
    fail "T2223L-gate-script-present — $GATES_SCRIPT missing"
fi

if [ -f "$LOOP_WRAPPER" ]; then
    pass "T2223L-loop-wrapper-present"
else
    fail "T2223L-loop-wrapper-present — $LOOP_WRAPPER missing"
fi

# The gate must no longer reach a codex reviewer at all: the loop owns that now,
# and a gate that still shelled out to one would review the same diff twice.
assert_file_lacks "T2223L-gate-no-longer-runs-the-codex-review" "$GATES_SCRIPT" "review-code-ledger"

LOOP_CALL="$TMP_ROOT/loop-call.txt"
if grep -qF 'run-codex-review-loop' "$LOOP_WRAPPER" 2>/dev/null \
    && grep -qF -- '--format' "$LOOP_WRAPPER" 2>/dev/null; then
    grep -F 'run-codex-review-loop' "$LOOP_WRAPPER" > "$LOOP_CALL" 2>/dev/null || true
    pass "T2223L-wrapper-invokes-the-shared-loop"
else
    fail "T2223L-wrapper-invokes-the-shared-loop — no --format line for run-codex-review-loop found"
    : > "$LOOP_CALL"
fi
assert_file_has "T2223L-wrapper-selects-the-security-code-format" "$LOOP_WRAPPER" "security-code"

# The production line passes the loop's own flags and nothing else, and it is
# right not to: review-code-codex reviews the repo it is invoked from, so it
# defaults its own project root to that repo and the NFR arrives without the
# wrapper naming one. This row pins the argv the replay below imitates — were the
# wrapper to start passing --project-root, the replay would stop being the
# production path and would have to be rewritten.
assert_file_lacks "T2223L-wrapper-omits-project-root" "$LOOP_CALL" "--project-root"

# ---------------------------------------------------------------------------
# The same argv, replayed end to end. The fixture repo carries PROJECT_NFR in
# its own .env.local — the exact scenario issue #2223 exists for — and the mock
# codex captures the prompt the production flag set really produces.
# ---------------------------------------------------------------------------
PROD_SENTINEL="PRODNFRSENTINEL8VC"
CFG_PROD="$(make_cfg prod "CODE_LANG=english")"
REPO_PROD="$(make_repo prod)"
printf 'PROJECT_NFR=%s from-project-dot-env-local\n' "$PROD_SENTINEL" > "$REPO_PROD/$LOCAL_ENV_BASENAME"
PROD_CONTEXT="$CFG_PROD/rules/core-principles.md"
PROD_TRADEOFFS="$TMP_ROOT/prod-tradeoffs.md"
printf 'none\n' > "$PROD_TRADEOFFS"
PROD_SEQ=0

# run_secloop_in <cfg> <repo> <extra args...> — the security-code loop with the
# wrapper's own flag set, run inside the given repo. Each call gets a plans dir
# and a session of its own so the round counter never carries between rows.
run_secloop_in() {
    local cfg="$1" repo="$2"; shift 2
    PROD_SEQ=$((PROD_SEQ + 1))
    local plans="$TMP_ROOT/prod-plans-$PROD_SEQ"
    mkdir -p "$plans"
    rm -f "$CAPTURE"
    (cd "$repo" && run_with_timeout 90 env -u CODEX_REVIEW_MAX_DIFF_LINES \
        AGENTS_CONFIG_DIR="$cfg" PATH="$MOCK_BIN:$PATH" \
        bash "$AGENTS_DIR/bin/run-codex-review-loop" --format security-code \
        --session-id "prodnfr$PROD_SEQ" --plans-dir "$plans" \
        --cap 2 --max-extensions 1 --extensions-used 0 \
        --accepted-tradeoffs "$PROD_TRADEOFFS" --repo-root "$repo" \
        --context "$PROD_CONTEXT" "$@" \
        >/dev/null 2>&1) || true
}

# run_secloop <extra args...> — the same against the NFR-carrying fixture.
run_secloop() { run_secloop_in "$CFG_PROD" "$REPO_PROD" "$@"; }

# The prompt must exist before any claim about its contents counts as evidence.
run_secloop
assert_file_has "T2223L-production-argv-produces-a-prompt" "$CAPTURE" "[DIFF START]"
assert_file_has "T2223L-production-argv-carries-project-nfr" "$CAPTURE" "$PROD_SENTINEL"
assert_file_has "T2223L-production-argv-frames-project-nfr" "$CAPTURE" "[PROJECT NFR START]"

# Control: the identical fixture with --project-root spelled out still delivers
# the NFR. That path was never broken, and keeping it pinned proves the new
# default supplements an explicit flag rather than displacing it.
run_secloop --project-root "$REPO_PROD"
assert_file_has "T2223L-same-fixture-with-project-root-carries-nfr" "$CAPTURE" "$PROD_SENTINEL"
assert_file_has "T2223L-same-fixture-with-project-root-frames-nfr" "$CAPTURE" "[PROJECT NFR START]"

# Regression guard on the default itself: a project that declares no NFR
# anywhere — no .env.local of its own, nothing in the global .env — must still
# review cleanly, with no empty NFR frame invented on its behalf. Without this
# row the default could satisfy every case above by always emitting a block.
CFG_BARE="$(make_cfg prodbare "CODE_LANG=english")"
REPO_BARE="$(make_repo prodbare)"
run_secloop_in "$CFG_BARE" "$REPO_BARE"
assert_file_has "T2223L-no-nfr-anywhere-still-produces-a-prompt" "$CAPTURE" "[DIFF START]"
assert_file_lacks "T2223L-no-nfr-anywhere-no-frame-start" "$CAPTURE" "[PROJECT NFR START]"
assert_file_lacks "T2223L-no-nfr-anywhere-no-frame-end" "$CAPTURE" "[PROJECT NFR END]"
assert_file_lacks "T2223L-no-nfr-anywhere-no-trust-label" "$CAPTURE" \
    "data supplied by the reviewed project"
