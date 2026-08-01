#!/usr/bin/env bash
# tests/feat-1761-reopen-note-guard.sh
# Tests: bin/github-issues/reopen-with-update.sh, bin/github-issues/issue-create-dispatch.sh, bin/lib/gh-outbound-guard.sh
# Tags: issue-create, reopen, outbound-guard, note, security, gh-mock, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The real scan-outbound.sh ruleset matching real private-info patterns (mocked here).
# - Real GitHub comment PATCH/create semantics.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# S13: reopen-with-update.sh gains an optional 2nd argument (note) carrying
# review-stage provenance derived from codex free text. Because externally authored
# text now rides on the comment body, the comment body must pass gh_outbound_guard
# exactly like the issue body already does (CPR-5). Guard failure drops the note and
# continues with the fixed text — it never aborts the reopen.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWU="$AGENTS_DIR/bin/github-issues/reopen-with-update.sh"
DISPATCH="$AGENTS_DIR/bin/github-issues/issue-create-dispatch.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

# --- fake AGENTS_CONFIG_DIR so gh_outbound_guard resolves our mock scanner -------
FAKE_CFG="$WORK/cfg"; mkdir -p "$FAKE_CFG/bin"
cat > "$FAKE_CFG/bin/scan-outbound.sh" <<'SCAN'
#!/usr/bin/env bash
# Mock scanner. Records the label it was called with; blocks when $GUARD_MOCK_RC is
# set (fail tier) AND the label matches $GUARD_MOCK_LABEL (glob, default '*' = every
# call).
#
# The label filter is not a convenience — reopen-with-update.sh runs the guard twice
# with different failure contracts: 'reopen-comment:#N' (the note) is advisory, WARN
# and drop; 'reopen:#N' (the composed issue body) is fatal by the #1591 outbound-scan
# contract that tests/fix-1591-forge-write-scan.sh pins at exactly rc=1. A scanner
# that blocks unconditionally makes the two indistinguishable, so a case meaning to
# exercise the advisory path is aborted by the fatal one and its assertion becomes
# unsatisfiable rather than false.
LABEL="${2:-stdin}"
printf '%s\n' "$LABEL" >> "${GUARD_LABEL_LOG:-/dev/null}"
cat > /dev/null
# shellcheck disable=SC2254
if [ -n "${GUARD_MOCK_RC:-}" ] && [ "${GUARD_MOCK_RC}" != "0" ] \
   && [[ "$LABEL" == ${GUARD_MOCK_LABEL:-*} ]]; then
    echo "mock-scanner: simulated violation"
    exit "$GUARD_MOCK_RC"
fi
exit 0
SCAN
chmod +x "$FAKE_CFG/bin/scan-outbound.sh"

# --- gh mock ---------------------------------------------------------------
cat > "$MOCKDIR/gh" <<'MOCK'
#!/usr/bin/env bash
ARGS="$*"
printf '%s\n' "$ARGS" >> "${GH_ARGS_LOG:-/dev/null}"
case "$ARGS" in
  repo\ view*)   echo "nirecom/agents"; exit 0 ;;
  issue\ reopen*) echo "reopened" ; exit 0 ;;
  issue\ view*body*) echo "existing issue body"; exit 0 ;;
  api\ *comments\ *) echo "[]"; exit 0 ;;
  issue\ comment*)
      # capture the --body argument
      while [ $# -gt 0 ]; do
          if [ "$1" = "--body" ]; then printf '%s' "$2" > "${COMMENT_CAPTURE:-/dev/null}"; fi
          shift
      done
      exit 0 ;;
  api\ -X\ PATCH*)
      while [ $# -gt 0 ]; do
          case "$1" in body=*) printf '%s' "${1#body=}" > "${COMMENT_CAPTURE:-/dev/null}" ;; esac
          shift
      done
      exit 0 ;;
  issue\ edit*)  exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCKDIR/gh"

RWU_ACCEPTS_NOTE=unknown

# run_reopen <case> <issue-number> <note> [GUARD_MOCK_RC] [GUARD_MOCK_LABEL glob]
#   → sets RC / COMMENT / LABELS
# The 5th argument narrows which guard call fails; omit it to fail every call.
run_reopen() {
    local name="$1" num="$2" note="$3" grc="${4:-}" glbl="${5:-*}"
    local d="$WORK/$name"; mkdir -p "$d"
    COMMENT_FILE="$d/comment.txt"; : > "$COMMENT_FILE"
    LABEL_FILE="$d/labels.txt";    : > "$LABEL_FILE"
    GH_ARGS_LOG="$d/gh-args.log";  : > "$GH_ARGS_LOG"
    # Config pinning (rules/test.md): the reopen note is emitted after the review
    # stage has already run, so the switches are declared rather than inherited from
    # the developer's .env — the note contract must not vary with them.
    ISSUE_VERDICT_REVIEW=on \
    ISSUE_PROVENANCE=off \
    GUARD_MOCK_RC="$grc" \
    GUARD_MOCK_LABEL="$glbl" \
    GUARD_LABEL_LOG="$LABEL_FILE" \
    COMMENT_CAPTURE="$COMMENT_FILE" \
    GH_ARGS_LOG="$GH_ARGS_LOG" \
    AGENTS_CONFIG_DIR="$FAKE_CFG" \
    CLAUDE_SESSION_ID="test-session" \
    PATH="$MOCKDIR:$PATH" \
        "$RWT" 30 bash "$RWU" "$num" "$note" >"$d/stdout.txt" 2>"$d/stderr.txt"
    RC=$?
    COMMENT="$(cat "$COMMENT_FILE" 2>/dev/null)"
    LABELS="$(cat "$LABEL_FILE" 2>/dev/null)"
}

