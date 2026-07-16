#!/usr/bin/env bash
# run-completion.sh — clarify-intent Completion orchestrator (#1465)
# Args: --session-id <sid> --plans-dir <dir> [--non-github (silently ignored; gate is internal)]
# Env: AGENTS_CONFIG_DIR (required)
# Stdout: single token on last line: PROCEED | NEED_ISSUE | RETRY_EXHAUSTED | CLOSED_ENTRY | CREATED:<N> | CLOSED:<N> | RC2
# Exit: 0 on token output, 1 on hard error (missing args)
set -uo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR must be set}"

SESSION_ID=""
PLANS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id)  SESSION_ID="${2:-}"; shift 2 ;;
        --plans-dir)   PLANS_DIR="${2:-}"; shift 2 ;;
        --non-github)  shift ;;  # silently ignored — gate is internal
        *) echo "[run-completion] unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$SESSION_ID" ]] && { echo "[run-completion] --session-id is required" >&2; exit 1; }
[[ -z "$PLANS_DIR" ]]  && { echo "[run-completion] --plans-dir is required" >&2; exit 1; }

# Step 2 — NON_GITHUB gate (internal; never rely on caller-passed flag)
NON_GITHUB_ARG=()
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" 2>/dev/null; _gate_rc=$?
if [[ $_gate_rc -eq 1 ]]; then
    NON_GITHUB_ARG=(--non-github)
fi
# rc=2 → fail-open as GitHub (NON_GITHUB_ARG stays empty)

# Step 3 — Parse closes_issues via hooks/lib/parse-closes-issues.js
INTENT_PATH="$PLANS_DIR/$SESSION_ID-intent.md"
JSON=""
JSON="$(node -e "
const path = require('path');
const libPath = path.join(process.env.AGENTS_CONFIG_DIR, 'hooks', 'lib', 'parse-closes-issues.js');
try {
    const lib = require(libPath);
    if (typeof lib.parseClosesIssues === 'function') {
        process.stdout.write(JSON.stringify(lib.parseClosesIssues(process.argv[1])));
    }
    // else: standalone stub already output via side effect of require()
} catch (e) { process.stderr.write(e.message + '\n'); }
" "$INTENT_PATH" 2>/dev/null)" || { echo "[run-completion] parse-closes-issues failed" >&2; exit 1; }

# Step 4 — Build CLOSES_NUMBERS and REPO_MAP_ARGS
CLOSES_NUMBERS=""
REPO_MAP_ARGS=()
if [[ -n "$JSON" && "$JSON" != "[]" ]]; then
    _parsed="$(node -e "
const arr = JSON.parse(process.argv[1]);
const nums = arr.map(e => e.number).filter(Boolean).join(',');
process.stdout.write('CLOSES_NUMBERS=' + nums + '\n');
arr.forEach((e, i) => { if (e.repo) process.stdout.write('REPO_MAP_ARG=' + i + ':' + e.repo + '\n'); });
" "$JSON" 2>/dev/null)" || { echo "[run-completion] JSON parse failed" >&2; exit 1; }
    while IFS= read -r _line; do
        case "$_line" in
            CLOSES_NUMBERS=*) CLOSES_NUMBERS="${_line#CLOSES_NUMBERS=}" ;;
            REPO_MAP_ARG=*)   REPO_MAP_ARGS+=(--repo-map "${_line#REPO_MAP_ARG=}") ;;
        esac
    done <<< "$_parsed"
fi

# Step 5 — Phase 1: clarify-commit-scope.sh
SCOPE_RC=0
SCOPE_OUT="$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/clarify-commit-scope.sh" \
    --session-id "$SESSION_ID" \
    --plans-dir "$PLANS_DIR" \
    --issues "$CLOSES_NUMBERS" \
    "${REPO_MAP_ARGS[@]+"${REPO_MAP_ARGS[@]}"}" \
    "${NON_GITHUB_ARG[@]+"${NON_GITHUB_ARG[@]}"}" \
    2>/dev/null)" || SCOPE_RC=$?

if [[ $SCOPE_RC -eq 2 ]]; then
    # CLOSED:<N> or RC2
    printf '%s\n' "$SCOPE_OUT"
    exit 0
elif [[ $SCOPE_RC -eq 0 && -n "$SCOPE_OUT" ]]; then
    # CREATED:<N>
    printf '%s\n' "$SCOPE_OUT"
    exit 0
elif [[ $SCOPE_RC -eq 0 && -z "$SCOPE_OUT" ]]; then
    : # commit-scope success → proceed to guard-loop
else
    echo "[run-completion] clarify-commit-scope.sh failed (rc=$SCOPE_RC)" >&2
    exit 1
fi

# Step 6 — Phase 2: guard-loop
GUARD_OUT="$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/clarify-guard-loop.sh" \
    --session-id "$SESSION_ID" \
    --plans-dir "$PLANS_DIR" \
    "${NON_GITHUB_ARG[@]+"${NON_GITHUB_ARG[@]}"}" \
    2>/dev/null)"
printf '%s\n' "$GUARD_OUT"
exit 0
