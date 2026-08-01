#!/usr/bin/env bash
# tests/feat-1763-provenance-mint-input-validation.sh
# Tests: hooks/issue-provenance-mint.js, hooks/lib/issue-provenance-keys.js, hooks/lib/session-markers.js
# Tags: issue-create, provenance, mint, input-validation, path-traversal, security, table-driven, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code itself can ever emit a hostile session_id or transcript_path.
#   That is the threat model's premise, not something this test can settle.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# The mint hook is the only WRITE into the provenance marker set, and its filename is
# derived from a field of the hook payload. Everything downstream (single-use record,
# consumption boundary, fail-closed classification) assumes those files live inside the
# workflow directory. If the session_id can steer the path, the guarantee is not
# "provenance can be forged" but "an arbitrary file can be created or clobbered".
#
# The invariant asserted throughout is deliberately blunt and implementation-agnostic:
# after the hook runs, NOTHING outside the workflow directory changed. Whether the hook
# rejects, sanitises, or silently no-ops is its choice; escaping the directory is not.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
MINT="$AGENTS_DIR/hooks/issue-provenance-mint.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
red()  { fail "$1" "RED-EXPECTED: hooks/issue-provenance-mint.js not yet created"; }

MINT_PRESENT=no; [ -f "$MINT" ] && MINT_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The canary tree sits OUTSIDE every workflow directory the hook is given. `planted`
# is the traversal landing zone the hostile session-ids aim at.
OUTSIDE="$WORK/outside"
mkdir -p "$OUTSIDE/planted"
printf 'original-canary-content\n' > "$OUTSIDE/planted/x.json"
printf 'sibling-canary\n' > "$OUTSIDE/keep.txt"

snapshot() {  # → sorted "path:size" lines for the whole outside tree
    find "$OUTSIDE" -type f -print 2>/dev/null | sort | while IFS= read -r f; do
        printf '%s:%s\n' "$f" "$(wc -c < "$f" | tr -d ' ')"
    done
}
BASELINE="$(snapshot)"

# fire <case> <session-id> <transcript-path-mode> → MINT_RC
# transcript-path-mode: real | absent | traversal | device | huge
fire() {
    local case="$1" sid="$2" tmode="${3:-real}"
    local base="$WORK/$case"
    mkdir -p "$base/state" "$base/plans" "$base/cwd"
    printf 'Session-ID: 20260731-120000\n' > "$base/cwd/WORKTREE_NOTES.md"
    : > "$base/plans/20260731-120000-intent.md"
    printf '{"type":"user","message":{"role":"user","content":"/issue-create"}}\n' > "$base/transcript.jsonl"

    local tpath
    case "$tmode" in
        real)      tpath="$(node_path "$base/transcript.jsonl")" ;;
        absent)    tpath="" ;;
        traversal) tpath="$(node_path "$base/state")/../../outside/planted/x.json" ;;
        device)    tpath="/dev/zero" ;;
        huge)      tpath="$(node_path "$base/transcript.jsonl")$(printf 'A%.0s' $(seq 1 4096))" ;;
    esac

    [ "$MINT_PRESENT" = "yes" ] || { MINT_RC=127; return; }
    SID="$sid" T="$tpath" C="$(node_path "$base/cwd")" node -e "
const p = { prompt: '/issue-create', cwd: process.env.C, hook_event_name: 'UserPromptSubmit' };
if (process.env.SID !== '__OMIT__') p.session_id = process.env.SID;
if (process.env.T !== '__OMIT__' && process.env.T !== '') p.transcript_path = process.env.T;
process.stdout.write(JSON.stringify(p));" \
    | ( cd "$base/cwd" && \
        CLAUDE_WORKFLOW_DIR="$(node_path "$base/state")" \
        WORKFLOW_PLANS_DIR="$(node_path "$base/plans")" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=off \
        CLAUDE_CODE_SESSION_ID="" CLAUDE_SESSION_ID="" \
        "$RWT" 20 node "$MINT" >"$base/stdout.txt" 2>"$base/stderr.txt" )
    MINT_RC=$?
}

