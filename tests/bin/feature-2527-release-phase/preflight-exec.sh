#!/usr/bin/env bash
# preflight-exec.sh — #2527: get-release-approval GA-2 preflight run as a real subprocess.
# Tests: skills/get-release-approval/scripts/preflight.sh, bin/check-verification-gate.sh, bin/session-close-detect-route.js, bin/confirm-off
# Tags: scope:issue-specific, workflow, release-phase, user-verified, preflight, gh-stub, glab-stub, fail-closed
# TL2: spawns preflight.sh from outside a fixture repo (--repo), with a fixture state file for the
# delivery path, node-copy gh / glab stubs (fake-forge.js), and RUN_TL4 pinned per case in the
# process env (get-config-var: process env wins over .env).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): the skill driving AskUserQuestion from these lines and a live forge's
# mergeability answer; the caller-side RUN_TL4 handling lives in skills/_shared/user-verified.md.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.
rp_setup
trap rp_teardown EXIT
rp_fake_forge "$RP_TMP/forgebin" gh glab
PREFLIGHT_SH="$_HELPERS_SCRIPT_CHECKOUT_ROOT/skills/get-release-approval/scripts/preflight.sh"
GH_URL="https://github.com/example/repo.git"
GL_URL="https://gitlab.com/example/repo.git"
unset RUN_TL4 AGENTS_BASH_MAJOR_OVERRIDE

# pf <args...> — preflight stdout plus RC=<exit>, run from $RP_TMP (not the repo); stderr to pf.err.
pf() {
  local out rc
  out="$(cd "$RP_TMP" && run_with_timeout 120 bash "$PREFLIGHT_SH" "$@" 2>"$RP_TMP/pf.err")"
  rc=$?
  printf '%s\nRC=%s\n' "$out" "$rc"
}
tl4_word() { if [ "$1" = "on" ]; then printf 'ON'; else printf 'OFF'; fi; }
use_origin() { git -C "$RP_REPO" remote set-url origin "$1"; }

mk_state '{"sid":"pf-direct","path":"direct"}'
mk_state '{"sid":"pf-pr","path":"pull_request"}'
mk_state '{"sid":"pf-meta","dtype":"wf-meta","path":"pull_request"}'

case_begin "preflight: direct path is ok with no forge call (RUN_TL4 on and off)" "skills/get-release-approval/scripts/preflight.sh"
use_origin "$GH_URL"
for tl4 in on off; do
  : > "$RP_TMP/forge.log"
  out="$(RUN_TL4="$tl4" FAKE_FORGE_STATE=OPEN pf --session pf-direct --repo "$RP_REPO")"
  check "direct/$tl4: exit 0" "$(field "$out" RC)" "0"
  check "direct/$tl4: RUN_TL4 line" "$(field "$out" RUN_TL4)" "$(tl4_word "$tl4")"
  check "direct/$tl4: GATE_RC 0" "$(field "$out" GATE_RC)" "0"
  check "direct/$tl4: PREFLIGHT ok" "$(field "$out" PREFLIGHT)" "ok"
  check "direct/$tl4: empty PR_NUMBER" "$(field "$out" PR_NUMBER)" ""
  check_contains "direct/$tl4: reason names the path" "$(field "$out" PREFLIGHT_REASON)" "delivery path direct"
  check "direct/$tl4: no forge CLI called" "$(grep -c . "$RP_TMP/forge.log")" "0"
done
out="$(RUN_TL4=on pf --session pf-meta --repo "$RP_REPO")"
check "wf-meta: PREFLIGHT ok" "$(field "$out" PREFLIGHT)" "ok"
check_contains "wf-meta: reason names wf-meta" "$(field "$out" PREFLIGHT_REASON)" "delivery path wf-meta"
case_end

