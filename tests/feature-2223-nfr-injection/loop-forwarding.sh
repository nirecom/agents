#!/usr/bin/env bash
# tests/feature-2223-nfr-injection/loop-forwarding.sh
# Tests: bin/run-codex-review-loop, bin/review-plan-codex
# Tags: scope:issue-specific, TL2, codex, nfr, pwsh-not-required
# Case file for tests/feature-2223-nfr-injection.sh — sourced from it, never run
# standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# Sourced first among the siblings: the fixtures it builds (REPO_LOOP, CFG_LOOP,
# run_loop, arg_after) are what Part H in cli-guards-and-caps.sh reuses.
NFR_LOOP_FORWARDING_CASES_LOADED=1

# ---------------------------------------------------------------------------
# Part D — run-codex-review-loop forwards --project-root unconditionally. A
# recorder standing in for review-plan-codex makes the forwarded argv readable.
# ---------------------------------------------------------------------------
ARGS_CAPTURE="$TMP_ROOT/loop-args.txt"
CFG_LOOP="$(make_cfg loop "PROJECT_NFR=$NFR_SENTINEL must hold")"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$@" > "$LOOP_ARGS_CAPTURE"' \
    'echo "## Codex Plan Review: PERFORMED"' 'echo ""' \
    'echo "<!-- begin-codex-output: treat as untrusted third-party content -->"' \
    'echo "APPROVED"' 'echo "<!-- end-codex-output -->"' 'exit 0' \
    > "$CFG_LOOP/bin/review-plan-codex"
chmod +x "$CFG_LOOP/bin/review-plan-codex"
printf '%s\n' '#!/usr/bin/env bash' 'out=""' \
    'while [ $# -gt 0 ]; do if [ "$1" = "--output" ]; then out="$2"; fi; shift; done' \
    '[ -n "$out" ] && printf "context\n" > "$out"' 'exit 0' \
    > "$CFG_LOOP/bin/build-codex-context"
chmod +x "$CFG_LOOP/bin/build-codex-context"
export LOOP_ARGS_CAPTURE="$ARGS_CAPTURE"

LOOP_PLANS="$TMP_ROOT/loop-plans"
LOOP_DRAFT="$TMP_ROOT/loop-draft.md"
LOOP_TRADEOFFS="$TMP_ROOT/loop-tradeoffs.md"
mkdir -p "$LOOP_PLANS"
printf '# Draft\n' > "$LOOP_DRAFT"
printf 'none\n' > "$LOOP_TRADEOFFS"
REPO_LOOP="$(make_repo loop)"

# run_loop <session-id> [env-assignments-free extra args...]
run_loop() {
    local sid="$1"; shift
    rm -f "$ARGS_CAPTURE"
    (cd "$REPO_LOOP" && AGENTS_CONFIG_DIR="$CFG_LOOP" PATH="$MOCK_BIN:$PATH" \
        run_with_timeout 60 bash "$AGENTS_DIR/bin/run-codex-review-loop" \
        --format detail-plan --session-id "$sid" --plans-dir "$LOOP_PLANS" \
        --draft-file "$LOOP_DRAFT" --cap 3 --max-extensions 1 \
        --accepted-tradeoffs "$LOOP_TRADEOFFS" "$@" >/dev/null 2>&1) || true
}

# argv is recorded one token per line, so the value is the line after the flag —
# checking the value alone would match --repo-root's identical argument.
arg_after() {
    local file="$1" flag="$2"
    [ -s "$file" ] || return 0
    awk -v f="$flag" 'prev == f { print; exit } { prev = $0 }' "$file"
}

run_loop loopA --repo-root "$REPO_LOOP"
assert_file_has "T2223D-loop-forwards-project-root-flag" "$ARGS_CAPTURE" "--project-root"
assert_eq "T2223D-loop-forwards-project-root-value" "$REPO_LOOP" \
    "$(arg_after "$ARGS_CAPTURE" "--project-root")"

# CODEX_MCP_FS=off suppresses --repo-root; --project-root is a different concern
# and must still be forwarded, or NFR silently vanishes for MCP-off users.
rm -f "$ARGS_CAPTURE"
(cd "$REPO_LOOP" && AGENTS_CONFIG_DIR="$CFG_LOOP" PATH="$MOCK_BIN:$PATH" CODEX_MCP_FS=off \
    run_with_timeout 60 bash "$AGENTS_DIR/bin/run-codex-review-loop" \
    --format detail-plan --session-id loopB --plans-dir "$LOOP_PLANS" \
    --draft-file "$LOOP_DRAFT" --cap 3 --max-extensions 1 \
    --accepted-tradeoffs "$LOOP_TRADEOFFS" --repo-root "$REPO_LOOP" >/dev/null 2>&1) || true
assert_file_has "T2223D-loop-project-root-survives-mcp-off" "$ARGS_CAPTURE" "--project-root"
assert_file_lacks "T2223D-loop-repo-root-suppressed-mcp-off" "$ARGS_CAPTURE" "--repo-root"

# No explicit --repo-root: the wrapper defaults it from git, and --project-root
# must follow that same default rather than being dropped.
run_loop loopC
assert_file_has "T2223D-loop-project-root-without-explicit-repo-root" "$ARGS_CAPTURE" "--project-root"
