#!/usr/bin/env bash
# tests/bin/feature-2631-clarify-owner-paths.sh
# Tests: bin/github-issues/clarify-guard-loop.sh, bin/github-issues/clarify-commit-scope.sh
# Tags: scope:issue-specific, plan-artifact, resume-session, clarify-intent, workflow-state, TL2
# #2631: both clarify scripts resolve the intent through bin/plan-artifact-path, so a resumed
# (downstream) session D reads its upstream U's intent, even over its own. gh is a PATH
# stub (issue view answers GH_STUB_STATE, issue create prints a URL), so no network is used.
# TL3 gap: a real gh against GitHub and a real resumed session are not exercised here.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

readonly TMP_ROOT="$(np "$(make_tmp)")"
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$TMP_ROOT/cwd" "$TMP_ROOT/ghbin" "$TMP_ROOT/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP_ROOT/transcripts"
cd "$TMP_ROOT/cwd"

ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
PLANS="$WORKFLOW_PLANS_DIR"

export GH_STUB_LOG="$TMP_ROOT/gh.log"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >>"$GH_STUB_LOG"' \
  'if [[ "${1:-} ${2:-}" == "issue create" ]]; then echo "https://github.com/example/repo/issues/77"; exit 0; fi' \
  'printf "%s\n" "${GH_STUB_STATE:-OPEN}"' >"$TMP_ROOT/ghbin/gh"
chmod +x "$TMP_ROOT/ghbin/gh"
GH_BIN_DIR="$TMP_ROOT/ghbin"
command -v cygpath >/dev/null 2>&1 && GH_BIN_DIR="$(cygpath -u "$GH_BIN_DIR")"
export PATH="$GH_BIN_DIR:$PATH"

new_sid() { node -e 'process.stdout.write(require("crypto").randomUUID())'; }
# write_state <sid> [<upstream-sid>] — a raw v5 state file.
write_state() {
  local up=""
  [ -n "${2:-}" ] && up=",\"upstream_session_id\":\"$2\",\"upstream_copy_seq\":0"
  printf '{"version":5,"session_id":"%s","created_at":"2026-01-01T00:00:00.000Z","session_start_context":{"cwd":"%s","git_branch":"feature/f2631"},"events":[]%s}\n' \
    "$1" "$TMP_ROOT/cwd" "$up" >"$WORKFLOW_STATE_DIR/$1.json"
}
# write_intent <sid> <title> [<issue>] — an intent naming <title>; no <issue> -> empty Issues.
write_intent() {
  local issues="none"
  [ -n "${3:-}" ] && issues="- #$3 fixture issue"
  printf '# %s\n\n## Goal\n\ng\n\n## Background\n\nb\n\n## Issues\n\n%s\n' "$2" "$issues" >"$PLANS/$1-intent.md"
}
# run_cap <cmd...> — OUT = stdout, RC = exit code.
run_cap() {
  RC=0
  OUT="$(run_with_timeout 60 "$@" 2>"$TMP_ROOT/last.err")" || RC=$?
}
guard() { : >"$GH_STUB_LOG"; run_cap bash "$1/bin/github-issues/clarify-guard-loop.sh" --session-id "$2" --plans-dir "$PLANS"; }
scope_c() { : >"$GH_STUB_LOG"; run_cap bash "$1/bin/github-issues/clarify-commit-scope.sh" --session-id "$2" --plans-dir "$PLANS" --issues ""; }
gh_log() { cat "$GH_STUB_LOG" 2>/dev/null || true; }

# U owns an intent listing #4242 titled "Upstream intent"; D (resumed from U) has none.
U="$(new_sid)"; D="$(new_sid)"
write_state "$U"
write_state "$D" "$U"
write_intent "$U" "Upstream intent" 4242