# Rows: <name> | <RUN_TL4> | <FAKE_FORGE_STATE> | <mergeStateStatus> | <PREFLIGHT> | <PR_NUMBER> | <reason fragment>
case_begin "preflight: github PR mergeability verdicts (table)" "skills/get-release-approval/scripts/preflight.sh"
use_origin "$GH_URL"
while IFS='|' read -r name tl4 st merge want num reason; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; tl4="${tl4//[[:space:]]/}"; st="${st//[[:space:]]/}"
  merge="${merge//[[:space:]]/}"; want="${want//[[:space:]]/}"; num="${num//[[:space:]]/}"
  reason="${reason#"${reason%%[![:space:]]*}"}"; reason="${reason%"${reason##*[![:space:]]}"}"
  : > "$RP_TMP/forge.log"
  out="$(RUN_TL4="$tl4" FAKE_FORGE_STATE="$st" FAKE_FORGE_MERGE="$merge" pf --session pf-pr --repo "$RP_REPO")"
  check "$name: exit 0" "$(field "$out" RC)" "0"
  check "$name: RUN_TL4 pinned" "$(field "$out" RUN_TL4)" "$(tl4_word "$tl4")"
  check "$name: PREFLIGHT" "$(field "$out" PREFLIGHT)" "$want"
  check "$name: PR_NUMBER" "$(field "$out" PR_NUMBER)" "$num"
  check_contains "$name: reason" "$(field "$out" PREFLIGHT_REASON)" "$reason"
  check_contains "$name: gh queried in --repo" "$(cat "$RP_TMP/forge.log")" "$RP_REPO_M|gh pr view"
done <<'TABLE'
gh-clean-tl4-on       | on  | OPEN   | CLEAN    | ok            | 42 | PR #42 is open and mergeable (CLEAN)
gh-clean-tl4-off      | off | OPEN   | CLEAN    | ok            | 42 | PR #42 is open and mergeable (CLEAN)
gh-merged-tl4-on      | on  | MERGED | CLEAN    | merged_on_web | 42 | already merged outside this session
gh-merged-tl4-off     | off | MERGED | UNKNOWN  | merged_on_web | 42 | already merged outside this session
gh-dirty-tl4-on       | on  | OPEN   | DIRTY    | blocked       | 42 | merge conflicts (DIRTY)
gh-dirty-tl4-off      | off | OPEN   | DIRTY    | blocked       | 42 | merge conflicts (DIRTY)
gh-behind             | on  | OPEN   | BEHIND   | blocked       | 42 | BEHIND the base branch
gh-blocked-checks     | off | OPEN   | BLOCKED  | blocked       | 42 | is BLOCKED — wait for required checks
gh-unstable           | on  | OPEN   | UNSTABLE | blocked       | 42 | is UNSTABLE — wait for required checks
gh-draft              | off | OPEN   | DRAFT    | blocked       | 42 | is a draft
gh-unknown-tl4-on     | on  | OPEN   | UNKNOWN  | blocked       | 42 | mergeability is UNKNOWN
gh-unknown-tl4-off    | off | OPEN   | UNKNOWN  | blocked       | 42 | mergeability is UNKNOWN
gh-closed             | on  | CLOSED | CLEAN    | blocked       | 42 | is CLOSED, not OPEN
gh-no-pr              | off | NONE   | CLEAN    | blocked       |    | no pull request for the current branch
gh-api-failure        | on  | FAIL   | CLEAN    | blocked       |    | no pull request for the current branch
TABLE
case_end

# Rows: <name> | <RUN_TL4> | <state> | <detailed_merge_status> | <draft> | <PREFLIGHT> | <PR_NUMBER> | <reason fragment>
# detailed_merge_status maps onto the gh vocabulary (conflict / cannot_be_merged -> DIRTY,
# need_rebase -> BEHIND, ci_* / not_approved / ... -> BLOCKED); only uncomputed values
# (checking / unchecked / preparing) fall to the generic "wait for the forge" text.
case_begin "preflight: gitlab MR mergeability verdicts (table)" "skills/get-release-approval/scripts/preflight.sh"
use_origin "$GL_URL"
while IFS='|' read -r name tl4 st merge draft want num reason; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; tl4="${tl4//[[:space:]]/}"; st="${st//[[:space:]]/}"; merge="${merge//[[:space:]]/}"
  draft="${draft//[[:space:]]/}"; want="${want//[[:space:]]/}"; num="${num//[[:space:]]/}"
  reason="${reason#"${reason%%[![:space:]]*}"}"; reason="${reason%"${reason##*[![:space:]]}"}"
  : > "$RP_TMP/forge.log"
  out="$(RUN_TL4="$tl4" FAKE_FORGE_STATE="$st" FAKE_GLAB_MERGE="$merge" FAKE_GLAB_DRAFT="$draft" pf --session pf-pr --repo "$RP_REPO")"
  check "$name: exit 0" "$(field "$out" RC)" "0"
  check "$name: RUN_TL4 pinned" "$(field "$out" RUN_TL4)" "$(tl4_word "$tl4")"
  check "$name: PREFLIGHT" "$(field "$out" PREFLIGHT)" "$want"
  check "$name: PR_NUMBER" "$(field "$out" PR_NUMBER)" "$num"
  check_contains "$name: reason" "$(field "$out" PREFLIGHT_REASON)" "$reason"
  check_contains "$name: glab queried in --repo" "$(cat "$RP_TMP/forge.log")" "$RP_REPO_M|glab mr view"
  check_not_contains "$name: gh never called on gitlab" "$(cat "$RP_TMP/forge.log")" "|gh "
done <<'TABLE'
gl-mergeable-tl4-on   | on  | OPEN   | mergeable     | 0 | ok            | 42 | PR #42 is open and mergeable (CLEAN)
gl-can-be-merged-off  | off | OPEN   | can_be_merged | 0 | ok            | 42 | PR #42 is open and mergeable (CLEAN)
gl-merged-tl4-on      | on  | MERGED | mergeable     | 0 | merged_on_web | 42 | already merged outside this session
gl-merged-tl4-off     | off | MERGED | checking      | 0 | merged_on_web | 42 | already merged outside this session
gl-conflict           | off | OPEN   | conflict      | 0 | blocked       | 42 | merge conflicts (DIRTY)
gl-cannot-be-merged   | on  | OPEN   | cannot_be_merged | 0 | blocked    | 42 | merge conflicts (DIRTY)
gl-need-rebase        | off | OPEN   | need_rebase   | 0 | blocked       | 42 | BEHIND the base branch
gl-ci-still-running   | on  | OPEN   | ci_still_running | 0 | blocked    | 42 | is BLOCKED — wait for required checks
gl-not-approved       | off | OPEN   | not_approved  | 0 | blocked       | 42 | is BLOCKED — wait for required checks
gl-draft-status       | on  | OPEN   | draft_status  | 0 | blocked       | 42 | is a draft
gl-unchecked          | off | OPEN   | unchecked     | 0 | blocked       | 42 | mergeability is UNCHECKED — wait for the forge
gl-preparing          | on  | OPEN   | preparing     | 0 | blocked       | 42 | mergeability is PREPARING — wait for the forge
gl-checking-tl4-on    | on  | OPEN   | checking      | 0 | blocked       | 42 | mergeability is CHECKING — wait for the forge
gl-checking-tl4-off   | off | OPEN   | checking      | 0 | blocked       | 42 | mergeability is CHECKING — wait for the forge
gl-draft              | on  | OPEN   | mergeable     | 1 | blocked       | 42 | is a draft
gl-closed             | off | CLOSED | mergeable     | 0 | blocked       | 42 | is CLOSED, not OPEN
gl-no-mr              | on  | NONE   | mergeable     | 0 | blocked       |    | no merge request for the current branch
gl-malformed          | off | MALFORMED | mergeable  | 0 | blocked       |    | no pull request for the current branch
TABLE
case_end

case_begin "preflight: verification-gate failure is reported as GATE_RC and never ends the preflight" "bin/check-verification-gate.sh"
use_origin "$GH_URL"
for tl4 in on off; do
  out="$(AGENTS_BASH_MAJOR_OVERRIDE=3 RUN_TL4="$tl4" FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf --session pf-pr --repo "$RP_REPO")"
  check "gate-fail/$tl4: exit 0" "$(field "$out" RC)" "0"
  check "gate-fail/$tl4: RUN_TL4" "$(field "$out" RUN_TL4)" "$(tl4_word "$tl4")"
  check "gate-fail/$tl4: GATE_RC 3 (internal error)" "$(field "$out" GATE_RC)" "3"
  check_not_contains "gate-fail/$tl4: no CATEGORY line" "$out" "CATEGORY:"
  check "gate-fail/$tl4: PR verdict still computed" "$(field "$out" PREFLIGHT)" "ok"
  out="$(AGENTS_BASH_MAJOR_OVERRIDE=3 RUN_TL4="$tl4" pf --session pf-direct --repo "$RP_REPO")"
  check "gate-fail/$tl4 direct: GATE_RC 3" "$(field "$out" GATE_RC)" "3"
  check "gate-fail/$tl4 direct: PREFLIGHT ok" "$(field "$out" PREFLIGHT)" "ok"
done
case_end

case_begin "preflight: staged risk file surfaces its CATEGORY line in the --repo dir" "bin/check-verification-gate.sh"
mkdir -p "$RP_REPO/skills/demo"
printf '# demo\n' > "$RP_REPO/skills/demo/SKILL.md"
git -C "$RP_REPO" add skills/demo/SKILL.md
for tl4 in on off; do
  out="$(RUN_TL4="$tl4" pf --session pf-direct --repo "$RP_REPO")"
  check "category/$tl4: GATE_RC 0" "$(field "$out" GATE_RC)" "0"
  check_contains "category/$tl4: skill-orchestration line" "$out" "CATEGORY: skill-orchestration"
  check "category/$tl4: RUN_TL4" "$(field "$out" RUN_TL4)" "$(tl4_word "$tl4")"
  check "category/$tl4: PREFLIGHT ok" "$(field "$out" PREFLIGHT)" "ok"
done
check "line order: RUN_TL4 first" "$(printf '%s\n' "$out" | sed -n 1p | cut -d= -f1)" "RUN_TL4"
check "line order: GATE_RC second" "$(printf '%s\n' "$out" | sed -n 2p | cut -d= -f1)" "GATE_RC"
check "line order: CATEGORY third" "$(printf '%s\n' "$out" | sed -n 3p | cut -d: -f1)" "CATEGORY"
check "line order: PREFLIGHT_REASON last" "$(printf '%s\n' "$out" | grep -v '^RC=' | tail -n 1 | cut -d= -f1)" "PREFLIGHT_REASON"
git -C "$RP_REPO" rm -q --cached skills/demo/SKILL.md
rm -rf "$RP_REPO/skills"
case_end

case_begin "preflight: RUN_TL4 unset, unrecognized, and unreadable" "bin/confirm-off"
out="$(pf --session pf-direct --repo "$RP_REPO")"
check "unset RUN_TL4 defaults to OFF" "$(field "$out" RUN_TL4)" "OFF"
out="$(RUN_TL4=maybe pf --session pf-direct --repo "$RP_REPO")"
check "unrecognized RUN_TL4 fails safe to ON" "$(field "$out" RUN_TL4)" "ON"
# preflight.sh finds bin/confirm-off -> bin/get-config-var from its own path, so the unreadable
# case runs a checkout copy with get-config-var removed.
# shellcheck source=../../lib/script-checkout-fixture.sh
source "$_HELPERS_SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
script_checkout_fixture_copy "$RP_TMP/co" bin hooks skills/get-release-approval || fail "fixture" "checkout copy failed"
rm -f "$RP_TMP/co/bin/get-config-var"
out="$(PREFLIGHT_SH="$RP_TMP/co/skills/get-release-approval/scripts/preflight.sh" RUN_TL4=off pf --session pf-direct --repo "$RP_REPO")"
check "unreadable config: RUN_TL4=ERROR" "$(field "$out" RUN_TL4)" "ERROR"
check "unreadable config: still exit 0" "$(field "$out" RC)" "0"
check "unreadable config: PREFLIGHT still printed" "$(field "$out" PREFLIGHT)" "ok"
case_end

case_begin "preflight: usage errors exit 1 without a PREFLIGHT line" "skills/get-release-approval/scripts/preflight.sh"
out="$(pf --repo "$RP_REPO")"
check "no --session: exit 1" "$(field "$out" RC)" "1"
check_not_contains "no --session: no PREFLIGHT" "$out" "PREFLIGHT="
check_contains "no --session: usage line" "$(cat "$RP_TMP/pf.err")" "Usage: preflight.sh --session"
out="$(pf --session pf-direct --bogus)"
check "unknown argument: exit 1" "$(field "$out" RC)" "1"
check_contains "unknown argument: diagnostic" "$(cat "$RP_TMP/pf.err")" "unknown argument --bogus"
out="$(pf --session)"
check_not_contains "--session without value: no PREFLIGHT" "$out" "PREFLIGHT="
check_not_contains "--session without value: nonzero exit" "$(field "$out" RC)" "0"
case_end

# The real route CLI always prints a known route, so a checkout copy swaps in a stub driven by
# FAKE_ROUTE_MODE: fail (exit 1, no stdout), empty (exit 0, no stdout), else the line to print.
script_checkout_fixture_copy "$RP_TMP/co-route" bin hooks skills/get-release-approval || fail "fixture" "route checkout copy failed"
printf '%s\n' '"use strict";' 'const m = process.env.FAKE_ROUTE_MODE || "";' \
  'if (m === "fail") { process.stderr.write("stub route failure\n"); process.exit(1); }' \
  'if (m !== "empty") process.stdout.write(m + "\n");' > "$RP_TMP/co-route/bin/session-close-detect-route.js"
# Rows: <name> | <FAKE_ROUTE_MODE> | <PREFLIGHT> | <PR_NUMBER> | <reason fragment> | <forge called: yes|no>
case_begin "preflight: only direct / wf-meta skip the PR check; an unresolved route is blocked" "skills/get-release-approval/scripts/preflight.sh"
use_origin "$GH_URL"
while IFS='|' read -r name mode want num reason forge; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; mode="${mode//[[:space:]]/}"; want="${want//[[:space:]]/}"
  num="${num//[[:space:]]/}"; forge="${forge//[[:space:]]/}"
  reason="${reason#"${reason%%[![:space:]]*}"}"; reason="${reason%"${reason##*[![:space:]]}"}"
  : > "$RP_TMP/forge.log"
  out="$(PREFLIGHT_SH="$RP_TMP/co-route/skills/get-release-approval/scripts/preflight.sh" FAKE_ROUTE_MODE="$mode" RUN_TL4=off FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf --session pf-pr --repo "$RP_REPO")"
  check "$name: exit 0" "$(field "$out" RC)" "0"
  check "$name: PREFLIGHT" "$(field "$out" PREFLIGHT)" "$want"
  check "$name: PR_NUMBER" "$(field "$out" PR_NUMBER)" "$num"
  check_contains "$name: reason" "$(field "$out" PREFLIGHT_REASON)" "$reason"
  if [[ "$forge" == "yes" ]]; then
    check_contains "$name: PR checked" "$(cat "$RP_TMP/forge.log")" "|gh pr view"
  else
    check "$name: no forge CLI called" "$(grep -c . "$RP_TMP/forge.log")" "0"
  fi
done <<'TABLE'
route-cli-fails     | fail               | blocked | | delivery path could not be resolved | no
route-cli-empty     | empty              | blocked | | delivery path could not be resolved | no
route-unknown-value | ROUTE=bogus        | blocked | | delivery path could not be resolved | no
route-empty-value   | ROUTE=             | blocked | | delivery path could not be resolved | no
route-not-a-route   | garbage            | blocked | | delivery path could not be resolved | no
route-direct        | ROUTE=direct       | ok      | | delivery path direct                | no
route-wf-meta       | ROUTE=wf-meta      | ok      | | delivery path wf-meta               | no
route-pull-request  | ROUTE=pull_request | ok      | 42 | PR #42 is open and mergeable (CLEAN) | yes
TABLE
case_end

mk_state '{"sid":"pf-bs","path":"pull_request","steps":"push_branch=complete","annotate":"push_branch.decision=bootstrap"}'
mk_state '{"sid":"pf-pb-plain","path":"pull_request","steps":"push_branch=complete"}'
mk_state '{"sid":"pf-pb-other","path":"pull_request","steps":"push_branch=complete","annotate":"push_branch.decision=bootstrap-later"}'
# Rows: <name> | <sid> | <origin> | <FAKE_FORGE_STATE> | <PREFLIGHT> | <PR_NUMBER> | <reason fragment> | <forge called: yes|no>
case_begin "preflight: push_branch decision=bootstrap skips the PR check; anything else falls through" "skills/get-release-approval/scripts/preflight.sh"
while IFS='|' read -r name sid origin st want num reason forge; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; sid="${sid//[[:space:]]/}"; origin="${origin//[[:space:]]/}"; st="${st//[[:space:]]/}"
  want="${want//[[:space:]]/}"; num="${num//[[:space:]]/}"; forge="${forge//[[:space:]]/}"
  reason="${reason#"${reason%%[![:space:]]*}"}"; reason="${reason%"${reason##*[![:space:]]}"}"
  if [[ "$origin" == "gitlab" ]]; then use_origin "$GL_URL"; else use_origin "$GH_URL"; fi
  : > "$RP_TMP/forge.log"
  out="$(RUN_TL4=off FAKE_FORGE_STATE="$st" FAKE_FORGE_MERGE=CLEAN pf --session "$sid" --repo "$RP_REPO")"
  check "$name: exit 0" "$(field "$out" RC)" "0"
  check "$name: PREFLIGHT" "$(field "$out" PREFLIGHT)" "$want"
  check "$name: PR_NUMBER" "$(field "$out" PR_NUMBER)" "$num"
  check_contains "$name: reason" "$(field "$out" PREFLIGHT_REASON)" "$reason"
  if [[ "$forge" == "yes" ]]; then
    check_contains "$name: PR checked" "$(cat "$RP_TMP/forge.log")" "pr view"
  else
    check "$name: no forge CLI called" "$(grep -c . "$RP_TMP/forge.log")" "0"
  fi
done <<'TABLE'
bootstrap-gh-no-pr     | pf-bs       | github | NONE | ok      |    | bootstrap push to an empty remote      | no
bootstrap-gh-open-pr   | pf-bs       | github | OPEN | ok      |    | bootstrap push to an empty remote      | no
bootstrap-gl-no-mr     | pf-bs       | gitlab | NONE | ok      |    | bootstrap push to an empty remote      | no
plain-push-no-pr       | pf-pb-plain | github | NONE | blocked |    | no pull request for the current branch | yes
plain-push-open-pr     | pf-pb-plain | github | OPEN | ok      | 42 | PR #42 is open and mergeable (CLEAN)   | yes
other-decision-no-pr   | pf-pb-other | github | NONE | blocked |    | no pull request for the current branch | yes
other-decision-open-pr | pf-pb-other | github | OPEN | ok      | 42 | PR #42 is open and mergeable (CLEAN)   | yes
TABLE
case_end

# 4-5 web-merge channel: pull_request + AUTO_MERGE_PR=off fixed at branching, push_branch complete.
mk_state '{"sid":"pf-wm","path":"pull_request","autoMerge":"off","steps":"push_branch=complete"}'
mk_state '{"sid":"pf-dlg","path":"pull_request","autoMerge":"on","steps":"push_branch=complete"}'
# Rows: <name> | <origin> | <state> | <gh merge / glab status> | <glab draft> | <PREFLIGHT> | <reason fragment>
case_begin "preflight: web-merge channel verdicts (github and gitlab)" "skills/get-release-approval/scripts/preflight.sh"
while IFS='|' read -r name origin st merge draft want reason; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; origin="${origin//[[:space:]]/}"; st="${st//[[:space:]]/}"
  merge="${merge//[[:space:]]/}"; draft="${draft//[[:space:]]/}"; want="${want//[[:space:]]/}"
  reason="${reason#"${reason%%[![:space:]]*}"}"; reason="${reason%"${reason##*[![:space:]]}"}"
  if [[ "$origin" == "gitlab" ]]; then use_origin "$GL_URL"; else use_origin "$GH_URL"; fi
  out="$(RUN_TL4=off FAKE_FORGE_STATE="$st" FAKE_FORGE_MERGE="$merge" FAKE_GLAB_MERGE="$merge" FAKE_GLAB_DRAFT="$draft" pf --session pf-wm --repo "$RP_REPO")"
  check "$name: exit 0" "$(field "$out" RC)" "0"
  check "$name: PREFLIGHT" "$(field "$out" PREFLIGHT)" "$want"
  check "$name: RUN_TL4 still the first line" "$(printf '%s\n' "$out" | sed -n 1p | cut -d= -f1)" "RUN_TL4"
  [ -n "$reason" ] && check_contains "$name: reason" "$(field "$out" PREFLIGHT_REASON)" "$reason"
  if [[ "$want" == "web_merge_pending" ]]; then
    if [[ "$origin" == "gitlab" ]]; then want_url="https://gitlab.com/example/repo/-/merge_requests/42"
    else want_url="https://github.com/example/repo/pull/42"; fi
    check "$name: PR_URL line" "$(field "$out" PR_URL)" "$want_url"
  fi
done <<'TABLE'
wm-gh-clean     | github | OPEN   | CLEAN    | 0 | web_merge_pending |
wm-gh-behind    | github | OPEN   | BEHIND   | 0 | web_merge_blocked | BEHIND the base branch
wm-gh-dirty     | github | OPEN   | DIRTY    | 0 | web_merge_blocked | merge conflicts (DIRTY)
wm-gh-blocked   | github | OPEN   | BLOCKED  | 0 | web_merge_blocked | is BLOCKED — wait for required checks
wm-gh-unstable  | github | OPEN   | UNSTABLE | 0 | web_merge_blocked | is UNSTABLE — wait for required checks
wm-gh-draft     | github | OPEN   | DRAFT    | 0 | web_merge_blocked | is a draft
wm-gh-none      | github | NONE   | CLEAN    | 0 | web_merge_blocked | no pull request for the current branch
wm-gh-merged    | github | MERGED | UNKNOWN  | 0 | web_merge_done    |
wm-gh-closed    | github | CLOSED | CLEAN    | 0 | web_merge_closed  |
wm-gl-clean     | gitlab | OPEN   | mergeable        | 0 | web_merge_pending |
wm-gl-conflict  | gitlab | OPEN   | conflict         | 0 | web_merge_blocked | merge conflicts (DIRTY)
wm-gl-rebase    | gitlab | OPEN   | need_rebase      | 0 | web_merge_blocked | BEHIND the base branch
wm-gl-ci        | gitlab | OPEN   | ci_still_running | 0 | web_merge_blocked | is BLOCKED — wait for required checks
wm-gl-draft     | gitlab | OPEN   | mergeable        | 1 | web_merge_blocked | is a draft
wm-gl-checking  | gitlab | OPEN   | checking         | 0 | web_merge_blocked | mergeability is CHECKING — wait for the forge
wm-gl-merged    | gitlab | MERGED | mergeable        | 0 | web_merge_done   |
wm-gl-closed    | gitlab | CLOSED | mergeable        | 0 | web_merge_closed |
TABLE
use_origin "$GH_URL"
case_end

case_begin "preflight: AUTO_MERGE_PR=on keeps the dialog verdicts (regression)" "skills/get-release-approval/scripts/preflight.sh"
use_origin "$GH_URL"
out="$(RUN_TL4=off FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=CLEAN pf --session pf-dlg --repo "$RP_REPO")"
check "dialog CLEAN: PREFLIGHT ok" "$(field "$out" PREFLIGHT)" "ok"
check_contains "dialog CLEAN: reason" "$(field "$out" PREFLIGHT_REASON)" "PR #42 is open and mergeable (CLEAN)"
out="$(RUN_TL4=off FAKE_FORGE_STATE=MERGED pf --session pf-dlg --repo "$RP_REPO")"
check "dialog MERGED: merged_on_web" "$(field "$out" PREFLIGHT)" "merged_on_web"
out="$(RUN_TL4=off FAKE_FORGE_STATE=CLOSED pf --session pf-dlg --repo "$RP_REPO")"
check "dialog CLOSED: blocked" "$(field "$out" PREFLIGHT)" "blocked"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
