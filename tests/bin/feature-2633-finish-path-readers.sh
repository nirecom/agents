#!/usr/bin/env bash
# Tests: bin/plan-artifact-path, bin/parse-closes-issues, bin/render-final-report.js, bin/issue-close-write-outcome.js, bin/supervisor-check-session-active, bin/resolve-accepted-tradeoffs-file, hooks/workflow-state/plan-artifact-owner.js, hooks/workflow-state/session-facts.js, skills/make-outline-plan/scripts/run-codex-review-loop.sh, skills/make-detail-plan/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, skills/review-plan-security/scripts/run-codex-review-loop.sh
# Tags: scope:issue-specific, workflow-state, plan-artifact, finish-path, TL2
# #2633 1b finish path (shell / CLI): a downstream session D whose plan artifacts live under
# its upstream session U (state key upstream_session_id) must resolve U's intent / outline in
# every terminal reader. gh is a PATH stub; the static block lists the migrated SKILL/md/sh files.
# TL3 gap: a real gh against GitHub and a real resumed session are not exercised here.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

readonly TMP_ROOT="$(np "$(make_tmp)")"
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID
mkdir -p "$TMP_ROOT/cwd" "$TMP_ROOT/ghbin" "$TMP_ROOT/transcripts" "$TMP_ROOT/outside" "$TMP_ROOT/alt"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP_ROOT/transcripts"
cd "$TMP_ROOT/cwd" || exit 1

ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
BIN="$ROOT_N/bin"
PLANS="$WORKFLOW_PLANS_DIR"
CLI="$BIN/plan-artifact-path"

# gh stub: logs every call, answers the state the case put in GH_STUB_STATE. A per-issue
# GH_STUB_FAIL_<n> makes that lookup exit 1; GH_STUB_STATE_<n> overrides the state for <n>.
export GH_STUB_LOG="$TMP_ROOT/gh.log"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >>"$GH_STUB_LOG"' \
  'n=x; [[ "${3:-}" =~ ^[0-9]+$ ]] && n="$3"; f="GH_STUB_FAIL_$n"; s="GH_STUB_STATE_$n"' \
  '[[ -n "${!f:-}" ]] && exit 1' \
  'printf "%s\n" "${!s:-${GH_STUB_STATE:-OPEN}}"' >"$TMP_ROOT/ghbin/gh"
chmod +x "$TMP_ROOT/ghbin/gh"
# PATH is ':'-separated, so the drive-letter form (C:/...) of np() would split; use /c/... there.
GH_BIN_DIR="$TMP_ROOT/ghbin"
command -v cygpath >/dev/null 2>&1 && GH_BIN_DIR="$(cygpath -u "$GH_BIN_DIR")"
export PATH="$GH_BIN_DIR:$PATH"

new_sid() { node -e 'process.stdout.write(require("crypto").randomUUID())'; }
# write_state <sid> [<upstream-sid>] — a raw v5 state file (the writer still rejects the new keys).
write_state() {
  local up=""
  [ -n "${2:-}" ] && up=",\"upstream_session_id\":\"$2\",\"upstream_copy_seq\":0"
  printf '{"version":5,"session_id":"%s","created_at":"2026-01-01T00:00:00.000Z","session_start_context":{"cwd":"%s","git_branch":"feature/f2633"},"events":[]%s}\n' \
    "$1" "$TMP_ROOT/cwd" "$up" >"$WORKFLOW_STATE_DIR/$1.json"
}
# write_intent <dir> <sid> <issue>; write_outline <dir> <sid>
write_intent() { printf '# Intent\n\n## Goal\n\ng\n\n## Issues\n\n- #%s fixture issue\n' "$3" >"$1/$2-intent.md"; }
write_outline() { printf '# Outline\n\n## Adopted approach\n\na\n' >"$1/$2-outline.md"; }
norm() { local p; p="$(np "$1" 2>/dev/null || printf '%s' "$1")"; p="${p//\\//}"; printf '%s' "${p,,}"; }
same_path() { [ -n "$1" ] && [ "$(norm "$1")" = "$(norm "$2")" ]; }
# run_cap <cmd...> — OUT = stdout, RC = exit code, ERR = first stderr line.
run_cap() {
  OUT="$(run_with_timeout 60 "$@" 2>"$TMP_ROOT/last.err")"
  RC=$?
  ERR="$(head -n 1 "$TMP_ROOT/last.err" 2>/dev/null)"
}
gh_calls() { [ -f "$GH_STUB_LOG" ] && cat "$GH_STUB_LOG"; }
cli_present() { [ -f "$CLI" ] || { fail "$1" "bin/plan-artifact-path is not implemented"; return 1; }; }