case_begin "guard-loop-resumed-session-reads-upstream-intent" "bin/github-issues/clarify-guard-loop.sh"
export GH_STUB_STATE=OPEN
guard "$ROOT_N" "$D"
assert_eq "rc=$RC out=$OUT" "rc=0 out=PROCEED"
if [[ "$(gh_log)" == *"issue view 4242"* ]]; then pass "guard asked gh about U's #4242"
else fail "guard asked gh about U's #4242" "gh log: $(gh_log)"; fi
export GH_STUB_STATE=CLOSED
guard "$ROOT_N" "$D"
assert_eq "closed-out=$OUT" "closed-out=CLOSED_ENTRY"
export GH_STUB_STATE=OPEN
case_end

# #2631 SSOT: U's existing intent wins even when S has its own; the own intent is read only as
# never read when the declared upstream has none (L): no own-file fallback.
case_begin "guard-loop-upstream-intent-wins-over-own" "bin/github-issues/clarify-guard-loop.sh"
S="$(new_sid)"
write_state "$S" "$U"
write_intent "$S" "Own intent"
guard "$ROOT_N" "$S"
assert_eq "both-out=$OUT" "both-out=PROCEED"
if [[ "$(gh_log)" == *"issue view 4242"* ]]; then pass "guard read U's #4242 although S has its own intent"
else fail "guard read U's #4242 although S has its own intent" "gh log: $(gh_log)"; fi
L="$(new_sid)"
write_state "$L" "$(new_sid)"
write_intent "$L" "Legacy intent"
guard "$ROOT_N" "$L"
assert_eq "no-own-fallback-out=$OUT" "no-own-fallback-out=NEED_ISSUE"
case_end

case_begin "commit-scope-path-c-resumed-session-titles-from-upstream" "bin/github-issues/clarify-commit-scope.sh"
scope_c "$ROOT_N" "$D"
assert_eq "rc=$RC out=$OUT" "rc=0 out=CREATED:77"
if [[ "$(gh_log)" == *"issue create --title Upstream intent"* ]]; then pass "issue created with U's title"
else fail "issue created with U's title" "gh log: $(gh_log) err=$(head -c 300 "$TMP_ROOT/last.err")"; fi
case_end

case_begin "commit-scope-path-c-upstream-intent-wins-over-own" "bin/github-issues/clarify-commit-scope.sh"
scope_c "$ROOT_N" "$S"
if [ "$RC" -eq 0 ] && [[ "$(gh_log)" == *"--title Upstream intent"* ]]; then pass "issue created with U's title although S has its own intent"
else fail "issue created with U's title although S has its own intent" "rc=$RC gh log: $(gh_log)"; fi
scope_c "$ROOT_N" "$L"
if [ "$RC" -ne 0 ] && [[ "$(gh_log)" != *"Legacy intent"* ]]; then pass "upstream without a file: L's own intent is never used (no issue created)"
else fail "upstream without a file: L's own intent is never used (no issue created)" "rc=$RC gh log: $(gh_log)"; fi
case_end

case_begin "commit-scope-path-c-no-intent-anywhere-fails-on-upstream-path" "bin/github-issues/clarify-commit-scope.sh"
D2="$(new_sid)"; U2="$(new_sid)"
write_state "$D2" "$U2"
scope_c "$ROOT_N" "$D2"
assert_eq "missing-rc=$RC" "missing-rc=1"
if grep -qF -- "$U2-intent.md" "$TMP_ROOT/last.err" && ! grep -qF -- "$D2-intent.md" "$TMP_ROOT/last.err"; then pass "the missing path named is the upstream's intent (the write target)"
else fail "the missing path named is the upstream's intent (the write target)" "err=$(head -c 300 "$TMP_ROOT/last.err")"; fi
assert_eq "gh-calls=[$(gh_log)]" "gh-calls=[]"
case_end

# A copied checkout whose bin/plan-artifact-path fails or prints a foreign name: both scripts
# fall back to <plans>/<sid>-intent.md, so S2's own intent (#9191) is read, never U's.
FROOT="$TMP_ROOT/froot"
mkdir -p "$FROOT"
cp -r "$ROOT_N/bin" "$ROOT_N/hooks" "$FROOT/"
printf '%s\n' 'process.stdout.write(process.env.STUB_PAP_OUT || "");' 'process.exit(Number(process.env.STUB_PAP_RC || 0));' >"$FROOT/bin/plan-artifact-path"
# The copy is no git repo, so the real scanner finds no blocklist and fails closed; the root
# cases above already ran the real scanner, so the copy gets a pass-through one.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'exit 0' >"$FROOT/bin/scan-outbound.sh"
chmod +x "$FROOT/bin/scan-outbound.sh"
S2="$(new_sid)"
write_state "$S2" "$U"
write_intent "$S2" "Fallback intent" 9191

