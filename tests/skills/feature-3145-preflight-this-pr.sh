#!/usr/bin/env bash
# feature-3145-preflight-this-pr.sh — #3145: GA-2 preflight refuses release while this-pr findings are open.
# Tests: skills/get-release-approval/scripts/preflight.sh
# Tags: TL2, scope:issue-specific, dup-group-keep:time-hard-limit, preflight, this-pr, release-phase, gh-stub, glab-stub, fail-closed
# TL2: preflight.sh runs as a real subprocess from inside a linked fixture worktree. The delivery
# route comes from a fixture state file (direct / pull_request / pull_request + AUTO_MERGE_PR=off),
# the forge from node-copy gh / glab stubs; the notes check is the real worktree-notes-triage.js.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../bin/feature-2527-release-phase/helpers.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2527-release-phase/helpers.sh"

# TL3 gap (not caught here): the skill reading PREFLIGHT=blocked + THIS_PR_OPEN lines and walking
# the user through the settle commands, and a live forge's mergeability answer.
# Closest-to-action mitigation: write_code completion refusal (T4) and the commit-push this-pr gate (T6).
# category: skill-orchestration.

readonly T_ROOT="$(make_tmp)"
RP_TMP="$T_ROOT"
rp_setup
trap rp_teardown EXIT
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
unset RUN_TL4 AGENTS_BASH_MAJOR_OVERRIDE AUTO_MERGE_PR
export ENFORCE_WORKTREE=on RUN_TL4=off
rp_fake_forge "$RP_TMP/forgebin" gh glab
git -C "$RP_REPO" remote set-url origin "https://github.com/example/repo.git"
rp_worktree
git -C "$RP_WT" config core.hooksPath /dev/null
PREFLIGHT_SH="$SCRIPT_CHECKOUT_ROOT/skills/get-release-approval/scripts/preflight.sh"
NOTES="$RP_WT/WORKTREE_NOTES.md"

# pf_in <dir> <args...> — preflight stdout plus RC=<exit>, run with $PWD=<dir>; stderr to pf.err.
pf_in() {
  local dir="$1" out rc
  shift
  out="$(cd "$dir" && run_with_timeout 120 bash "$PREFLIGHT_SH" "$@" 2>"$RP_TMP/pf.err")"
  rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}
this_pr_lines() { printf '%s\n' "$1" | grep -c '^THIS_PR_OPEN:'; }

write_notes() {
  printf '# Worktree Notes\n\n## BugsFound\n%s\n\n## RelatedTasks\n' "$1" > "$NOTES"
}
OPEN_ENTRY='- Parser drops trailing marker <!-- severity: medium --> <!-- pr-scope: this-pr -->'
SETTLED_ENTRY='- Unrelated cleanup idea <!-- severity: low --> <!-- pr-scope: other -->'

ST_SPEC_BASE="\"upto\":\"user_verification\",\"entered\":true,\"branch\":\"feature/2527-wt\",\"cwd\":\"$RP_WT_M\""
mk_state "{\"sid\":\"tp-direct\",\"path\":\"direct\",$ST_SPEC_BASE}"
mk_state "{\"sid\":\"tp-pr\",\"path\":\"pull_request\",\"autoMerge\":\"on\",$ST_SPEC_BASE}"
mk_state "{\"sid\":\"tp-wm\",\"path\":\"pull_request\",\"autoMerge\":\"off\",$ST_SPEC_BASE}"

# Rows: <name> | <sid> — every route blocks while one this-pr entry is open.
case_begin "preflight: open this-pr finding blocks every route with THIS_PR_OPEN lines" "skills/get-release-approval/scripts/preflight.sh"
write_notes "$OPEN_ENTRY"
while IFS='|' read -r name sid; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; sid="${sid//[[:space:]]/}"
  out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf_in "$RP_WT" --session "$sid" --repo "$RP_WT_M")"
  check "$name: exit 0" "$(field "$out" RC)" "0"
  check "$name: PREFLIGHT blocked (never web_merge_*)" "$(field "$out" PREFLIGHT)" "blocked"
  check_contains "$name: reason names the unsettled findings" "$(field "$out" PREFLIGHT_REASON)" "this-pr findings are unsettled"
  check "$name: THIS_PR_OPEN line present" "$( [ "$(this_pr_lines "$out")" -ge 1 ] && echo yes || echo no)" "yes"
  check "$name: no PR number reported" "$(field "$out" PR_NUMBER)" ""
  check "$name: RUN_TL4 still the first line" "$(printf '%s\n' "$out" | sed -n 1p | cut -d= -f1)" "RUN_TL4"
done <<'TABLE'
direct     | tp-direct
pullreq    | tp-pr
web-merge  | tp-wm
TABLE
case_end

