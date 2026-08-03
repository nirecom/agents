#!/usr/bin/env bash
# Tests: hooks/enforce-system-ops.js
# Tags: system-ops, enforce, hook, classifier, table-driven, mutation-probe, security, scope:cross-cutting, pwsh-not-required, TL2
#
# Table-driven classifier coverage for hooks/enforce-system-ops.js (review gap C8).
#
# WHAT THIS FILE DEFENDS
# tests/feature-enforce-system-ops.sh already enumerates the per-command block
# list, but as ~130 independent `expect_block` / `expect_pass` calls. Three
# properties that guard are NOT covered there, and each one is a full-bypass
# class rather than a single missing command:
#
#   (1) THE ENV BRANCH. `SYSTEM_OPS_APPROVED` is the only bypass, and the source
#       comment (hooks/enforce-system-ops.js:5-6) says it must be honoured ONLY
#       as an inherited process env value equal to the string "1". Every other
#       spelling — inline `VAR=1 cmd` prefix, an inline `export`, "0", "true",
#       " 1" — must keep the guard armed. If any of those started bypassing,
#       the model could disarm the guard from inside a tool call.
#   (2) INTERPRETER WRAPPING. `stripQuotedArgs` blanks quoted spans, so the whole
#       payload of `bash -c '<blocked cmd>'` disappears before classification.
#       getInnerBodies() is what re-exposes it. Its reach is asserted here in
#       both directions — the shapes it DOES recover, and the shapes it does NOT
#       (recorded as current behaviour, not as endorsement; see section W).
#   (3) PAYLOAD SHAPE + MALFORMED INPUT. The hook is a PreToolUse guard: a throw
#       on malformed stdin kills the process and the tool layer reads that as
#       "no objection" — fail-OPEN. Every degenerate stdin shape must therefore
#       exit 0 cleanly (rc 0), never rc 1.
#
# FALSE-GREEN GUARD
# A verdict is never inferred from "did not block". run_case() maps the exit
# status to an explicit token — ALLOW(0) / BLOCK(2) / RC<n> for anything else —
# and a BLOCK additionally requires the documented stderr banner, so a crash,
# a timeout, or a silent exit can never be read as a passing ALLOW or BLOCK.
#
# TL3 gap (what this test does NOT catch):
# - Real Claude Code PreToolUse dispatch. This drives the hook as a subprocess
#   with hand-built JSON; it cannot catch settings.json failing to register the
#   hook for a tool name, because matcher evaluation happens in the host before
#   any hook code runs. Section R asserts the registration against settings.json
#   as the closest reachable proxy.
# - Real pwsh/cmd.exe quoting. Section W's PowerShell rows model the payload
#   TEXT a PowerShell tool call would carry; they do not run a real shell.
# Closest-to-action mitigation: registration is asserted from settings.json in
# section R, so a de-registration fails here rather than silently in production.
#
# Case bodies live in tests/enforce-system-ops-classifier/ (rules/coding/file-split.md);
# this file is the shared harness plus dispatch.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$AGENTS_DIR/hooks/enforce-system-ops.js"
SETTINGS="$AGENTS_DIR/settings.json"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

# Portable timeout wrapper (rules/test/macos-timeout.md).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$HOOK" ]; then
    echo "FAIL: precondition missing — hooks/enforce-system-ops.js"
    echo ""
    echo "Results: 0 passed, 1 failed, 0 skipped"
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ERRF="$TMP/stderr.txt"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# json_escape <text> — minimal JSON string-body escaping for the table cells.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# expand_placeholders <text> — a table cell cannot contain the field delimiter,
# so a literal shell pipe is written as %PIPE% and restored here.
expand_placeholders() {
    local s="$1"
    s="${s//%PIPE%/|}"
    printf '%s' "$s"
}