# Fixture: U owns intent (#4242) and outline; downstream D has no artifact of its own.
U="$(new_sid)"; D="$(new_sid)"
write_state "$U"
write_state "$D" "$U"
write_intent "$PLANS" "$U" 4242
write_outline "$PLANS" "$U"

case_begin "parse-closes-issues-session-follows-upstream" "bin/parse-closes-issues"
run_cap node "$BIN/parse-closes-issues" --session "$D"
if [ "$RC" -eq 0 ] && [[ "$OUT" == *4242* ]]; then pass "parse-closes-issues --session D returns U's #4242"
else fail "parse-closes-issues --session D returns U's #4242" "rc=$RC out=$OUT err=$ERR"; fi
case_end

case_begin "render-final-report-closes-follow-upstream" "bin/render-final-report.js"
node "$ROOT_N/tests/lib/workflow-state-tool.js" "$ROOT_N" ctl "$D" final-report-env.json '{}' >/dev/null
run_cap node "$BIN/render-final-report.js" --session "$D"
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"#4242"* ]]; then pass "render-final-report --session D lists U's #4242"
else fail "render-final-report --session D lists U's #4242" "rc=$RC err=$ERR out=$(printf '%s' "$OUT" | grep -i -A2 'close' | head -n 3 | tr '\n' ' ')"; fi
case_end

case_begin "issue-close-write-outcome-fallback-follows-upstream" "bin/issue-close-write-outcome.js"
run_cap node "$BIN/issue-close-write-outcome.js" --fallback "$PLANS/$D-intent.md" "$TMP_ROOT/outcome.json"
if [ -f "$TMP_ROOT/outcome.json" ] && grep -q '"issueNumber": *4242' "$TMP_ROOT/outcome.json"; then
  pass "--fallback <PLANS>/D-intent.md writes U's #4242"
else fail "--fallback <PLANS>/D-intent.md writes U's #4242" "rc=$RC out=$(tr -d '\n' <"$TMP_ROOT/outcome.json" 2>/dev/null | head -c 200)"; fi
case_end

case_begin "supervisor-check-session-active-reads-upstream-issue" "bin/supervisor-check-session-active"
: >"$GH_STUB_LOG"
export GH_STUB_STATE=CLOSED
run_cap bash "$BIN/supervisor-check-session-active" "$D" --plans-dir "$PLANS"
assert_eq "closed-rc=$RC" "closed-rc=1"
: >"$GH_STUB_LOG"
export GH_STUB_STATE=OPEN
run_cap bash "$BIN/supervisor-check-session-active" "$D" --plans-dir "$PLANS"
assert_eq "open-rc=$RC" "open-rc=0"
if [[ "$(gh_calls)" == *"issue view 4242"* ]]; then pass "gh was asked about U's #4242"
else fail "gh was asked about U's #4242" "gh log: $(gh_calls | tr '\n' ' ')"; fi
case_end

# Two-issue intent (#6101, #6102): active unless every lookup answers CLOSED.
M="$(new_sid)"
write_state "$M"
printf '# Intent\n\n## Goal\n\ng\n\n## Issues\n\n- #6101 first issue\n- #6102 second issue\n' >"$PLANS/$M-intent.md"
# run_two <state-6101> <state-6102|FAIL> — runs the CLI on M with per-issue stub answers.
run_two() {
  : >"$GH_STUB_LOG"
  export GH_STUB_STATE_6101="$1"
  if [[ "$2" == "FAIL" ]]; then export GH_STUB_FAIL_6102=1; unset GH_STUB_STATE_6102
  else export GH_STUB_STATE_6102="$2"; unset GH_STUB_FAIL_6102; fi
  run_cap bash "$BIN/supervisor-check-session-active" "$M" --plans-dir "$PLANS"
  unset GH_STUB_STATE_6101 GH_STUB_STATE_6102 GH_STUB_FAIL_6102
}
asked_both() {
  if [[ "$(gh_calls)" == *"issue view 6101"* && "$(gh_calls)" == *"issue view 6102"* ]]; then pass "$1: gh was asked about #6101 and #6102"
  else fail "$1: gh was asked about #6101 and #6102" "gh log: $(gh_calls | tr '\n' ' ')"; fi
}

