#!/usr/bin/env bash
# Tests: bin/github-issues/merge-finding-comment.sh, bin/github-issues/issue-create-dispatch.sh
# Tags: TL2, bin, github-issues, issue-create, reopen, merge-comment, gh, outbound-guard, user-block-guard, fail-closed, scope:issue-specific
# #2019 S5: `merge-finding-comment.sh TARGET FILE` adds one comment (never a body rewrite) behind the
# outbound and user-block guards; the dispatch reopen branch calls it only after a successful reopen
# and only with --merged-finding-file. A failed comment keeps the reopen, leaves stdout empty (no URL
# for the caller to annotate from), puts `merge_comment: failed` and `reopened: <url>` on stderr and
# exits 3. The dispatch cases run a copy of the dispatcher beside fake sibling scripts.
# TL3 gap (what this test does NOT catch):
# - real GitHub comment rendering and gh's own argv handling of the body file

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
GI="$SCRIPT_CHECKOUT_ROOT/bin/github-issues"

readonly BASE="$(make_tmp)"
trap 'rm -rf "$BASE"' EXIT
harness_isolate "$BASE/iso"
unset CLAUDE_CODE_SESSION_ID GH_REPO
export CLAUDE_TRANSCRIPT_BASE_DIR="$BASE/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR" "$BASE/gi/lib"
harness_git_init "$BASE/cwd"

# The scanner reads its lists from its own checkout's main worktree, or <bin>/.. outside any
# git repo; so the script runs from a non-git sandbox copy whose root holds the fixture lists.
SB="$BASE/sb"
for rel in bin/github-issues/merge-finding-comment.sh bin/lib bin/scan-outbound.sh bin/scan-outbound.d bin/user-block-guard bin/user-block-guard.d hooks/lib; do
  mkdir -p "$SB/$(dirname "$rel")"
  cp -R "$SCRIPT_CHECKOUT_ROOT/$rel" "$SB/$rel"
done
if git -C "$SB" rev-parse --git-dir >/dev/null 2>&1; then
  echo "FATAL: sandbox $SB is inside a git repo; the scanner would ignore its lists"
  exit 1
fi
: >"$SB/.private-info-allowlist"
: >"$SB/.private-info-blocklist"
MERGE="$SB/bin/github-issues/merge-finding-comment.sh"

STUB_OUT="$(node "$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/gh-scripted-stub.js")" setup "$(np "$BASE/stub")")"
STUB_BIN="${STUB_OUT%%$'\n'*}"
PRELOAD="${STUB_OUT#*$'\n'}"
command -v cygpath >/dev/null 2>&1 && STUB_BIN="$(cygpath -u "$STUB_BIN")"
export PATH="$STUB_BIN:$PATH"
export NODE_OPTIONS="--require \"$PRELOAD\""
export F2940_GH_SPEC="$(np "$BASE/spec.json")"
export F2940_GH_LOG="$(np "$BASE/gh-calls.jsonl")"
if ! [ "$(command -v gh 2>/dev/null)" -ef "$STUB_BIN/gh" ]; then
  echo "FATAL: gh does not resolve to the stub; aborting before any real gh call"
  exit 1
fi

# spec [comment-exit] — repo slug, an issue with a plain body, and the comment reply.
spec() {
  printf '{"rules":[{"match":"^repo view","stdout":"example-owner/example-repo"},{"match":"^issue view.*--jq","stdout":"Old body"},{"match":"^issue view","stdout":{"number":41,"title":"Old","body":"Old body","state":"CLOSED","comments":[]}},{"match":"^issue comment","exit":%s,"stdout":"https://github.com/example-owner/example-repo/issues/41#issuecomment-1"}],"fallback":{"exit":0}}\n' "${1:-0}" >"$BASE/spec.json"
  rm -f "$BASE/gh-calls.jsonl"
}
called() { grep -qF "$1" "$BASE/gh-calls.jsonl" 2>/dev/null; }
# run <cmd...> — sets RC, OUT, ERR.
run() {
  RC=0
  (cd "$BASE/cwd" && run_with_timeout 60 "$@") >"$BASE/out.txt" 2>"$BASE/err.txt" || RC=$?
  OUT="$(cat "$BASE/out.txt")"
  ERR="$(cat "$BASE/err.txt")"
}
finding() { printf '%s\n' "$1" >"$BASE/finding.md"; np "$BASE/finding.md"; }

case_begin "comment-added-not-body" "bin/github-issues/merge-finding-comment.sh"
spec
F="$(finding $'Source: worktree notes of #2019\nloc: bin/x.js:4\ninstance: rename fails with EPERM\n\nRetry loop ignores EPERM.')"
run bash "$MERGE" 41 "$F"
assert_eq "$RC" "0"
if called '"issue","comment"'; then pass "issue comment called"; else fail "issue comment called" "$ERR"; fi
if called '"41"'; then pass "comment targets #41"; else fail "comment targets #41"; fi
if grep -F '"comment"' "$BASE/gh-calls.jsonl" | grep -qF 'rename fails with EPERM'; then pass "the finding text is the comment"; else fail "the finding text is the comment" "$(cat "$BASE/gh-calls.jsonl")"; fi
if called '"issue","edit"'; then fail "the issue body is not rewritten"; else pass "the issue body is not rewritten"; fi
case_end

