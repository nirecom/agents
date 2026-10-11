# Tests: hooks/show-plan-link.js
# Tags: plan-sync, e2e, ssh-stub, show-plan-link, project-host, scope:issue-specific
# shellcheck shell=bash
# Sourced by tests/hooks/feature-2513-plan-sync-e2e.sh after its E3 case: $PLANS is provisioned,
# $BARE main already holds the earlier pushes, and hook_run / expect_has / ctx_has_plan_path exist.
# The project is decided from the hook input cwd alone: CLAUDE_PROJECT_DIR stays pinned to the
# github.com project in every run below, so a hook that falls back to it would wrongly send.

# not_sent_case <tag> <plan-file> <reason word> <cwd or ""> <project-dir|->
# The record verdict (psf_record_state against the plans remote) must equal <reason word>.
not_sent_case() {
  local tag="$1" f="$2" reason="$3" before after tree state
  printf 'stays local\n' > "$PLANS/$f"
  before="$(git -C "$BARE" rev-parse --verify -q refs/heads/main)"
  hook_run "$SPL" "$(psf_write_json "$PLANS/$f" "${f%-*}" "$4")" "$PLANS" "$5"
  after="$(git -C "$BARE" rev-parse --verify -q refs/heads/main)"
  tree="$(git -C "$BARE" ls-tree -r --name-only refs/heads/main 2>/dev/null | tr '\n' ' ')"
  if [ -n "$before" ] && [ "$before" = "$after" ]; then pass "$tag bare main unchanged"
  else fail "$tag bare main unchanged" "before=$before after=$after"; fi
  case " $tree" in
    *" $f "*) fail "$tag plan absent from the bare repo" "tree=$tree" ;;
    *" s2513e2e-intent.md "*) pass "$tag plan absent from the bare repo" ;;
    *) fail "$tag plan absent from the bare repo" "bare tree lost the earlier pushes: $tree" ;;
  esac
  state="$(psf_record_state "$PLANS" "$f" "$PSF_ORIGIN_E2E")"
  if [ "$state" = "$reason" ]; then pass "$tag record verdict is $reason"
  else fail "$tag record verdict is $reason" "state=$state"; fi
  expect_has "$tag additionalContext names $reason" "$H_CTX" "$reason"
  if ctx_has_plan_path "$PLANS" "$f"; then pass "$tag additionalContext carries the local path"
  else fail "$tag additionalContext carries the local path" "ctx=$(printf '%q' "$H_CTX")"; fi
  case "$H_CTX$H_MSG" in
    *"/blob/"*) fail "$tag no blob URL shown" "ctx=$(printf '%q' "$H_CTX") msg=$(printf '%q' "$H_MSG")" ;;
    *) if [ "$H_EVT" = PostToolUse ]; then pass "$tag no blob URL shown"
       else fail "$tag no blob URL shown" "hook emitted no PostToolUse output"; fi ;;
  esac
  if [ -z "$H_MSG" ]; then pass "$tag no systemMessage (a skip is not a failure, D2)"
  else fail "$tag no systemMessage (a skip is not a failure, D2)" "msg=$(printf '%q' "$H_MSG")"; fi
}

case_begin "other-host-project-not-sent" "hooks/show-plan-link.js"
psf_make_project "$PSF_ROOT/proj-gl" "$PSF_ORIGIN_GL" || fail "E4 setup" "psf_make_project failed"
not_sent_case "E4 cwd in a gitlab.com project:" s2513e2egl-intent.md host-mismatch "$(psf_np "$PSF_ROOT/proj-gl")" "$PSF_PROJECT"
case_end

case_begin "no-cwd-not-sent" "hooks/show-plan-link.js"
not_sent_case "E5 no cwd in the hook input:" s2513e2enocwd-intent.md no-project-host "" "$PSF_PROJECT"
case_end

case_begin "later-matching-write-still-sent" "hooks/show-plan-link.js"
printf 'e2e detail\n' > "$PLANS/s2513e2e-detail.md"
hook_run "$SPL" "$(psf_write_json "$PLANS/s2513e2e-detail.md" test-sid-e2e "$PSF_PROJECT")"
expect_ctx_url "E6 a matching project still gets the blob URL afterwards" PostToolUse "$BLOB/s2513e2e-detail.md" "$PLANS"
E6_TREE=" $(git -C "$BARE" ls-tree -r --name-only refs/heads/main 2>/dev/null | tr '\n' ' ')"
expect_has "E6 bare repo holds the matching plan" "$E6_TREE" " s2513e2e-detail.md "
case "$E6_TREE" in
  *" s2513e2egl-intent.md "*|*" s2513e2enocwd-intent.md "*) fail "E6 the unsent plans did not ride along" "tree=$E6_TREE" ;;
  *" s2513e2e-detail.md "*) pass "E6 the unsent plans did not ride along" ;;
  *) fail "E6 the unsent plans did not ride along" "the matching plan was not pushed: $E6_TREE" ;;
esac
case_end
