#!/usr/bin/env bash
# Tests: bin/github-issues/pr-known-limits-append.sh
# Tags: TL2, bin, github-issues, known-limits, pr-body, gh, outbound-guard, user-block-guard, fail-closed, scope:issue-specific
# #2019 S3-5: `pr-known-limits-append.sh --branch <b> --file <entry>` adds one line to the
# `## Known limits` section of the branch's single PR (creating the section at the end when absent),
# behind gh_outbound_guard and gh_user_block_guard. 0 or 2+ PRs, a failed edit, or a guard stop exit
# non-zero without a successful edit. gh is tests/lib/gh-scripted-stub.js behind a capture shim
# that records the body sent to `gh pr edit` (the stub keeps body files for `issue` only).
# TL3 gap (what this test does NOT catch):
# - real GitHub PR bodies (CRLF, very long bodies), gh's own --jq evaluation, edits to merged PRs

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
readonly BASE="$(make_tmp)"
trap 'rm -rf "$BASE"' EXIT
harness_isolate "$BASE/iso"
unset CLAUDE_CODE_SESSION_ID GH_REPO
export CLAUDE_TRANSCRIPT_BASE_DIR="$BASE/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR" "$BASE/shim"
harness_git_init "$BASE/cwd"

# The scanner reads its lists from its own checkout's main worktree, or <bin>/.. outside any
# git repo; so the script runs from a non-git sandbox copy whose root holds the fixture lists.
SB="$BASE/sb"
for rel in bin/github-issues/pr-known-limits-append.sh bin/lib bin/scan-outbound.sh bin/scan-outbound.d bin/user-block-guard bin/user-block-guard.d hooks/lib; do
  mkdir -p "$SB/$(dirname "$rel")"
  cp -R "$SCRIPT_CHECKOUT_ROOT/$rel" "$SB/$rel"
done
if git -C "$SB" rev-parse --git-dir >/dev/null 2>&1; then
  echo "FATAL: sandbox $SB is inside a git repo; the scanner would ignore its lists"
  exit 1
fi
: >"$SB/.private-info-allowlist"
: >"$SB/.private-info-blocklist"
SCRIPT="$SB/bin/github-issues/pr-known-limits-append.sh"

STUB_OUT="$(node "$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/gh-scripted-stub.js")" setup "$(np "$BASE/stub")")"
STUB_BIN="${STUB_OUT%%$'\n'*}"
PRELOAD="${STUB_OUT#*$'\n'}"
command -v cygpath >/dev/null 2>&1 && STUB_BIN="$(cygpath -u "$STUB_BIN")"
export F2019_BODY_CAPTURE="$BASE/edited-body.txt"
export F2019_STUB_GH="$STUB_BIN/gh"
# The shim: on `pr edit` it saves the body (--body, --body-file <f>|=<f>|-) and then runs the stub.
cat >"$BASE/shim/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "edit" ]; then
  prev=""
  for a in "$@"; do
    case "$prev" in
      --body) printf '%s' "$a" >"$F2019_BODY_CAPTURE" ;;
      --body-file|-F) if [ "$a" = "-" ]; then cat >"$F2019_BODY_CAPTURE"; else cp "$a" "$F2019_BODY_CAPTURE"; fi ;;
    esac
    case "$a" in --body-file=*) cp "${a#--body-file=}" "$F2019_BODY_CAPTURE" ;; esac
    prev="$a"
  done
fi
exec "$F2019_STUB_GH" "$@"
SHIM
chmod +x "$BASE/shim/gh"
export PATH="$BASE/shim:$STUB_BIN:$PATH"
export NODE_OPTIONS="--require \"$PRELOAD\""
export F2940_GH_SPEC="$(np "$BASE/spec.json")"
export F2940_GH_LOG="$(np "$BASE/gh-calls.jsonl")"
if ! [ "$(command -v gh 2>/dev/null)" -ef "$BASE/shim/gh" ]; then
  echo "FATAL: gh does not resolve to the capture shim; aborting before any real gh call"
  exit 1
fi

js() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}
# spec <pr-count> <body> [edit-exit] — PR list/view/edit replies; clears the log and the capture.
spec() {
  local n="$1" body="$2" edit_exit="${3:-0}" arr="" nums=""
  case "$n" in
    0) arr='[]' ;;
    1) arr='[{"number":77,"state":"OPEN","headRefName":"feature/x"}]'; nums="77" ;;
    2) arr='[{"number":77,"state":"OPEN","headRefName":"feature/x"},{"number":78,"state":"CLOSED","headRefName":"feature/x"}]'; nums=$'77\n78' ;;
  esac
  printf '{"rules":[{"match":"^pr list.*--jq","stdout":%s},{"match":"^pr list","stdout":%s},{"match":"^pr view.*--jq","stdout":%s},{"match":"^pr view","stdout":{"number":77,"body":%s}},{"match":"^pr edit","exit":%s}],"fallback":{"exit":0}}\n' \
    "$(js "$nums")" "$(js "$arr")" "$(js "$body")" "$(js "$body")" "$edit_exit" >"$BASE/spec.json"
  rm -f "$BASE/gh-calls.jsonl" "$F2019_BODY_CAPTURE"
}
edited() { grep -qF '"pr","edit"' "$BASE/gh-calls.jsonl" 2>/dev/null; }
# run_append <entry-text> — sets RC, OUT, ERR.
run_append() {
  printf '%s\n' "$1" >"$BASE/entry.txt"
  RC=0
  (cd "$BASE/cwd" && run_with_timeout 60 bash "$SCRIPT" --branch feature/x --file "$(np "$BASE/entry.txt")") >"$BASE/out.txt" 2>"$BASE/err.txt" || RC=$?
  OUT="$(cat "$BASE/out.txt")"
  ERR="$(cat "$BASE/err.txt")"
}
# section_lines — the bullet lines under `## Known limits` in the captured body.
section_lines() {
  awk '/^## Known limits[[:space:]]*$/{f=1;next} /^## /{f=0} f&&/^- /' "$F2019_BODY_CAPTURE" 2>/dev/null
}