case_begin "supervisor-check-session-active-two-issues-closed-then-open-is-active" "bin/supervisor-check-session-active"
run_two CLOSED OPEN
assert_eq "closed-open-rc=$RC" "closed-open-rc=0"
asked_both "closed-open"
case_end

case_begin "supervisor-check-session-active-two-issues-open-then-closed-is-active" "bin/supervisor-check-session-active"
run_two OPEN CLOSED
assert_eq "open-closed-rc=$RC" "open-closed-rc=0"
case_end

case_begin "supervisor-check-session-active-two-issues-failed-lookup-is-active" "bin/supervisor-check-session-active"
run_two CLOSED FAIL
assert_eq "closed-fail-rc=$RC" "closed-fail-rc=0"
asked_both "closed-fail"
case_end

case_begin "supervisor-check-session-active-two-issues-all-closed-is-terminated" "bin/supervisor-check-session-active"
run_two CLOSED CLOSED
assert_eq "closed-closed-rc=$RC" "closed-closed-rc=1"
asked_both "closed-closed"
case_end

case_begin "own-intent-wins-over-upstream" "bin/parse-closes-issues"
S="$(new_sid)"
write_state "$S" "$U"
write_intent "$PLANS" "$S" 5151
run_cap node "$BIN/parse-closes-issues" --session "$S"
if [[ "$OUT" == *5151* && "$OUT" != *4242* ]]; then pass "own intent (#5151) is used, not U's"
else fail "own intent (#5151) is used, not U's" "out=$OUT"; fi
case_end

case_begin "no-intent-anywhere-stays-active-without-gh" "bin/supervisor-check-session-active"
N="$(new_sid)"; N2="$(new_sid)"; U3="$(new_sid)"
write_state "$N2" "$U3"
export GH_STUB_STATE=CLOSED
for sid in "$N" "$N2"; do
  : >"$GH_STUB_LOG"
  run_cap bash "$BIN/supervisor-check-session-active" "$sid" --plans-dir "$PLANS"
  assert_eq "missing-intent-rc=$RC" "missing-intent-rc=0"
  assert_eq "gh-calls=[$(gh_calls)]" "gh-calls=[]"
done
run_cap node "$BIN/parse-closes-issues" --session "$N2"
assert_eq "$OUT" "[]"
case_end

case_begin "resolve-accepted-tradeoffs-follows-upstream" "bin/resolve-accepted-tradeoffs-file"
run_cap bash "$BIN/resolve-accepted-tradeoffs-file" "$PLANS" "$D" outline intent
if [ "$RC" -eq 0 ] && same_path "$OUT" "$PLANS/$U-outline.md"; then pass "D outline intent -> U's outline"
else fail "D outline intent -> U's outline" "rc=$RC out=$OUT err=$ERR"; fi
case_end

case_begin "plan-artifact-path-resolves-upstream-and-honors-plans-dir" "bin/plan-artifact-path"
if cli_present "plan-artifact-path exists"; then
  run_cap node "$CLI" --stage outline --session "$D"
  if [ "$RC" -eq 0 ] && same_path "$OUT" "$PLANS/$U-outline.md"; then pass "default plans dir (WORKFLOW_PLANS_DIR) -> U's outline"
  else fail "default plans dir (WORKFLOW_PLANS_DIR) -> U's outline" "rc=$RC out=$OUT err=$ERR"; fi
  write_intent "$TMP_ROOT/alt" "$U" 7777
  run_cap node "$CLI" --stage intent --session "$D" --plans-dir "$TMP_ROOT/alt"
  if [ "$RC" -eq 0 ] && same_path "$OUT" "$TMP_ROOT/alt/$U-intent.md"; then pass "--plans-dir is honored"
  else fail "--plans-dir is honored" "rc=$RC out=$OUT err=$ERR"; fi
  [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] && pass "one output line" || fail "one output line" "out=$OUT"
fi
case_end

case_begin "plan-artifact-path-missing-prints-own-path" "bin/plan-artifact-path"
if cli_present "plan-artifact-path exists"; then
  D2="$(new_sid)"; U2="$(new_sid)"
  write_state "$D2" "$U2"
  run_cap node "$CLI" --stage detail --session "$D2"
  if [ "$RC" -eq 0 ] && same_path "$OUT" "$PLANS/$D2-detail.md"; then pass "missing everywhere -> own path, exit 0"
  else fail "missing everywhere -> own path, exit 0" "rc=$RC out=$OUT err=$ERR"; fi
