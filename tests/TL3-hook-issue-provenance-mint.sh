#!/usr/bin/env bash
# Tests: hooks/issue-provenance-mint.js, hooks/lib/issue-request-patterns.js, hooks/lib/issue-provenance-keys.js
# Tags: issue-create, provenance, user-prompt-submit, hook, TL3, run-e2e, scope:common
#
# #1763 S10a — per-hook seam TL3 test for issue-provenance-mint.js (UserPromptSubmit).
# Only a live `claude -p` session proves the three things the TL2 suite cannot:
#   1. the hook is actually wired to UserPromptSubmit and fires on a real turn,
#   2. Claude Code's real `session_id` payload field is what the marker is keyed on,
#   3. the real `transcript_path` payload field points at a readable JSONL file.
# TL2 counterparts (fixture payloads, no live session):
#   tests/feat-1763-provenance-token.sh, tests/feat-1763-settings-registration.sh
#
# Layer: TL3 (live claude -p session, real UserPromptSubmit firing, real marker files).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- skip gates (claude-e2e.md acceptance criteria) --------------------------
if [ ! -x "$AGENTS_DIR/bin/get-config-var" ]; then
    echo "SKIP: bin/get-config-var not found or not executable" >&2; exit 77
fi
if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then
    echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "SKIP: claude CLI not found" >&2; exit 77
fi
HOOK="$AGENTS_DIR/hooks/issue-provenance-mint.js"
if [ ! -f "$HOOK" ]; then
    echo "FAIL: RED-EXPECTED — hooks/issue-provenance-mint.js not yet created" >&2; exit 1
fi

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

REPO="$BASE/repo"; WFDIR="$BASE/workflow"; PLANS="$BASE/plans"; MOCKBIN="$BASE/bin"
mkdir -p "$REPO/.claude" "$WFDIR" "$PLANS" "$MOCKBIN"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# SAFETY: shadow `gh` so that even if the model proceeds to run /issue-create,
# no GitHub write can happen. The assertions below are on the marker file the
# hook writes at prompt-submit time, so the turn's outcome is irrelevant.
cat > "$MOCKBIN/gh" <<'GHMOCK'
#!/usr/bin/env bash
echo "gh is disabled in this TL3 fixture" >&2
exit 1
GHMOCK
chmod +x "$MOCKBIN/gh"

HOOK_JS="$(node_path "$HOOK")"
cat > "$REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"$HOOK_JS\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

unset CLAUDECODE

# run_turn <session-id> <prompt> — fires one real UserPromptSubmit
run_turn() {
    ( cd "$REPO" && \
      PATH="$MOCKBIN:$PATH" \
      CLAUDE_WORKFLOW_DIR="$WFDIR" \
      WORKFLOW_PLANS_DIR="$PLANS" \
      AGENTS_CONFIG_DIR="$(node_path "$AGENTS_DIR")" \
      ISSUE_PROVENANCE=on \
      ISSUE_VERDICT_REVIEW=off \
      run_with_timeout 180 claude -p "$2" \
        --session-id "$1" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format json \
      >"$BASE/$1.out" 2>&1 )
    return 0
}

# marker_field <sid> <json-path-expr> → value or "<absent>"
marker_field() {
    local f="$WFDIR/$1.issue-provenance"
    [ -f "$f" ] || { printf '<absent>'; return; }
    node -e "
try {
  const d = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const v = d[process.argv[2]];
  process.stdout.write(v === undefined ? '<undefined>' : String(v));
} catch (e) { process.stdout.write('<unreadable>'); }" "$(node_path "$f")" "$2" 2>/dev/null
}

echo "=== TL3-A: slash form (/issue-create) mints a user-explicit token ==="
SID_A="e1763000-0000-0000-0000-00000000000a"
run_turn "$SID_A" "/issue-create the provenance hook seam test"
if [ -f "$WFDIR/$SID_A.issue-provenance" ]; then
    pass "A1. UserPromptSubmit fired and wrote <sid>.issue-provenance"