case_begin "guard-loop-falls-back-to-own-intent-on-bad-resolver" "bin/github-issues/clarify-guard-loop.sh"
for mode in "1:" "0:/elsewhere/secret.txt"; do
  export STUB_PAP_RC="${mode%%:*}" STUB_PAP_OUT="${mode#*:}"
  guard "$FROOT" "$S2"
  if [ "$OUT" = "PROCEED" ] && [[ "$(gh_log)" == *"issue view 9191"* ]]; then pass "resolver rc=$STUB_PAP_RC out=[$STUB_PAP_OUT] -> own intent"
  else fail "resolver rc=$STUB_PAP_RC out=[$STUB_PAP_OUT] -> own intent" "out=$OUT gh log: $(gh_log)"; fi
done
case_end

case_begin "commit-scope-falls-back-to-own-intent-on-bad-resolver" "bin/github-issues/clarify-commit-scope.sh"
for mode in "1:" "0:/elsewhere/secret.txt"; do
  export STUB_PAP_RC="${mode%%:*}" STUB_PAP_OUT="${mode#*:}"
  scope_c "$FROOT" "$S2"
  if [ "$RC" -eq 0 ] && [[ "$(gh_log)" == *"--title Fallback intent"* ]]; then pass "resolver rc=$STUB_PAP_RC out=[$STUB_PAP_OUT] -> own intent"
  else fail "resolver rc=$STUB_PAP_RC out=[$STUB_PAP_OUT] -> own intent" "rc=$RC out=$OUT gh log: $(gh_log) err=$(head -c 400 "$TMP_ROOT/last.err")"; fi
done
unset STUB_PAP_RC STUB_PAP_OUT
case_end

case_begin "boundary-missing-plans-dir-and-out-of-class-session-id" "bin/github-issues/clarify-guard-loop.sh"
: >"$GH_STUB_LOG"
run_cap bash "$ROOT_N/bin/github-issues/clarify-guard-loop.sh" --session-id "$D" --plans-dir "$PLANS/no-such-dir"
assert_eq "guard-missing-plans-rc=$RC" "guard-missing-plans-rc=2"
run_cap bash "$ROOT_N/bin/github-issues/clarify-commit-scope.sh" --session-id "$D" --plans-dir "$PLANS/no-such-dir" --issues ""
assert_eq "scope-missing-plans-rc=$RC" "scope-missing-plans-rc=2"
# An out-of-class id makes plan-artifact-path exit 1; neither script may reach U's intent or gh create.
guard "$ROOT_N" "../$U"
if [ "$OUT" != "PROCEED" ] && [[ "$(gh_log)" != *"4242"* ]]; then pass "guard: out-of-class id never reads U's intent (out=$OUT rc=$RC)"
else fail "guard: out-of-class id never reads U's intent" "out=$OUT gh log: $(gh_log)"; fi
scope_c "$ROOT_N" "../$U"
if [ "$RC" -ne 0 ] && [[ "$(gh_log)" != *"issue create"* ]]; then pass "scope: out-of-class id creates no issue (rc=$RC)"
else fail "scope: out-of-class id creates no issue" "rc=$RC out=$OUT gh log: $(gh_log)"; fi
case_end

case_begin "static-both-scripts-resolve-intent-through-plan-artifact-path" "bin/github-issues/clarify-commit-scope.sh"
for rel in bin/github-issues/clarify-guard-loop.sh bin/github-issues/clarify-commit-scope.sh; do
  if grep -qF -- 'plan-artifact-path" --stage intent' "$ROOT_N/$rel"; then pass "static: $rel uses plan-artifact-path --stage intent"
  else fail "static: $rel uses plan-artifact-path --stage intent"; fi
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