ENTRY="Retry loop ignores EPERM on rename"

case_begin "existing-section-gets-one-line" "bin/github-issues/pr-known-limits-append.sh"
spec 1 $'## Summary\nDoes X.\n\n## Known limits\n- Old limit\n\n## Test plan\n- run'
run_append "$ENTRY"
assert_eq "$RC" "0"
if edited; then pass "pr edit called"; else fail "pr edit called" "$ERR"; fi
LINES="$(section_lines)"
if printf '%s\n' "$LINES" | grep -qF "Old limit"; then pass "old line kept"; else fail "old line kept" "$LINES"; fi
if printf '%s\n' "$LINES" | grep -qF "$ENTRY"; then pass "new line inside the section"; else fail "new line inside the section" "$LINES"; fi
assert_eq "$(grep -c '^## Known limits' "$F2019_BODY_CAPTURE" 2>/dev/null)" "1"
if grep -q '^## Test plan' "$F2019_BODY_CAPTURE" 2>/dev/null && grep -q '^Does X.' "$F2019_BODY_CAPTURE"; then pass "other sections kept"; else fail "other sections kept"; fi
case_end

case_begin "missing-section-created-at-end" "bin/github-issues/pr-known-limits-append.sh"
spec 1 $'## Summary\nDoes Y.'
run_append "$ENTRY"
assert_eq "$RC" "0"
if printf '%s\n' "$(section_lines)" | grep -qF "$ENTRY"; then pass "section created with the line"; else fail "section created with the line" "$(cat "$F2019_BODY_CAPTURE" 2>/dev/null)"; fi
LAST_HEADING="$(grep '^## ' "$F2019_BODY_CAPTURE" 2>/dev/null | tail -n 1)"
assert_eq "$LAST_HEADING" "## Known limits"
case_end

case_begin "rerun-same-entry-keeps-one-line" "bin/github-issues/pr-known-limits-append.sh"
# A pass retried after a crash must not stack the line: the second run sees the body the first one wrote.
spec 1 $'## Summary\nDoes W.\n\n## Known limits\n- Old limit'
run_append "$ENTRY"
assert_eq "$RC" "0"
FIRST_BODY="$(cat "$F2019_BODY_CAPTURE" 2>/dev/null)"
spec 1 "$FIRST_BODY"
run_append "$ENTRY"
assert_eq "$RC" "0"
if edited; then AFTER="$(section_lines)"; else AFTER="$(printf '%s\n' "$FIRST_BODY" | awk '/^## Known limits[[:space:]]*$/{f=1;next} /^## /{f=0} f&&/^- /')"; fi
assert_eq "$(printf '%s\n' "$AFTER" | grep -cF "$ENTRY")" "1"
if printf '%s\n' "$AFTER" | grep -qF "Old limit"; then pass "rerun keeps the other line"; else fail "rerun keeps the other line" "$AFTER"; fi
case_end

case_begin "pr-count-not-one-fails" "bin/github-issues/pr-known-limits-append.sh"
for n in 0 2; do
  spec "$n" $'## Summary\nZ'
  run_append "$ENTRY"
  if [ "$RC" -ne 0 ]; then pass "$n PRs: non-zero exit"; else fail "$n PRs: non-zero exit"; fi
  if edited; then fail "$n PRs: no edit"; else pass "$n PRs: no edit"; fi
done
case_end

case_begin "edit-failure-fails" "bin/github-issues/pr-known-limits-append.sh"
spec 1 $'## Summary\nZ' 1
run_append "$ENTRY"
if [ "$RC" -ne 0 ]; then pass "failed edit: non-zero exit"; else fail "failed edit: non-zero exit" "$OUT"; fi
case_end

case_begin "outbound-guard-stops-edit" "bin/github-issues/pr-known-limits-append.sh"
printf 'warn:WIDGET-INTERNAL-CODENAME\n' >"$SB/.private-info-blocklist"
spec 1 $'## Summary\nZ'
run_append "Leak of WIDGET-INTERNAL-CODENAME in logs"
if [ "$RC" -ne 0 ]; then pass "blocked word: non-zero exit"; else fail "blocked word: non-zero exit"; fi
if edited; then fail "blocked word: no edit"; else pass "blocked word: no edit"; fi
: >"$SB/.private-info-blocklist"
case_end

case_begin "user-block-guard-stops-edit" "bin/github-issues/pr-known-limits-append.sh"
spec 1 $'## Summary\nZ'
run_append "Entry with <user>x</user> block"
if [ "$RC" -ne 0 ]; then pass "user block: non-zero exit"; else fail "user block: non-zero exit"; fi
if edited; then fail "user block: no edit"; else pass "user block: no edit"; fi
case_end

case_begin "bad-arguments-fail" "bin/github-issues/pr-known-limits-append.sh"
spec 1 $'## Summary\nZ'
RC=0
(cd "$BASE/cwd" && run_with_timeout 60 bash "$SCRIPT" --branch feature/x) >/dev/null 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then pass "missing --file: non-zero exit"; else fail "missing --file: non-zero exit"; fi
RC=0
(cd "$BASE/cwd" && run_with_timeout 60 bash "$SCRIPT" --file "$(np "$BASE/entry.txt")") >/dev/null 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then pass "missing --branch: non-zero exit"; else fail "missing --branch: non-zero exit"; fi
if edited; then fail "bad arguments: no edit"; else pass "bad arguments: no edit"; fi
case_end

echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
