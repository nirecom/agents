#!/bin/bash
# tests/bin/fix-1591-forge-write-scan.sh
# Tests: bin/github-issues/reopen-with-update.sh, bin/lib/github-contents-write.sh, bin/lib/github-git-data-write.sh
# Tags: github, issues, contents-api, git-data-api, scan-outbound, security, scope:issue-specific, layer:TL2, reopen, session-id, pwsh-not-required
#
# Issue #1591 — outbound-scan guards on forge-write paths: reopen-with-update.sh,
# github-contents-write.sh, github-git-data-write.sh. Block aborts before gh api push.
# #2925 (reopen-session-*): the reopen banner and log entry carry the raw session id; a value
# outside [A-Za-z0-9_-], or none, is written as `unknown`.
# TL3 gap: real GitHub body/comment rendering of the raw id is not exercised.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
WORK="$(make_tmp)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT
harness_isolate "$WORK"

REOPEN="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/reopen-with-update.sh"
CONTENTS="$SCRIPT_CHECKOUT_ROOT/bin/lib/github-contents-write.sh"
GITDATA="$SCRIPT_CHECKOUT_ROOT/bin/lib/github-git-data-write.sh"
GUARD_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/gh-outbound-guard.sh"
REAL_SCANNER="$SCRIPT_CHECKOUT_ROOT/bin/scan-outbound.sh"

TMP=""
BLOCKED_IP="10.0.0.1"   # RFC 1918 private IP — hard-block under a non-tests label.

setup() {
    TMP="$(mktemp -d)"
    export MOCK_LOG_DIR="$TMP"
    mkdir -p "$TMP/mock-bin" "$TMP/fake_main_root/bin"
    cp "$REAL_SCANNER" "$TMP/fake_main_root/bin/scan-outbound.sh"
    chmod +x "$TMP/fake_main_root/bin/scan-outbound.sh"
    : > "$TMP/fake_main_root/.private-info-allowlist"
    : > "$TMP/fake_main_root/.private-info-blocklist"
    # gh mock — logs every call. Returns a body containing $BLOCKED_IP for
    # `issue view` so reopen's composed body carries the blocked pattern.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
echo "gh $*" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$*" in
  repo\ view*)   echo "nirecom/agents"; exit 0 ;;
  issue\ reopen*) exit 0 ;;
  issue\ view*)  echo "existing body with host ${MOCK_VIEW_IP:-10.0.0.1} inside"; exit 0 ;;
  auth\ status*) echo "scopes: 'repo'"; exit 0 ;;
  api*)          echo "{}"; exit 0 ;;
esac
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_MAIN_ROOT="$TMP/fake_main_root"
}

teardown() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
    unset MOCK_LOG_DIR MOCK_VIEW_IP 2>/dev/null || true
    TMP=""
}

gh_api_called()   { cat "$TMP/gh-calls.log" 2>/dev/null | grep -qE '^gh api '; }
gh_edit_called()  { cat "$TMP/gh-calls.log" 2>/dev/null | grep -q 'issue edit'; }

if [ ! -f "$GUARD_LIB" ]; then
    fail "F-ALL: bin/lib/gh-outbound-guard.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# F-1: reopen-with-update — fetched body contains blocked pattern -> guard blocks
# the composed body before `gh issue edit --body-file`, exit 1.
case_begin "reopen-blocked-body-exits-before-edit" "bin/github-issues/reopen-with-update.sh"
setup
RC=0
run_with_timeout 20 bash "$REOPEN" 4242 >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_edit_called; then
    pass "F-1: reopen blocked body -> exit 1 before gh issue edit"
else
    fail "F-1: expected exit 1 no-edit; got rc=$RC edit=$(gh_edit_called && echo y || echo n)"
fi
teardown
case_end