NOTE_PLAIN='survey verdict none -> review verdict reopen (replaced) — same root cause'
NOTE_DIRTY="$(printf 'survey verdict none -> review verdict reopen (replaced) — line1\nline2 <!-- injected --> tail')"
NOTE_LONG="survey verdict none -> review verdict reopen (replaced) — $(node -e "process.stdout.write('z'.repeat(300))" 2>/dev/null || printf 'z%.0s' $(seq 1 300))"

echo "=== N1: reopen-with-update.sh accepts an optional note argument ==="
run_reopen n1 4242 "$NOTE_PLAIN"
if [ "$RC" -eq 0 ]; then
    RWU_ACCEPTS_NOTE=yes; pass "N1-note-argument-accepted"
else
    RWU_ACCEPTS_NOTE=no
    fail "N1-note-argument-accepted" "RED-EXPECTED: script rejects a 2nd argument (rc=$RC; $(head -n 1 "$WORK/n1/stderr.txt" 2>/dev/null))"
fi

echo ""
echo "=== N2: the comment body passes gh_outbound_guard (CPR-5 with the issue body) ==="
if [ "$RWU_ACCEPTS_NOTE" != "yes" ]; then
    fail "N2-comment-guard-invoked" "RED-EXPECTED: note argument not yet supported"
    fail "N3-note-present-in-comment" "RED-EXPECTED: note argument not yet supported"
    fail "N4-reopen-log-marker-intact" "RED-EXPECTED: note argument not yet supported"
else
    if printf '%s' "$LABELS" | grep -q 'reopen-comment'; then
        pass "N2-comment-guard-invoked"
    else
        fail "N2-comment-guard-invoked" "no gh_outbound_guard call with a 'reopen-comment:*' label (labels seen: $(printf '%s' "$LABELS" | tr '\n' ' '))"
    fi
    if printf '%s' "$COMMENT" | grep -qF 'review verdict reopen'; then
        pass "N3-note-present-in-comment"
    else
        fail "N3-note-present-in-comment" "the note did not reach the comment body (got: $COMMENT)"
    fi
    if printf '%s' "$COMMENT" | grep -qF '<!-- reopen-log -->'; then
        pass "N4-reopen-log-marker-intact"
    else
        fail "N4-reopen-log-marker-intact" "the reopen-log marker is missing from the comment body"
    fi
fi

echo ""
echo "=== N5: guard failure drops the note but still reopens ==="
# Only the note's own guard call is failed. The reopen must survive it: the note is
# supplementary explanation, and losing the explanation is not a reason to leave a
# duplicate issue closed. Failing the body guard too would be a different scenario
# (the #1591 fatal contract, covered by tests/fix-1591-forge-write-scan.sh).
run_reopen n5 4242 "$NOTE_PLAIN" 1 'reopen-comment:*'
if [ "$RWU_ACCEPTS_NOTE" != "yes" ]; then
    fail "N5-guard-fail-still-reopens" "RED-EXPECTED: note argument not yet supported"
    fail "N6-guard-fail-drops-note"    "RED-EXPECTED: note argument not yet supported"
else
    if [ "$RC" -eq 0 ] && grep -q 'issue reopen' "$WORK/n5/gh-args.log"; then
        pass "N5-guard-fail-still-reopens"
    else
        fail "N5-guard-fail-still-reopens" "a blocked note must not abort the reopen (rc=$RC)"
    fi
    if printf '%s' "$COMMENT" | grep -qF 'review verdict reopen'; then
        fail "N6-guard-fail-drops-note" "unscanned note text was emitted anyway"
    else
        pass "N6-guard-fail-drops-note"
    fi
fi

echo ""
echo "=== N7: note sanitization (newline / HTML comment markers / 120-char cap) ==="
run_reopen n7 4242 "$NOTE_DIRTY"
if [ "$RWU_ACCEPTS_NOTE" != "yes" ]; then
    fail "N7-no-injected-comment-markers" "RED-EXPECTED: note argument not yet supported"
    fail "N8-note-is-single-line"          "RED-EXPECTED: note argument not yet supported"