fi
case_end

case_begin "plan-artifact-path-rejects-unresolvable-input" "bin/plan-artifact-path"
if cli_present "plan-artifact-path exists"; then
  run_cap node "$CLI" --stage intent
  assert_eq "no-sid-rc=$RC out=[$OUT]" "no-sid-rc=1 out=[]"
  run_cap node "$CLI" --stage intent --session "../$U"
  assert_eq "traversal-rc=$RC out=[$OUT]" "traversal-rc=1 out=[]"
  run_cap node "$CLI" --stage bogus --session "$D"
  if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then pass "unknown --stage is rejected"
  else fail "unknown --stage is rejected" "rc=$RC out=$OUT"; fi
fi
case_end

# Symlinks need native support on Windows (developer mode); without it the cases skip.
export MSYS=winsymlinks:nativestrict
printf 'secret\n' >"$TMP_ROOT/outside/secret.md"

case_begin "resolve-accepted-tradeoffs-rejects-own-escaping-symlink" "bin/resolve-accepted-tradeoffs-file"
L="$(new_sid)"
write_state "$L"
if ln -s "$TMP_ROOT/outside/secret.md" "$PLANS/$L-outline.md" 2>/dev/null && [ -L "$PLANS/$L-outline.md" ]; then
  run_cap bash "$BIN/resolve-accepted-tradeoffs-file" "$PLANS" "$L" outline
  assert_eq "own-symlink-rc=$RC" "own-symlink-rc=3"
else skip "native symlinks unavailable"; fi
case_end

case_begin "resolve-accepted-tradeoffs-rejects-upstream-escaping-symlink" "bin/resolve-accepted-tradeoffs-file"
D3="$(new_sid)"; U4="$(new_sid)"
write_state "$U4"
write_state "$D3" "$U4"
if ln -s "$TMP_ROOT/outside/secret.md" "$PLANS/$U4-outline.md" 2>/dev/null && [ -L "$PLANS/$U4-outline.md" ]; then
  run_cap bash "$BIN/resolve-accepted-tradeoffs-file" "$PLANS" "$D3" outline
  assert_eq "upstream-symlink-rc=$RC" "upstream-symlink-rc=3"
  if [[ "$(norm "$OUT")" != *secret.md* ]]; then pass "outside target is never printed"
  else fail "outside target is never printed" "out=$OUT"; fi
else skip "native symlinks unavailable"; fi
case_end
unset MSYS

# Static: no migrated reader still builds <session-id>-intent.md itself. --fallback lines
# (session-close: follows via getClosesIssues) and frontmatter description: lines are outputs/prose.
MD_EXCLUDE='--fallback|^[0-9]+:description:'
static_absent() {
  local rel="$1" lit="$2" ex="${3:-}" hits
  [ -f "$ROOT_N/$rel" ] || { fail "static: $rel exists"; return; }
  hits="$(grep -nF -- "$lit" "$ROOT_N/$rel")"
  [ -n "$ex" ] && hits="$(printf '%s\n' "$hits" | grep -vE -- "$ex")"
  if [ -z "$hits" ]; then pass "static: $rel has no $lit"
  else fail "static: $rel has no $lit" "$(printf '%s' "$hits" | head -n 2 | tr '\n' ' ')"; fi
}
static_present() {
  if grep -qF -- "$2" "$ROOT_N/$1" 2>/dev/null; then pass "static: $1 uses $2"
  else fail "static: $1 uses $2"; fi
}

case_begin "static-migrated-readers-build-no-intent-path" "skills/session-close/SKILL.md"
for rel in skills/commit-push/SKILL.md skills/issue-close-finalize/SKILL.md skills/session-close/SKILL.md \
  skills/worktree-end/scripts/cleanup-cascade.md skills/update-docs/SKILL.md \
  skills/make-outline-plan/SKILL.md skills/make-detail-plan/SKILL.md; do
  static_absent "$rel" '<session-id>-intent.md' "$MD_EXCLUDE"