# F-2: github-contents-write — blocked pattern in FILE content -> abort before gh api.
case_begin "contents-write-blocked-file-content" "bin/lib/github-contents-write.sh"
setup
CF="$TMP/history.md"; printf '# history\ninternal host %s here\n' "$BLOCKED_IP" > "$CF"
RC=0
run_with_timeout 20 bash "$CONTENTS" \
    --owner nirecom --repo agents --path docs/history.md \
    --file "$CF" --message "docs: update" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_api_called; then
    pass "F-2: contents-write blocked FILE content -> exit 1 before gh api"
else
    fail "F-2: expected exit 1 no-api; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown
case_end

# F-3: github-contents-write — blocked pattern ONLY in --message (file clean) ->
# abort before gh api. Proves the commit message is scanned, not just the file.
case_begin "contents-write-blocked-message-only" "bin/lib/github-contents-write.sh"
setup
CF="$TMP/history.md"; printf '# history\nperfectly clean content\n' > "$CF"
RC=0
run_with_timeout 20 bash "$CONTENTS" \
    --owner nirecom --repo agents --path docs/history.md \
    --file "$CF" --message "deploy note host $BLOCKED_IP" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_api_called; then
    pass "F-3: contents-write blocked --message (clean file) -> exit 1 before gh api"
else
    fail "F-3: expected exit 1 no-api; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown
case_end

# F-4: github-git-data-write — blocked pattern in one file's content (multi-file)
# -> abort before gh api blob push, exit 1.
case_begin "git-data-write-blocked-file-content" "bin/lib/github-git-data-write.sh"
setup
F1="$TMP/a.md"; printf 'clean a\n' > "$F1"
F2="$TMP/b.md"; printf 'leak host %s in b\n' "$BLOCKED_IP" > "$F2"
RC=0
run_with_timeout 20 bash "$GITDATA" \
    --owner nirecom --repo agents --branch main --message "docs: rotate" \
    --file "docs/a.md=$F1" --file "docs/b.md=$F2" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_api_called; then
    pass "F-4: git-data-write blocked file content (multi-file) -> exit 1 before gh api"
else
    fail "F-4: expected exit 1 no-api; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown
case_end

# F-5: github-git-data-write — blocked pattern ONLY in --message (all files clean,
# multi-file) -> message-only leak still caught, exit 1 before gh api.
case_begin "git-data-write-blocked-message-only" "bin/lib/github-git-data-write.sh"
setup
F1="$TMP/a.md"; printf 'clean a\n' > "$F1"
F2="$TMP/b.md"; printf 'clean b\n' > "$F2"
RC=0
run_with_timeout 20 bash "$GITDATA" \
    --owner nirecom --repo agents --branch main --message "note host $BLOCKED_IP" \
    --file "docs/a.md=$F1" --file "docs/b.md=$F2" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 1 ] && ! gh_api_called; then
    pass "F-5: git-data-write blocked --message (clean files) -> exit 1 before gh api"
else
    fail "F-5: expected exit 1 no-api; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown
case_end

# F-6: reopen-with-update — fetched body is CLEAN (no blocked pattern) -> guard
# allows the composed body through, real `gh issue edit --body-file` IS reached.
case_begin "reopen-clean-body-reaches-edit" "bin/github-issues/reopen-with-update.sh"
setup
export MOCK_VIEW_IP="a-clean-hostname-token"
RC=0
run_with_timeout 20 bash "$REOPEN" 4242 >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && gh_edit_called; then
    pass "F-6: reopen clean body -> exit 0, gh issue edit reached"
else
    fail "F-6: expected exit 0 edit called; got rc=$RC edit=$(gh_edit_called && echo y || echo n)"
fi
teardown
case_end

# F-7: github-contents-write — CLEAN file content AND clean --message -> guard
# allows through, real `gh api` call IS reached.
case_begin "contents-write-clean-reaches-api" "bin/lib/github-contents-write.sh"
setup
CF="$TMP/history.md"; printf '# history\nperfectly clean content\n' > "$CF"
RC=0
run_with_timeout 20 bash "$CONTENTS" \
    --owner nirecom --repo agents --path docs/history.md \
    --file "$CF" --message "docs: update" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && gh_api_called; then
    pass "F-7: contents-write clean content+message -> exit 0, gh api reached"
