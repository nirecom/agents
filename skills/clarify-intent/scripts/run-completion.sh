#!/usr/bin/env bash
# run-completion.sh — clarify-intent Completion orchestrator (#1465)
# Args: --session-id <sid> --plans-dir <dir> [--non-github (silently ignored; gate is internal)]
# Stdout: single token on last line: PROCEED | NEED_ISSUE | RETRY_EXHAUSTED | CLOSED_ENTRY | CREATED:<N> | CLOSED:<N> | RC2
#         | UNAPPROVED | APPROVAL_UNKNOWN (Phase 1 approval gate, #2277)
# Exit: 0 on token output, 1 on hard error (missing args)
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

SESSION_ID=""
PLANS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id)  [[ $# -ge 2 ]] || { echo "[run-completion] $1 needs a value" >&2; exit 1; }; SESSION_ID="${2:-}"; shift 2 ;;
        --plans-dir)   [[ $# -ge 2 ]] || { echo "[run-completion] $1 needs a value" >&2; exit 1; }; PLANS_DIR="${2:-}"; shift 2 ;;
        --non-github)  shift ;;  # silently ignored — gate is internal
        *) echo "[run-completion] unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$SESSION_ID" ]] && { echo "[run-completion] --session-id is required" >&2; exit 1; }
[[ -z "$PLANS_DIR" ]]  && { echo "[run-completion] --plans-dir is required" >&2; exit 1; }

# Phase 1 — plan approval gate (#2277): no side effect runs before the intent is approved.
# The CLI prints exactly one APPROVAL=<v> line; anything else is unreadable and fails closed.
APPROVAL_RC=0
APPROVAL_OUT="$(node "$SCRIPT_CHECKOUT_ROOT/bin/workflow/check-plan-approval" \
    --session "$SESSION_ID" --step clarify_intent 2>/dev/null)" || APPROVAL_RC=$?
APPROVAL_OUT="${APPROVAL_OUT%$'\r'}"
if [[ $APPROVAL_RC -ne 0 ]]; then
    echo "APPROVAL_UNKNOWN"; exit 0
fi
case "$APPROVAL_OUT" in
    "APPROVAL=approved") : ;;
    "APPROVAL=unapproved") echo "UNAPPROVED"; exit 0 ;;
    *) echo "APPROVAL_UNKNOWN"; exit 0 ;;
esac

# Phase 2 — NON_GITHUB gate (internal; never rely on caller-passed flag)
NON_GITHUB_ARG=()
"$SCRIPT_CHECKOUT_ROOT/bin/is-github-dotcom-remote" 2>/dev/null; _gate_rc=$?
if [[ $_gate_rc -eq 1 ]]; then
    NON_GITHUB_ARG=(--non-github)
fi
# rc=2 → fail-open as GitHub (NON_GITHUB_ARG stays empty)

# Phase 3 — Parse closes_issues via hooks/lib/parse-closes-issues.js
# The intent of the session chain is named after first_session_id (#2748); no own-sid fallback.
INTENT_PATH="$(node "$SCRIPT_CHECKOUT_ROOT/bin/plan-artifact-path" --stage intent --session "$SESSION_ID" --plans-dir "$PLANS_DIR" 2>/dev/null)" || INTENT_PATH=""
if [[ -z "$INTENT_PATH" ]]; then
    echo "clarify-intent/run-completion: cannot resolve the intent path" >&2
    exit 1
fi
JSON=""
JSON="$(node -e "
const path = require('path');
const libPath = path.join(process.argv[2], 'hooks', 'lib', 'parse-closes-issues.js');
try {
    const lib = require(libPath);
    if (typeof lib.parseClosesIssues === 'function') {
        process.stdout.write(JSON.stringify(lib.parseClosesIssues(process.argv[1])));
    }
    // else: standalone stub already output via side effect of require()
} catch (e) { process.stderr.write(e.message + '\n'); }
" "$INTENT_PATH" "$SCRIPT_CHECKOUT_ROOT" 2>/dev/null)" || { echo "[run-completion] parse-closes-issues failed" >&2; exit 1; }

# Phase 4 — Build CLOSES_NUMBERS and REPO_MAP_ARGS
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

# Phase 5 — clarify-commit-scope.sh
SCOPE_RC=0
SCOPE_OUT="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/clarify-commit-scope.sh" \
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

# Phase 6 — guard-loop
GUARD_OUT="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/clarify-guard-loop.sh" \
    --session-id "$SESSION_ID" \
    --plans-dir "$PLANS_DIR" \
    "${NON_GITHUB_ARG[@]+"${NON_GITHUB_ARG[@]}"}" \
    2>/dev/null)"
printf '%s\n' "$GUARD_OUT"
exit 0
