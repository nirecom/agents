#!/usr/bin/env bash
# Tests: hooks/block-capture-echo/remedy.js, hooks/block-capture-echo.js
# Tags: capture-echo-guard, remedy-wording, secret-leakage, security, protection-fix, scope:issue-specific, pwsh-not-required
# Serial: no

# Section F (round 13, C4) — SEPARATED-argument secret leakage on the matched-SSOT
# branch. part2 B-13..B-20 cover only the ATTACHED `--token=value` spelling, where
# remedy.js SECRET_NAME_RE reads the name left of the `=`; a separated pair is two
# argv elements, so the value alone must carry the evidence. SA-0/SA-6 are the
# Pattern-4 controls without which every "secret absent" row would pass vacuously.

set -uo pipefail

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
export AGENTS_DIR
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$AGENTS_DIR/hooks/block-capture-echo.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$want got=$got"; FAIL=$((FAIL + 1))
    fi
}

finish() {
    echo ""
    echo "Section F: PASS=$PASS FAIL=$FAIL"
    exit "$FAIL"
}

if [ ! -f "$HOOK" ]; then
    assert_eq "F-hook-present" "present" "HOOK_MISSING"
    finish
fi

TMPDIR_F="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_F"' EXIT
EV="$TMPDIR_F/event.json"
OUT="$TMPDIR_F/out.json"
ERR="$TMPDIR_F/err.txt"

# Fixture isolation: never let a real session/plan dir leak in.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export CLAUDE_WORKFLOW_DIR="$TMPDIR_F/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_F/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

# A REAL row of the allow SSOT, so the matched (argument-reproducing) branch is
# genuinely reachable; bail loudly rather than silently if the row ever moves.
ENTRY='bin/workflow/record-complexity-and-skip'
if ! grep -Fxq "$ENTRY" "$AGENTS_DIR/install/settings-allow-commands.txt"; then
    assert_eq "F-0-entry-is-on-the-real-ssot-list" "listed" "NOT_LISTED"
    finish
fi

VERDICT=""
run_case() { # <arg-string>
    node "$HERE/mk-event.js" Bash \
        "X=\$(bash \"\$AGENTS_CONFIG_DIR/$ENTRY\" $1); echo \"\$X\"" >"$EV"
    env AGENTS_CONFIG_DIR="$AGENTS_DIR" node "$HOOK" <"$EV" >"$OUT" 2>"$ERR"
    VERDICT="$(node "$HERE/hook-out.js" "$OUT")"
}

seen() { # <needle> -> stdout|stderr|both|neither, so a leak on EITHER channel fails
    local o=no e=no
    grep -qF -- "$1" "$OUT" && o=yes
    grep -qF -- "$1" "$ERR" && e=yes
    if [ "$o" = yes ] && [ "$e" = yes ]; then printf 'both'
    elif [ "$o" = yes ]; then printf 'stdout'
    elif [ "$e" = yes ]; then printf 'stderr'
    else printf 'neither'; fi
}

# --- SA-0: control — the matched branch is reachable AND does render arguments ----
run_case '--target outline'
assert_eq "SA-0a-matched-entry-blocks" "block" "$VERDICT"
assert_eq "SA-0b-matched-entry-renders-args" "stdout" "$(seen -- '--target outline')"

# --- SA-1..SA-3: separated sensitive options whose VALUE is evidently a secret ----
# Recognised by the value alone (provider shape, then the generic opaque arm), so the
# whole invocation degrades to the branch that names no argument.
GH_SECRET='ghp_TESTFIXTUREAAAABBBBCCCCDDDDEEEE1234'
OPAQUE1='Zm9vYmFyMTIzNDU2Nzg5MGFiY2RlZg'
OPAQUE2='QWxwaGE5OTk5QmV0YTg4ODhHYW1tYTc3'

while IFS='|' read -r id flag secret; do
    [ -z "$id" ] && continue
    run_case "$flag $secret"
    assert_eq "$id-still-blocked" "block" "$VERDICT"
    assert_eq "$id-secret-absent-from-both-channels" "neither" "$(seen "$secret")"
    assert_eq "$id-pair-not-rendered-either" "neither" "$(seen "$flag $secret")"
done <<TABLE
SA-1|--token|$GH_SECRET
SA-2|--password|$OPAQUE1
SA-3|--api-key|$OPAQUE2
TABLE

# --- SA-4: same value behind a NON-sensitive flag degrades identically ------------
# Proves routing follows the value's shape, not a flag-name allowlist.
run_case "--target $GH_SECRET"
assert_eq "SA-4a-still-blocked" "block" "$VERDICT"
assert_eq "SA-4b-secret-absent" "neither" "$(seen "$GH_SECRET")"

# --- SA-5/SA-6: KNOWN GAP — a SHORT value behind a separated sensitive flag -------
# `--token hunter2` is two argv elements, so SECRET_NAME_RE never sees `--token`, and
# `hunter2` is too short/plain for OPAQUE_TOKEN_RE: the value is echoed back verbatim.
# SA-6 isolates the cause — the same name and value ATTACHED are caught. Pinned at
# today's behaviour so a later source fix flips a named row instead of landing unseen.
SHORT_SECRET='hunter2'
run_case "--token $SHORT_SECRET"
assert_eq "SA-5a-still-blocked" "block" "$VERDICT"
assert_eq "SA-5b-KNOWN-GAP-short-separated-value-is-reproduced" "stdout" "$(seen "--token $SHORT_SECRET")"

run_case "--token=$SHORT_SECRET"
assert_eq "SA-6a-still-blocked" "block" "$VERDICT"
assert_eq "SA-6b-attached-spelling-is-caught" "neither" "$(seen "--token=$SHORT_SECRET")"

# --- SA-7: the block path writes diagnostics nowhere, so stderr cannot leak -------
run_case "--token $GH_SECRET"
err_bytes="$(wc -c <"$ERR" | tr -d '[:space:]')"
assert_eq "SA-7-stderr-is-empty-on-the-block-path" "0" "$err_bytes"

finish