case_begin "preflight: \$PWD outside the session worktree is never read as absent" "skills/get-release-approval/scripts/preflight.sh"
# The session's worktree holds no open entry at all; only the cwd differs. --repo names the
# session worktree, which must not be used to resolve the notes.
write_notes "$SETTLED_ENTRY"
for sid in tp-direct tp-pr; do
  out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf_in "$RP_REPO" --session "$sid" --repo "$RP_WT_M")"
  check "main-checkout cwd/$sid: exit 0" "$(field "$out" RC)" "0"
  check "main-checkout cwd/$sid: PREFLIGHT blocked" "$(field "$out" PREFLIGHT)" "blocked"
  check_not_contains "main-checkout cwd/$sid: not the direct ok reason" "$(field "$out" PREFLIGHT_REASON)" "delivery path direct"
  check_not_contains "main-checkout cwd/$sid: not the PR ok reason" "$(field "$out" PREFLIGHT_REASON)" "open and mergeable"
done
# Adversarial: an open entry sits in the session worktree but the caller stands in the main checkout.
write_notes "$OPEN_ENTRY"
out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf_in "$RP_REPO" --session tp-direct --repo "$RP_WT_M")"
check "main-checkout cwd/open: PREFLIGHT blocked" "$(field "$out" PREFLIGHT)" "blocked"
# A cwd that is no git repo at all (repo-unresolved) blocks too.
mkdir -p "$RP_TMP/plain"
out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf_in "$RP_TMP/plain" --session tp-direct --repo "$RP_WT_M")"
check "non-git cwd: PREFLIGHT blocked" "$(field "$out" PREFLIGHT)" "blocked"
check_not_contains "non-git cwd: not the direct ok reason" "$(field "$out" PREFLIGHT_REASON)" "delivery path direct"
case_end

case_begin "preflight: a failing notes check (exit 1) blocks with a reason" "skills/get-release-approval/scripts/preflight.sh"
rm -f "$NOTES"
mkdir -p "$NOTES"
out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf_in "$RP_WT" --session tp-direct --repo "$RP_WT_M")"
check "notes-is-dir: exit 0" "$(field "$out" RC)" "0"
check "notes-is-dir: PREFLIGHT blocked" "$(field "$out" PREFLIGHT)" "blocked"
check_not_contains "notes-is-dir: not the direct ok reason" "$(field "$out" PREFLIGHT_REASON)" "delivery path direct"
reason="$(field "$out" PREFLIGHT_REASON)"
check "notes-is-dir: reason is non-empty" "$( [ -n "$reason" ] && echo yes || echo no)" "yes"
rmdir "$NOTES"
# No state file for the session: the notes cannot be resolved, so the check fails closed.
out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf_in "$RP_WT" --session tp-nostate --repo "$RP_WT_M")"
check "no-state: PREFLIGHT blocked" "$(field "$out" PREFLIGHT)" "blocked"
check_not_contains "no-state: not an ok reason" "$(field "$out" PREFLIGHT_REASON)" "no pull request to check"
case_end

# Rows: <name> | <notes: absent|settled> | <sid> | <PREFLIGHT> | <reason fragment>
case_begin "preflight: absent or settled notes keep the previous verdicts" "skills/get-release-approval/scripts/preflight.sh"
while IFS='|' read -r name notes sid want reason; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; notes="${notes//[[:space:]]/}"; sid="${sid//[[:space:]]/}"; want="${want//[[:space:]]/}"
  reason="${reason#"${reason%%[![:space:]]*}"}"; reason="${reason%"${reason##*[![:space:]]}"}"
  rm -f "$NOTES"
  [[ "$notes" == "settled" ]] && write_notes "$SETTLED_ENTRY"
  out="$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf_in "$RP_WT" --session "$sid" --repo "$RP_WT_M")"
  check "$name: exit 0" "$(field "$out" RC)" "0"
  check "$name: PREFLIGHT" "$(field "$out" PREFLIGHT)" "$want"
  check_contains "$name: reason" "$(field "$out" PREFLIGHT_REASON)" "$reason"
  check "$name: no THIS_PR_OPEN line" "$(this_pr_lines "$out")" "0"
done <<'TABLE'
absent-direct   | absent  | tp-direct | ok                | delivery path direct
absent-pullreq  | absent  | tp-pr     | ok                | PR #42 is open and mergeable (CLEAN)
absent-webmerge | absent  | tp-wm     | web_merge_pending | the human merges it on the web
settled-direct  | settled | tp-direct | ok                | delivery path direct
settled-pullreq | settled | tp-pr     | ok                | PR #42 is open and mergeable (CLEAN)
settled-webmrg  | settled | tp-wm     | web_merge_pending | the human merges it on the web
TABLE
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