else
    fail "A1. no marker at $WFDIR/$SID_A.issue-provenance (present: $(ls "$WFDIR" 2>/dev/null | tr '\n' ' ')); output: $(head -c 400 "$BASE/$SID_A.out" 2>/dev/null)"
fi
V=$(marker_field "$SID_A" provenance)
[ "$V" = "user-explicit" ] && pass "A2. provenance=user-explicit" || fail "A2. provenance want user-explicit, got $V"
V=$(marker_field "$SID_A" target)
[ "$V" = "issue-create" ] && pass "A3. target=issue-create" || fail "A3. target want issue-create, got $V"
V=$(marker_field "$SID_A" match_layer)
[ "$V" = "slash" ] && pass "A4. match_layer=slash (layer A)" || fail "A4. match_layer want slash, got $V"

echo ""
echo "=== TL3-B: natural-language form mints with match_layer=natural ==="
SID_B="e1763000-0000-0000-0000-00000000000b"
run_turn "$SID_B" "Please just reply OK. Also, open an issue for the flaky provenance test later."
if [ -f "$WFDIR/$SID_B.issue-provenance" ]; then
    pass "B1. natural-language request minted a token"
else
    fail "B1. no marker for the natural-language turn; output: $(head -c 400 "$BASE/$SID_B.out" 2>/dev/null)"
fi
V=$(marker_field "$SID_B" match_layer)
[ "$V" = "natural" ] && pass "B2. match_layer=natural (layer B)" || fail "B2. match_layer want natural, got $V"

echo ""
echo "=== TL3-C: the real transcript_path payload field is captured and readable ==="
PTR="$WFDIR/$SID_B.session-transcript"
if [ -f "$PTR" ]; then
    pass "C1. <sid>.session-transcript pointer written from the live payload"
    TPATH="$(tr -d '\r\n' < "$PTR")"
    if [ -n "$TPATH" ] && [ -f "$TPATH" ]; then
        pass "C2. the pointer resolves to an existing transcript file"
        if head -n 1 "$TPATH" | grep -q '{'; then
            pass "C3. the transcript is JSONL as the re-scan path assumes"
        else
            fail "C3. transcript first line is not JSON: $(head -c 120 "$TPATH")"
        fi
    else
        fail "C2. pointer does not resolve to a file: '$TPATH'"
        fail "C3. skipped — pointer unusable"
    fi
else
    fail "C1. no <sid>.session-transcript pointer (present: $(ls "$WFDIR" 2>/dev/null | tr '\n' ' '))"
    fail "C2. skipped — no pointer"
    fail "C3. skipped — no pointer"
fi

echo ""
echo "=== TL3-D: a non-request turn does not mint (and revokes) ==="
SID_D="e1763000-0000-0000-0000-00000000000d"
run_turn "$SID_D" "Reply with the single word OK and nothing else."
if [ -f "$WFDIR/$SID_D.issue-provenance" ]; then
    fail "D1. an unrelated turn minted a provenance token (over-matching): $(cat "$WFDIR/$SID_D.issue-provenance")"
else
    pass "D1. an unrelated turn mints no token"
fi

echo ""
echo "=== TL3-E: markers are keyed on the real Claude Code session_id ==="
STRAY=$(ls "$WFDIR" 2>/dev/null | grep -E '\.issue-provenance$' | grep -vE "^($SID_A|$SID_B)\." | tr '\n' ' ')
if [ -z "$STRAY" ]; then
    pass "E1. every provenance marker is keyed on a --session-id we passed"
else
    fail "E1. marker(s) keyed on an unexpected session id: $STRAY"
fi

# TL3 gap: this seam does not exercise consumption (bin/github-issues/issue-provenance
# --consume), the FIFO consumption record, or the confirm gate — those are asserted at
# TL2 in tests/feat-1763-provenance-single-use.sh and
# tests/feat-1763-confirm-gate-matrix.sh, which can drive states a live session cannot
# reach deterministically.

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
