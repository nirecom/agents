#!/bin/bash
# Tests: skills/write-code/SKILL.md
# Tags: skill, shared-lib, scope:common
# Shared scaffolding for the feature-write-code-skill-static fragments, sourced by the
# dispatcher after REPO_ROOT is set: the grep helpers, the file paths under check and the
# closing summary. Holds no cases of its own.

if [ -n "${_WRITE_CODE_STATIC_LIB_SOURCED:-}" ]; then
    return 0
fi
_WRITE_CODE_STATIC_LIB_SOURCED=1

ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

has() {
    grep -E -- "$1" "$2" >/dev/null 2>&1
}
has_fixed() {
    grep -F -- "$1" "$2" >/dev/null 2>&1
}

require_file() {
    if [ ! -f "$1" ]; then
        fail "missing required file: $1"
        return 1
    fi
    return 0
}

WRITE_CODE_SKILL="$REPO_ROOT/skills/write-code/SKILL.md"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
NODEJS_RULES="$REPO_ROOT/rules/coding/nodejs.md"
PYTHON_RULES="$REPO_ROOT/rules/coding/python.md"
JEV_JUDGE_PROC="$REPO_ROOT/skills/_shared/jev-two-stage-judge.md"
COMPLEXITY_JUDGE_AGENT="$REPO_ROOT/agents/complexity-judge.md"

case_begin() { echo "--- group: $1 ---"; }
case_end()   { :; }

# static_finish: print the total and exit 0 (all passed) or 1.
static_finish() {
    echo
    if [ "$ERRORS" -eq 0 ]; then
        echo "All static checks passed."
        exit 0
    else
        echo "$ERRORS check(s) failed."
        exit 1
    fi
}
