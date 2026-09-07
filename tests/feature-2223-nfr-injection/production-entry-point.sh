#!/usr/bin/env bash
# tests/feature-2223-nfr-injection/production-entry-point.sh
# Tests: skills/review-code-security/scripts/run-quality-gates.sh, bin/review-code-ledger, bin/review-code-codex
# Tags: scope:issue-specific, TL2, codex, nfr, e2e-path, pwsh-not-required
# Case file for tests/feature-2223-nfr-injection.sh — sourced from it, never run
# standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# Every other case in this suite hands --project-root to the reviewer itself.
# That proves the plumbing works when someone supplies the flag; it says nothing
# about the real code-review entry point, which supplies no such flag. This file
# drives the production call site's own argv rather than a constructed one.
NFR_PRODUCTION_ENTRY_CASES_LOADED=1

# ---------------------------------------------------------------------------
# Part L — the argv the real code-review gate uses.
# The gate script is read rather than executed: run-quality-gates.sh runs eight
# further gates plus git plumbing against the caller's own repo and session, so
# executing it here would measure the harness. What decides the NFR's fate is
# one line of it — the review-code-ledger invocation — and that line is read
# from the file on disk, so a change to it changes this test's answer.
# ---------------------------------------------------------------------------
GATES_SCRIPT="$AGENTS_DIR/skills/review-code-security/scripts/run-quality-gates.sh"
if [ -f "$GATES_SCRIPT" ]; then
    pass "T2223L-gate-script-present"
else
    fail "T2223L-gate-script-present — $GATES_SCRIPT missing"
fi

LEDGER_CALL="$TMP_ROOT/ledger-call.txt"
grep -F 'bin/review-code-ledger' "$GATES_SCRIPT" 2>/dev/null | grep -F '_run_gate' > "$LEDGER_CALL" || true
if [ -s "$LEDGER_CALL" ]; then
    pass "T2223L-gate-invokes-review-code-ledger"
else
    fail "T2223L-gate-invokes-review-code-ledger — no _run_gate line for review-code-ledger found"
fi

# The production line passes --base, --base-state and --context and nothing
# else, and it is right not to: review-code-codex reviews the repo it is invoked
# from, so it defaults its own project root to that repo and the NFR arrives
# without the gate naming one. This row pins the argv the replay below imitates
# — were the gate to start passing --project-root, the replay would stop being
# the production path and would have to be rewritten.
assert_file_lacks "T2223L-gate-omits-project-root" "$LEDGER_CALL" "--project-root"

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

# run_ledger_in <cfg> <repo> <extra args...> — review-code-ledger with the
# gate's own flag set, run inside the given repo.
run_ledger_in() {
    local cfg="$1" repo="$2"; shift 2
    rm -f "$CAPTURE"
    (cd "$repo" && run_with_timeout 90 env -u CODEX_REVIEW_MAX_DIFF_LINES \
        AGENTS_CONFIG_DIR="$cfg" PATH="$MOCK_BIN:$PATH" \
        bash "$AGENTS_DIR/bin/review-code-ledger" \
        --base main --base-state RESOLVED --context "$PROD_CONTEXT" "$@" \
        >/dev/null 2>&1) || true
}

# run_ledger <extra args...> — the same against the NFR-carrying fixture.
run_ledger() { run_ledger_in "$CFG_PROD" "$REPO_PROD" "$@"; }

# The prompt must exist before any claim about its contents counts as evidence.
run_ledger
assert_file_has "T2223L-production-argv-produces-a-prompt" "$CAPTURE" "[DIFF START]"
assert_file_has "T2223L-production-argv-carries-project-nfr" "$CAPTURE" "$PROD_SENTINEL"
assert_file_has "T2223L-production-argv-frames-project-nfr" "$CAPTURE" "[PROJECT NFR START]"

# Control: the identical fixture with --project-root spelled out still delivers
# the NFR. That path was never broken, and keeping it pinned proves the new
# default supplements an explicit flag rather than displacing it.
run_ledger --project-root "$REPO_PROD"
assert_file_has "T2223L-same-fixture-with-project-root-carries-nfr" "$CAPTURE" "$PROD_SENTINEL"
assert_file_has "T2223L-same-fixture-with-project-root-frames-nfr" "$CAPTURE" "[PROJECT NFR START]"

# Regression guard on the default itself: a project that declares no NFR
# anywhere — no .env.local of its own, nothing in the global .env — must still
# review cleanly, with no empty NFR frame invented on its behalf. Without this
# row the default could satisfy every case above by always emitting a block.
CFG_BARE="$(make_cfg prodbare "CODE_LANG=english")"
REPO_BARE="$(make_repo prodbare)"
run_ledger_in "$CFG_BARE" "$REPO_BARE"
assert_file_has "T2223L-no-nfr-anywhere-still-produces-a-prompt" "$CAPTURE" "[DIFF START]"
assert_file_lacks "T2223L-no-nfr-anywhere-no-frame-start" "$CAPTURE" "[PROJECT NFR START]"
assert_file_lacks "T2223L-no-nfr-anywhere-no-frame-end" "$CAPTURE" "[PROJECT NFR END]"
assert_file_lacks "T2223L-no-nfr-anywhere-no-trust-label" "$CAPTURE" \
    "data supplied by the reviewed project"