else
    fail "F-7: expected exit 0 api called; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown
case_end

# F-8: github-git-data-write — CLEAN content in all files (multi-file) AND clean
# --message -> guard allows through, real `gh api` call IS reached.
case_begin "git-data-write-clean-reaches-api" "bin/lib/github-git-data-write.sh"
setup
F1="$TMP/a.md"; printf 'clean a\n' > "$F1"
F2="$TMP/b.md"; printf 'clean b\n' > "$F2"
RC=0
run_with_timeout 20 bash "$GITDATA" \
    --owner nirecom --repo agents --branch main --message "docs: rotate" \
    --file "docs/a.md=$F1" --file "docs/b.md=$F2" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && gh_api_called; then
    pass "F-8: git-data-write clean files+message (multi-file) -> exit 0, gh api reached"
else
    fail "F-8: expected exit 0 api called; got rc=$RC api=$(gh_api_called && echo y || echo n)"
fi
teardown
case_end

# #2925 fixture: a fake checkout (the real script + guard library beside a pass-through
# scanner) and a gh mock capturing the new body (--body-file) and the log comment (--body).
RS_MOCKDIR="$WORK/rs-bin"; mkdir -p "$RS_MOCKDIR"
FAKE="$WORK/fake-script-checkout-root"
mkdir -p "$FAKE/bin/github-issues" "$FAKE/bin/lib"
cp "$REOPEN" "$FAKE/bin/github-issues/reopen-with-update.sh"
cp "$GUARD_LIB" "$FAKE/bin/lib/gh-outbound-guard.sh"
cp "$SCRIPT_CHECKOUT_ROOT/bin/lib/native-path.sh" "$FAKE/bin/lib/native-path.sh"
# The real session-id bridge plus its load-time require graph (hooks/, and bin/workflow/ which hooks/lib reaches).
cp "$SCRIPT_CHECKOUT_ROOT/bin/resolve-session-id" "$FAKE/bin/resolve-session-id"
cp -R "$SCRIPT_CHECKOUT_ROOT/hooks" "$FAKE/hooks"
cp -R "$SCRIPT_CHECKOUT_ROOT/bin/workflow" "$FAKE/bin/workflow"
RS_TRANSCRIPTS="$WORK/rs-empty-transcripts"; mkdir -p "$RS_TRANSCRIPTS"
printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > "$FAKE/bin/scan-outbound.sh"
chmod +x "$FAKE/bin/scan-outbound.sh"
RWU_COPY="$FAKE/bin/github-issues/reopen-with-update.sh"
cat > "$RS_MOCKDIR/gh" <<'MOCK'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  repo\ view*)    echo "nirecom/agents"; exit 0 ;;
  issue\ reopen*) exit 0 ;;
  issue\ view*)   echo "existing issue body"; exit 0 ;;
  api\ *comments\ *) echo "[]"; exit 0 ;;
  issue\ comment*)
      while [ $# -gt 0 ]; do
          [ "$1" = "--body" ] && printf '%s' "$2" > "$COMMENT_CAPTURE"
          shift
      done
      exit 0 ;;
  issue\ edit*)
      while [ $# -gt 0 ]; do
          [ "$1" = "--body-file" ] && cp "$2" "$BODY_CAPTURE"
          shift
      done
      exit 0 ;;
esac
exit 0
MOCK
chmod +x "$RS_MOCKDIR/gh"

# run_reopen <name> [<sid>] — runs with CLAUDE_CODE_SESSION_ID=<sid>, or unset when omitted.
run_reopen() {
    local d="$WORK/$1"; mkdir -p "$d"
    COMMENT_F="$d/comment.txt"; BODY_F="$d/body.txt"; : > "$COMMENT_F"; : > "$BODY_F"
    if [ "$#" -ge 2 ]; then
        env CLAUDE_TRANSCRIPT_BASE_DIR="$RS_TRANSCRIPTS" COMMENT_CAPTURE="$COMMENT_F" BODY_CAPTURE="$BODY_F" CLAUDE_CODE_SESSION_ID="$2" PATH="$RS_MOCKDIR:$PATH" \
            bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 30 bash "$RWU_COPY" 4242 >"$d/stdout.txt" 2>"$d/stderr.txt"
    else
        env -u CLAUDE_CODE_SESSION_ID CLAUDE_TRANSCRIPT_BASE_DIR="$RS_TRANSCRIPTS" COMMENT_CAPTURE="$COMMENT_F" BODY_CAPTURE="$BODY_F" PATH="$RS_MOCKDIR:$PATH" \
            bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 30 bash "$RWU_COPY" 4242 >"$d/stdout.txt" 2>"$d/stderr.txt"
    fi
    RC=$?
    COMMENT="$(cat "$COMMENT_F" 2>/dev/null)"
    BODY="$(cat "$BODY_F" 2>/dev/null)"
}
# both_have <text> — banner (body) and log entry (comment) both carry `session: <text>` at line end.
both_have() {
    printf '%s\n' "$BODY" | grep -qE -- "session: $1\$" && printf '%s\n' "$COMMENT" | grep -qE -- "session: $1\$"
}

# RS1: a valid session id is written verbatim in both places.
case_begin "reopen-session-raw-sid-written" "bin/github-issues/reopen-with-update.sh"
SID_OK="sess-2925_OK"
run_reopen rs1 "$SID_OK"
DIGEST="$(printf '%s' "$SID_OK" | sha256sum | cut -c1-8)"
if [ "$RC" -eq 0 ] && both_have "$SID_OK" && ! printf '%s%s' "$BODY" "$COMMENT" | grep -qF "$DIGEST"; then
    pass "RS1: banner and reopen-log carry 'session: $SID_OK' (no sha256 digest)"
else
    fail "RS1: rc=$RC body=[$BODY] comment=[$COMMENT] stderr=[$(head -n 2 "$WORK/rs1/stderr.txt")]"
fi
case_end

# RS2: a value with characters outside [A-Za-z0-9_-] falls back to unknown; the raw value never appears.
case_begin "reopen-session-invalid-chars-unknown" "bin/github-issues/reopen-with-update.sh"
SID_BAD='bad sid;x'
run_reopen rs2 "$SID_BAD"
if [ "$RC" -eq 0 ] && both_have "unknown" && ! printf '%s%s' "$BODY" "$COMMENT" | grep -qF "bad sid"; then
    pass "RS2: invalid characters → 'session: unknown', raw value not written"
else
    fail "RS2: rc=$RC body=[$BODY] comment=[$COMMENT]"
fi
case_end

# RS3: no session id at all → unknown (not the digest of the literal 'unknown').
case_begin "reopen-session-unset-unknown" "bin/github-issues/reopen-with-update.sh"
run_reopen rs3
UNK_DIGEST="$(printf '%s' unknown | sha256sum | cut -c1-8)"
if [ "$RC" -eq 0 ] && both_have "unknown" && ! printf '%s%s' "$BODY" "$COMMENT" | grep -qF "$UNK_DIGEST"; then
    pass "RS3: unset session id → 'session: unknown'"
else
    fail "RS3: rc=$RC body=[$BODY] comment=[$COMMENT]"
fi
case_end

# RS4: the sha256sum / shasum branch is gone from the script's code lines.
case_begin "reopen-session-no-hash-code" "bin/github-issues/reopen-with-update.sh"
HASH_LINES="$(grep -nE 'sha256sum|shasum' "$REOPEN" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [ -z "$HASH_LINES" ]; then
    pass "RS4: reopen-with-update.sh no longer hashes the session id"
else
    fail "RS4: hash code still present: $HASH_LINES"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