else
    # The only HTML comment marker allowed in the body is the reopen-log marker itself.
    STRAY=$(printf '%s' "$COMMENT" | grep -oF -- '<!--' | wc -l | tr -d ' ')
    if [ "$STRAY" = "1" ]; then
        pass "N7-no-injected-comment-markers"
    else
        fail "N7-no-injected-comment-markers" "want exactly 1 '<!--' (the reopen-log marker), got $STRAY"
    fi
    # The appended log entry must remain one line: total lines = marker + heading + 1 entry.
    LINES=$(printf '%s\n' "$COMMENT" | grep -c 'line2' || true)
    if [ "$LINES" = "0" ]; then
        pass "N8-note-is-single-line"
    else
        fail "N8-note-is-single-line" "the note's second physical line survived into the comment body"
    fi
fi

run_reopen n9 4242 "$NOTE_LONG"
if [ "$RWU_ACCEPTS_NOTE" != "yes" ]; then
    fail "N9-note-truncated-120" "RED-EXPECTED: note argument not yet supported"
else
    ZCOUNT=$(printf '%s' "$COMMENT" | tr -cd 'z' | wc -c | tr -d ' ')
    if [ "$ZCOUNT" -le 120 ]; then
        pass "N9-note-truncated-120 (z-count=$ZCOUNT)"
    else
        fail "N9-note-truncated-120" "note not capped at 120 chars (z-count=$ZCOUNT)"
    fi
fi

echo ""
echo "=== N13: marker stripping runs to a FIXED POINT, not a single pass ==="
# Same class as validate-review-verdict.js's stripCommentMarkers (CPR-5): both sites
# take reviewer-authored free text and must remove HTML comment markers from it, so the
# same PoC has to fail at both or the weaker site is the one an attacker uses.
# `<<!--!--` holds `<!--` at offset 1; deleting it rejoins `<` + `!--` into a NEW `<!--`.
# `---->>` does the same for `-->`. One pass therefore returns `PoC --> and <!-- end` —
# the very markers it was asked to strip. N7's plain `<!-- injected -->` cannot see this.
NOTE_POC='survey verdict none -> review verdict reopen (replaced) — PoC ---->> and <<!--!-- end'
run_reopen n13 4242 "$NOTE_POC"
if [ "$RWU_ACCEPTS_NOTE" != "yes" ]; then
    fail "N13-open-marker-fixed-point"  "RED-EXPECTED: note argument not yet supported"
    fail "N14-close-marker-fixed-point" "RED-EXPECTED: note argument not yet supported"
else
    OPENS=$(printf '%s' "$COMMENT" | grep -oF -- '<!--' | wc -l | tr -d ' ')
    CLOSES=$(printf '%s' "$COMMENT" | grep -oF -- '-->' | wc -l | tr -d ' ')
    # Exactly the reopen-log marker's own pair may remain.
    if [ "$OPENS" = "1" ]; then
        pass "N13-open-marker-fixed-point"
    else
        fail "N13-open-marker-fixed-point" "a single stripping pass re-spelled '<!--': want exactly 1 (the reopen-log marker), got $OPENS"
    fi
    if [ "$CLOSES" = "1" ]; then
        pass "N14-close-marker-fixed-point"
    else
        fail "N14-close-marker-fixed-point" "a single stripping pass re-spelled '-->': want exactly 1 (the reopen-log marker), got $CLOSES"
    fi
fi

echo ""
echo "=== N10: no-note invocation is unchanged (regression guard) ==="
d="$WORK/n10"; mkdir -p "$d"
ISSUE_VERDICT_REVIEW=off ISSUE_PROVENANCE=off \
GUARD_LABEL_LOG="$d/labels.txt" COMMENT_CAPTURE="$d/comment.txt" GH_ARGS_LOG="$d/gh-args.log" \
AGENTS_CONFIG_DIR="$FAKE_CFG" CLAUDE_SESSION_ID="test-session" PATH="$MOCKDIR:$PATH" \
    "$RWT" 30 bash "$RWU" 4242 >"$d/stdout.txt" 2>"$d/stderr.txt"
if [ $? -eq 0 ] && grep -q 'issue reopen' "$d/gh-args.log"; then
    pass "N10-single-arg-invocation-still-works"
else
    fail "N10-single-arg-invocation-still-works" "the 1-argument form regressed ($(head -n 1 "$d/stderr.txt" 2>/dev/null))"
fi

echo ""
echo "=== N11: issue-create-dispatch.sh exposes --note and routes it to reopen only ==="
if ! grep -qF -- '--note' "$DISPATCH"; then
    fail "N11-dispatch-note-flag" "RED-EXPECTED: issue-create-dispatch.sh has no --note flag yet"
    fail "N12-dispatch-note-reopen-only" "RED-EXPECTED: issue-create-dispatch.sh has no --note flag yet"
else
    pass "N11-dispatch-note-flag"
    if grep -qE 'reopen-with-update\.sh"? +"?\$(TARGET|\{TARGET)' "$DISPATCH" && grep -q 'NOTE' "$DISPATCH"; then
        pass "N12-dispatch-note-reopen-only"
    else
        fail "N12-dispatch-note-reopen-only" "the note must be passed only on the reopen branch"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