# topath <posix-path> — Git Bash hands Node a POSIX-style path; normalize to the
# `C:/...` form Node's own path APIs accept (rules/test/fixture-isolation.md).
topath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# run_json <raw-json> [env-assignment] -> ALLOW | BLOCK | BLOCK-NO-BANNER | RC<n>
# The env argument selects the SYSTEM_OPS_APPROVED branch:
#   "unset"     -> variable removed from the hook's environment
#   "<value>"   -> variable exported with that exact value (inherited branch)
run_json() {
    # NOTE: ${2-unset} (no colon) — an EMPTY env value is a distinct branch that
    # must reach the hook as an exported empty string, not fall back to "unset".
    local json="$1" envspec="${2-unset}" rc
    : > "$ERRF"
    if [ "$envspec" = "unset" ]; then
        printf '%s' "$json" | (
            unset SYSTEM_OPS_APPROVED
            run_with_timeout 15 node "$HOOK" >/dev/null 2>"$ERRF"
        )
    else
        printf '%s' "$json" | (
            export SYSTEM_OPS_APPROVED="$envspec"
            run_with_timeout 15 node "$HOOK" >/dev/null 2>"$ERRF"
        )
    fi
    rc=$?
    case "$rc" in
        0) printf 'ALLOW' ;;
        2)
            if grep -q "enforce-system-ops: blocked" "$ERRF" 2>/dev/null; then
                printf 'BLOCK'
            else
                printf 'BLOCK-NO-BANNER'
            fi
            ;;
        124) printf 'TIMEOUT' ;;
        *) printf 'RC%s' "$rc" ;;
    esac
}

# run_cmd <command-text> [tool] [env] -> verdict token
run_cmd() {
    local cmd tool envspec json
    cmd="$(expand_placeholders "$1")"
    tool="${2:-Bash}"
    envspec="${3-unset}"
    json="{\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"$(json_escape "$cmd")\"}}"
    run_json "$json" "$envspec"
}

# category_of <command-text> -> the "(X ...)" label the hook reports, or NONE
category_of() {
    local cmd json
    cmd="$(expand_placeholders "$1")"
    json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$(json_escape "$cmd")\"}}"
    run_json "$json" unset >/dev/null
    # The banner reads `blocked (A (winget)).` — the label itself contains
    # parentheses, so the extraction has to span to the LAST `)` before the `.`.
    local label
    label="$(sed -n 's/.*enforce-system-ops: blocked (\(.*\))\..*/\1/p' "$ERRF" | head -1 | tr -d '\r\n')"
    if [ -z "$label" ]; then printf 'NONE'; else printf '%s' "$label"; fi
}

# ── harness self-check: a driver that cannot reach the hook must not report a
# table of green ALLOWs. Both directions of the harness are pinned first.
assert_eq "H1 harness reports BLOCK for a canonical category-A command" \
    "BLOCK" "$(run_cmd 'winget install jq')"
assert_eq "H2 harness reports ALLOW for an ordinary command" \
    "ALLOW" "$(run_cmd 'ls -la')"

PARTS_DIR="$AGENTS_DIR/tests/enforce-system-ops-classifier"
# shellcheck source=./enforce-system-ops-classifier/cases-categories.sh
. "$PARTS_DIR/cases-categories.sh"
# shellcheck source=./enforce-system-ops-classifier/cases-anchoring.sh
. "$PARTS_DIR/cases-anchoring.sh"
# shellcheck source=./enforce-system-ops-classifier/cases-env-approval.sh
. "$PARTS_DIR/cases-env-approval.sh"
# shellcheck source=./enforce-system-ops-classifier/cases-payload.sh
. "$PARTS_DIR/cases-payload.sh"
# shellcheck source=./enforce-system-ops-classifier/cases-mutation.sh
. "$PARTS_DIR/cases-mutation.sh"

run_C_categories    # C - categories A-F, block/nearest-miss pairs
run_C_labels        # L - the category label reported in the banner
run_S_separators    # S - command-position anchor set
run_W_wrapping      # W - interpreter wrapping (getInnerBodies reach)
run_E_inherited     # E - SYSTEM_OPS_APPROVED, inherited env branch
run_E_inline        # E - SYSTEM_OPS_APPROVED, inline spellings
run_P_payload       # P - payload shape / malformed stdin
run_M_mutation      # M - mutation evidence
run_R_registration  # R - settings.json PreToolUse registration

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