# assert_contained <case>: nothing outside changed, the hook answered, and any marker
# it did write stayed inside the workflow directory it was given.
assert_contained() {
    local case="$1" base="$WORK/$1" now stray
    now="$(snapshot)"
    if [ "$now" = "$BASELINE" ]; then pass "$case-outside-tree-unchanged"
    else fail "$case-outside-tree-unchanged" "files outside the workflow dir were created or modified:
$(diff <(printf '%s\n' "$BASELINE") <(printf '%s\n' "$now") | head -n 6)"; fi

    # A hook that crashes is not "safe": Claude Code surfaces the stack trace and the
    # user learns nothing. Exit 0 with no marker is the correct fail-closed shape.
    if [ "${MINT_RC:-1}" -eq 0 ]; then pass "$case-hook-exits-0"
    else fail "$case-hook-exits-0" "hook exited ${MINT_RC} (stderr: $(head -n 1 "$base/stderr.txt" 2>/dev/null))"; fi

    # Any marker must be a direct child of the state dir — no nested dirs conjured
    # from a session-id containing a separator.
    stray=$(find "$base/state" -mindepth 2 2>/dev/null | tr '\n' ' ')
    if [ -z "$stray" ]; then pass "$case-no-nested-marker-paths"
    else fail "$case-no-nested-marker-paths" "marker path escaped into a subdirectory: $stray"; fi
}

if [ "$MINT_PRESENT" != "yes" ]; then
    while IFS='|' read -r name _sid _tm; do
        [[ -z "${name// /}" ]] && continue
        name="${name//[[:space:]]/}"
        for t in outside-tree-unchanged hook-exits-0 no-nested-marker-paths; do red "$name-$t"; done
    done <<'NAMES'
M1-dotdot-posix
M2-dotdot-windows
M3-absolute-posix
M4-absolute-windows
M5-forward-slash
M6-back-slash
M7-nul-byte-literal
M8-newline-in-sid
M9-sid-omitted
M10-sid-empty
M11-sid-not-a-string
M12-sid-glob-chars
M13-transcript-absent
M14-transcript-traversal
M15-transcript-device
M16-transcript-huge-path
NAMES
    red "M17-valid-sid-still-mints"
else
    echo "=== M1-M12: hostile session_id must not steer the marker path ==="
    while IFS='|' read -r name sid tm; do
        [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; tm="${tm//[[:space:]]/}"
        fire "$name" "$sid" "$tm"
        assert_contained "$name"
    done <<'TABLE'
M1-dotdot-posix        | ../../outside/planted/x            | real
M2-dotdot-windows      | ..\..\outside\planted\x            | real
M3-absolute-posix      | /tmp/planted-absolute              | real
M4-absolute-windows    | C:\Windows\Temp\planted-absolute   | real
M5-forward-slash       | abc/def                            | real
M6-back-slash          | abc\def                            | real
M7-nul-byte-literal    | abc%00def                          | real
M8-newline-in-sid      | abc
def                                                         | real
M9-sid-omitted         | __OMIT__                           | real
M10-sid-empty          |                                    | real
M11-sid-not-a-string   | 12345                              | real
M12-sid-glob-chars     | *                                  | real
TABLE

    echo ""
    echo "=== M13-M16: hostile transcript_path must not become a write target ==="
    # The transcript is a READ input, but a hook that resolves it relative to the
    # state dir, or that copies it next to the marker, turns it into a write.
    while IFS='|' read -r name sid tm; do
        [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; tm="${tm//[[:space:]]/}"; sid="${sid//[[:space:]]/}"
        fire "$name" "$sid" "$tm"
        assert_contained "$name"
    done <<'TABLE'
M13-transcript-absent    | 11111111-2222-3333-4444-555555555555 | absent
M14-transcript-traversal | 11111111-2222-3333-4444-555555555555 | traversal
M15-transcript-device    | 11111111-2222-3333-4444-555555555555 | device
M16-transcript-huge-path | 11111111-2222-3333-4444-555555555555 | huge
TABLE

    echo ""
    echo "=== M17: positive control — a well-formed payload still mints ==="
    # Without this, an implementation that refuses every payload would pass M1-M16.
    fire "M17-valid" "11111111-2222-3333-4444-555555555555" real
    MK=$(find "$WORK/M17-valid/state" -maxdepth 1 -name '11111111-*' 2>/dev/null | head -n 1)
    if [ -n "$MK" ]; then pass "M17-valid-sid-still-mints"
    else fail "M17-valid-sid-still-mints" "RED-EXPECTED: no marker written for a well-formed payload (the containment assertions above would be vacuous)"; fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