case_begin "guards-stop-the-comment" "bin/github-issues/merge-finding-comment.sh"
printf 'warn:WIDGET-INTERNAL-CODENAME\n' >"$SB/.private-info-blocklist"
spec
run bash "$MERGE" 41 "$(finding 'Leak of WIDGET-INTERNAL-CODENAME')"
if [ "$RC" -ne 0 ]; then pass "outbound: non-zero exit"; else fail "outbound: non-zero exit"; fi
if called '"issue","comment"'; then fail "outbound: no comment"; else pass "outbound: no comment"; fi
: >"$SB/.private-info-blocklist"
spec
run bash "$MERGE" 41 "$(finding 'Has <user>x</user> inside')"
if [ "$RC" -ne 0 ]; then pass "user block: non-zero exit"; else fail "user block: non-zero exit"; fi
if called '"issue","comment"'; then fail "user block: no comment"; else pass "user block: no comment"; fi
case_end

case_begin "bad-arguments-and-gh-failure" "bin/github-issues/merge-finding-comment.sh"
spec
run bash "$MERGE" 41
if [ "$RC" -ne 0 ]; then pass "missing FILE: non-zero"; else fail "missing FILE: non-zero"; fi
run bash "$MERGE" notanumber "$(finding 'x')"
if [ "$RC" -ne 0 ]; then pass "non-numeric TARGET: non-zero"; else fail "non-numeric TARGET: non-zero"; fi
run bash "$MERGE" 41 "$(np "$BASE/no-such.md")"
if [ "$RC" -ne 0 ]; then pass "missing file: non-zero"; else fail "missing file: non-zero"; fi
if called '"issue","comment"'; then fail "bad arguments: no comment"; else pass "bad arguments: no comment"; fi
spec 1
run bash "$MERGE" 41 "$(finding 'plain finding')"
if [ "$RC" -ne 0 ]; then pass "gh comment failure: non-zero"; else fail "gh comment failure: non-zero"; fi
case_end

# ---- dispatch wiring: a copy of the dispatcher beside fake siblings ----
cp "$GI/issue-create-dispatch.sh" "$BASE/gi/issue-create-dispatch.sh"
printf '#!/usr/bin/env bash\necho "reopen $*" >>"%s"\nexit "${F2019_REOPEN_RC:-0}"\n' "$BASE/calls.log" >"$BASE/gi/reopen-with-update.sh"
printf '#!/usr/bin/env bash\necho "merge $*" >>"%s"\nexit "${F2019_MERGE_RC:-0}"\n' "$BASE/calls.log" >"$BASE/gi/merge-finding-comment.sh"
DISPATCH="$BASE/gi/issue-create-dispatch.sh"
dispatch() { rm -f "$BASE/calls.log"; spec; run env F2019_REOPEN_RC="${REOPEN_RC:-0}" F2019_MERGE_RC="${MERGE_RC:-0}" bash "$DISPATCH" "$@"; }
logged() { grep -qE "$1" "$BASE/calls.log" 2>/dev/null; }

case_begin "dispatch-reopen-calls-merge" "bin/github-issues/issue-create-dispatch.sh"
FF="$(finding 'merged finding')"
REOPEN_RC=0 MERGE_RC=0 dispatch --verdict reopen --target 41 --note "same fix" --merged-finding-file "$FF" --
assert_eq "$RC" "0"
if logged '^reopen 41'; then pass "reopen ran"; else fail "reopen ran"; fi
if logged "^merge 41 .*finding\.md"; then pass "merge comment called with TARGET FILE"; else fail "merge comment called with TARGET FILE" "$(cat "$BASE/calls.log" 2>/dev/null)"; fi
assert_eq "$OUT" "https://github.com/example-owner/example-repo/issues/41"
if printf '%s\n%s\n' "$OUT" "$ERR" | grep -q 'merge_comment:'; then fail "no merge_comment line on success"; else pass "no merge_comment line on success"; fi
case_end

case_begin "dispatch-no-file-no-merge" "bin/github-issues/issue-create-dispatch.sh"
REOPEN_RC=0 dispatch --verdict reopen --target 41 --
assert_eq "$RC" "0"
if logged '^merge'; then fail "no --merged-finding-file: merge not called"; else pass "no --merged-finding-file: merge not called"; fi
REOPEN_RC=1 dispatch --verdict reopen --target 41 --merged-finding-file "$FF" --
if [ "$RC" -ne 0 ]; then pass "failed reopen: non-zero"; else fail "failed reopen: non-zero"; fi
if logged '^merge'; then fail "failed reopen: merge not called"; else pass "failed reopen: merge not called"; fi
case_end

case_begin "dispatch-merge-failure-keeps-reopen" "bin/github-issues/issue-create-dispatch.sh"
REOPEN_RC=0 MERGE_RC=1 dispatch --verdict reopen --target 41 --merged-finding-file "$FF" --
assert_eq "$RC" "3"
assert_eq "$OUT" ""
if printf '%s\n' "$ERR" | grep -q '^merge_comment: failed$'; then pass "merge_comment: failed on stderr"; else fail "merge_comment: failed on stderr" "$ERR"; fi
if printf '%s\n' "$ERR" | grep -qxF "reopened: https://github.com/example-owner/example-repo/issues/41"; then pass "reopened URL named on stderr"; else fail "reopened URL named on stderr" "$ERR"; fi
if logged '^reopen 41'; then pass "the reopen is kept (no undo call)"; else fail "the reopen is kept (no undo call)"; fi
case_end

echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