done
static_absent skills/make-outline-plan/SKILL.md '$SESSION_ID-intent.md' "$MD_EXCLUDE"
static_absent skills/make-detail-plan/SKILL.md '<session-id>-outline.md' "$MD_EXCLUDE"
static_absent skills/make-detail-plan/SKILL.md '--source-kind outline "$PLANS_DIR/$SESSION_ID-outline.md"'
case_end

case_begin "static-migrated-scripts-use-plan-artifact-path" "bin/resolve-accepted-tradeoffs-file"
for rel in skills/make-outline-plan/scripts/run-codex-review-loop.sh skills/make-detail-plan/scripts/run-codex-review-loop.sh \
  skills/review-tests/scripts/run-codex-review-loop.sh skills/review-plan-security/scripts/run-codex-review-loop.sh; do
  static_absent "$rel" '--class-members "$PLANS_DIR/$SESSION_ID-intent.md"'
done
static_absent skills/review-plan-security/scripts/run-codex-review-loop.sh 'DRAFT_FILE="${PLANS_DIR}/${SESSION_ID}-detail.md"'
static_present bin/supervisor-check-session-active plan-artifact-path
static_present bin/resolve-accepted-tradeoffs-file plan-artifact-path
case_end

# Behavioural: each plan review wrapper runs from a copied checkout whose bin/run-codex-review-loop
# is an argv-recording stub, so the paths the reviewer would receive are observed, not grepped.
FROOT="$TMP_ROOT/froot"
REVIEW_STAGES="make-outline-plan make-detail-plan review-tests review-plan-security"
mkdir -p "$FROOT/skills" "$TMP_ROOT/repo"
cp -r "$ROOT_N/bin" "$ROOT_N/hooks" "$FROOT/"
for s in $REVIEW_STAGES; do
  mkdir -p "$FROOT/skills/$s"
  cp -r "$ROOT_N/skills/$s/scripts" "$FROOT/skills/$s/scripts"
done
STUB_ARGV="$TMP_ROOT/reviewer-argv.txt"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$@\" >\"$STUB_ARGV\"" 'exit 0' >"$FROOT/bin/run-codex-review-loop"
chmod +x "$FROOT/bin/run-codex-review-loop"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config core.hooksPath /dev/null
printf '# Detail\n\n## Files to modify\n\n- x\n' >"$PLANS/$U-detail.md"

# run_wrapper <stage> <sid> — WRAP_RC = wrapper exit code; the stub's argv lands in STUB_ARGV.
run_wrapper() {
  rm -f "$STUB_ARGV"
  WRAP_RC=0
  (
    cd "$TMP_ROOT/repo" || exit 1
    export SESSION_ID="$2" PLANS_DIR="$PLANS" EXTENSIONS_USED=0 REVIEW_TESTS_FULL_SCAN=1
    run_with_timeout 60 bash "$FROOT/skills/$1/scripts/run-codex-review-loop.sh"
  ) >"$TMP_ROOT/wrap.out" 2>&1 || WRAP_RC=$?
}
argv_of() { [ -f "$STUB_ARGV" ] && awk -v f="$1" '$0 == f { getline; print; exit }' "$STUB_ARGV"; }

case_begin "review-wrappers-pass-upstream-plans-to-reviewer" "skills/review-tests/scripts/run-codex-review-loop.sh"
for s in $REVIEW_STAGES; do
  run_wrapper "$s" "$D"
  assert_eq "$s-rc=$WRAP_RC" "$s-rc=0"
  if same_path "$(argv_of --class-members)" "$PLANS/$U-intent.md"; then pass "$s: reviewer gets U's intent as --class-members"
  else fail "$s: reviewer gets U's intent as --class-members" "got=$(argv_of --class-members) out=$(head -c 300 "$TMP_ROOT/wrap.out")"; fi
done
run_wrapper review-plan-security "$D"
if same_path "$(argv_of --draft-file)" "$PLANS/$U-detail.md"; then pass "review-plan-security: reviewer reviews U's detail"
else fail "review-plan-security: reviewer reviews U's detail" "got=$(argv_of --draft-file)"; fi
case_end

case_begin "review-wrapper-own-intent-wins" "skills/make-detail-plan/scripts/run-codex-review-loop.sh"
run_wrapper make-detail-plan "$S"
if same_path "$(argv_of --class-members)" "$PLANS/$S-intent.md"; then pass "own intent is passed, not U's"
else fail "own intent is passed, not U's" "rc=$WRAP_RC got=$(argv_of --class-members)"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
