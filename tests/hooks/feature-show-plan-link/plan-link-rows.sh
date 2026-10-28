# #2513 plan-link rows (R1-R9): what the real hook prints per record state, the record-before-sync
# order, and the hook-input cwd rule. Sourced by ../feature-show-plan-link.sh right after
# plan-sync-breadcrumb.sh: inherits pass/fail, the psf_setup root, PSF_PROJECT and the sps_* helpers.
# Each plan file is named <sid>-<stage>.md with session_id = <sid>.

SPR_BARE="$PSF_ROOT/pr-bare.git"
SPR="$PSF_ROOT/pr-plans"
SPR_BLOB="https://github.com/test-owner/test-repo/blob/main"
SPR_GL_PROJ="$PSF_ROOT/pr-gl-proj"

# spr_run <rel> <sid> [cwd] — Write hook run against $SPR; an empty sid / cwd leaves the field out.
spr_run() {
  WORKFLOW_PLANS_DIR="$SPR" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(psf_write_json "$SPR/$1" "$2" "${3:-}")"
}

spr_bare_show() { git -C "$SPR_BARE" show "refs/heads/main:$1" 2>/dev/null; }

# spr_expect_reason_line <name> <reason> <plans-dir> <shown|none> — one additionalContext line holds
# the reason and the local path and no URL; the systemMessage is present (shown) or absent (none).
spr_expect_reason_line() {
  local name="$1" line
  line="$(sps_ctx_line "$2")"
  if [ "$HOOK_EVT" != PostToolUse ] || [ -z "$line" ]; then
    fail "$name — want PostToolUse ctx line with $2 — evt=$(printf '%q' "$HOOK_EVT") ctx=$(printf '%q' "$HOOK_CTX")"
  elif ! sps_has_dir "$line" "$3"; then
    fail "$name — the $2 line lacks the local path — ctx=$(printf '%q' "$HOOK_CTX")"
  elif [[ "$line" == *https://* ]]; then
    fail "$name — the $2 line must not carry a URL — line=$(printf '%q' "$line")"
  elif [ "$4" = none ] && [ -n "$HOOK_MSG" ]; then
    fail "$name — no systemMessage expected — msg=$(printf '%q' "$HOOK_MSG")"
  elif [ "$4" = shown ] && [ -z "$HOOK_MSG" ]; then
    fail "$name — a systemMessage is expected"
  else
    pass "$name"
  fi
}

# spr_expect_record <name> <plans-dir> <rel> <dest-url> <want> — readProjectHostState verdict.
spr_expect_record() {
  local got
  got="$(psf_record_state "$2" "$3" "$4")"
  if [ "$got" = "$5" ]; then pass "$1"; else fail "$1 — record state=$got want=$5"; fi
}

# spr_expect_not_sent <name> <rel> — the destination holds no <rel>.
spr_expect_not_sent() {
  local got
  if got="$(spr_bare_show "$2")"; then fail "$1 — destination holds $2: $(printf '%q' "$got")"
  else pass "$1"; fi
}

if psf_make_bare "$SPR_BARE" && psf_make_provisioned "$SPR" "$PSF_ORIGIN_E2E" >/dev/null 2>&1 \
  && psf_make_project "$SPR_GL_PROJ" "$PSF_ORIGIN_GL" >/dev/null 2>&1; then
  SPR_GL_PROJ="$(psf_np "$SPR_GL_PROJ")"
  setup_ssh_stub "$SPR_BARE"

  echo "=== R1: match and sent -> URL + local path on one line, no systemMessage ==="
  printf 'r1 body\n' > "$SPR/sprok-intent.md"
  spr_run sprok-intent.md sprok "$PSF_PROJECT"
  sps_expect_ctx_url "R1 match: additionalContext line carries the URL and the local path" "$SPR_BLOB/sprok-intent.md" "$SPR"
  spr_expect_record "R1 match: record matches the destination host" "$SPR" sprok-intent.md "$PSF_ORIGIN_E2E" match
  if [ "$(spr_bare_show sprok-intent.md)" = "r1 body" ]; then pass "R1 match: destination holds the plan"
  else fail "R1 match: destination holds the plan — got=$(printf '%q' "$(spr_bare_show sprok-intent.md)")"; fi
  case "$HOOK_CTX" in
    "") fail "R1 model context no longer forbids a local path — no additionalContext" ;;
    *[Nn]"ever show a local"*) fail "R1 model context no longer forbids a local path — ctx=$(printf '%q' "$HOOK_CTX")" ;;
    *) pass "R1 model context no longer forbids a local path" ;;
  esac

  echo "=== R2: cwd in a project on another host -> host-mismatch, nothing sent, no systemMessage ==="
  printf 'r2 body\n' > "$SPR/sprmis-outline.md"
  spr_run sprmis-outline.md sprmis "$SPR_GL_PROJ"
  spr_expect_reason_line "R2 host-mismatch: local path + reason, no systemMessage" host-mismatch "$SPR" none
  spr_expect_record "R2 host-mismatch: record holds the cwd project's host" "$SPR" sprmis-outline.md "$PSF_ORIGIN_E2E" host-mismatch
  spr_expect_not_sent "R2 host-mismatch: nothing sent" sprmis-outline.md

  echo "=== R3: no cwd in the hook input -> no-project-host, even with a matching CLAUDE_PROJECT_DIR and process cwd ==="
  SPR_OLD_PWD="$PWD"
  cd "$PSF_PROJECT" || fail "R3 cd into the project"
  if [ "$(git remote get-url origin 2>/dev/null)" = "$PSF_ORIGIN_GH" ]; then pass "R3 precondition: the hook process cwd is a matching project"
  else fail "R3 precondition: the hook process cwd is a matching project — pwd=$PWD"; fi
  printf 'r3 body\n' > "$SPR/sprnoc-detail.md"
  SPS_PROJECT_DIR="$PSF_PROJECT" spr_run sprnoc-detail.md sprnoc
  cd "$SPR_OLD_PWD" || fail "R3 cd back"
  spr_expect_reason_line "R3 no cwd: local path + no-project-host, no systemMessage" no-project-host "$SPR" none
  spr_expect_record "R3 no cwd: record says no host" "$SPR" sprnoc-detail.md "$PSF_ORIGIN_E2E" no-project-host
  spr_expect_not_sent "R3 no cwd: nothing sent" sprnoc-detail.md

  echo "=== R4: record cannot be written, plan identical at the destination -> URL + local path, systemMessage shown ==="
  printf 'r4 v1\n' > "$SPR/sprblk-intent.md"
  spr_run sprblk-intent.md sprblk "$PSF_PROJECT"
  if [ "$(spr_bare_show sprblk-intent.md)" = "r4 v1" ]; then pass "R4 precondition: the plan is at the destination"
  else fail "R4 precondition: the plan is at the destination — got=$(printf '%q' "$(spr_bare_show sprblk-intent.md)")"; fi
  psf_record_block "$SPR" sprblk-intent.md
  spr_run sprblk-intent.md sprblk "$PSF_PROJECT"
  SPR_LINE="$(sps_ctx_line "$SPR_BLOB/sprblk-intent.md")"
  if [ -n "$SPR_LINE" ] && sps_has_dir "$SPR_LINE" "$SPR"; then pass "R4 no record, identical: line carries the URL and the local path"
  else fail "R4 no record, identical: line carries the URL and the local path — ctx=$(printf '%q' "$HOOK_CTX")"; fi
  sps_expect_msg_has "R4 no record, identical: systemMessage reports the record failure" "Plan file: " "[plan-sync] internal-error"

  echo "=== R5: record cannot be written -> the changed plan is not sent, no host record is left ==="
  printf 'r4 v2\n' > "$SPR/sprblk-intent.md"
  spr_run sprblk-intent.md sprblk "$PSF_PROJECT"
  SPR_GOT="$(spr_bare_show sprblk-intent.md)"
  SPR_REC="$(psf_record_state "$SPR" sprblk-intent.md "$PSF_ORIGIN_E2E")"
  if [ "$SPR_GOT" = "r4 v1" ] && [ "$SPR_REC" != match ] && [ "${SPR_REC#NOT_IMPLEMENTED}" = "$SPR_REC" ]; then
    pass "R5 record write failed: destination unchanged, no host record"
  else
    fail "R5 record write failed: destination unchanged, no host record — destination=$(printf '%q' "$SPR_GOT") record=$SPR_REC"
  fi
  spr_expect_reason_line "R5 no record, content differs: local path + not-published, systemMessage shown" not-published "$SPR" shown
  sps_expect_msg_has "R5 systemMessage reports the record failure" "Plan file: " "sprblk-intent.md" "[plan-sync] internal-error"

  echo "=== R6: record cannot be written, plan never sent -> local path + not-published, systemMessage shown ==="
  printf 'r6 body\n' > "$SPR/sprabs-detail.md"
  psf_record_block "$SPR" sprabs-detail.md
  spr_run sprabs-detail.md sprabs "$PSF_PROJECT"
  spr_expect_not_sent "R6 no record, absent: nothing sent" sprabs-detail.md
  spr_expect_reason_line "R6 no record, absent: local path + not-published, systemMessage shown" not-published "$SPR" shown

  echo "=== R7: no session id and no record -> the line still carries the local path ==="
  printf 'r7 body\n' > "$SPR/sprnos-outline.md"
  psf_record_block "$SPR" sprnos-outline.md
  spr_run sprnos-outline.md "" "$PSF_PROJECT"
  SPR_LINE="$(sps_ctx_line "sprnos-outline.md")"
  if [ "$HOOK_EVT" = PostToolUse ] && [ -n "$HOOK_MSG" ] && sps_has_dir "$SPR_LINE" "$SPR"; then
    pass "R7 resolution impossible: local path kept, systemMessage shown"
  else
    fail "R7 resolution impossible: local path kept, systemMessage shown — ctx=$(printf '%q' "$HOOK_CTX") msg=$(printf '%q' "$HOOK_MSG")"
  fi
  spr_expect_not_sent "R7 resolution impossible: nothing sent" sprnos-outline.md

  echo "=== R8: hard-linked plan (not a regular file) -> reason only, no local path in the model context ==="
  mkdir -p "$PSF_ROOT/pr-outside"; printf 'r8 outside\n' > "$PSF_ROOT/pr-outside/linked.txt"
  if psf_timeout 30 node -e '
const fs = require("fs");
try { fs.linkSync(process.argv[1], process.argv[2]); } catch (e) { process.exit(1); }
process.exit(fs.lstatSync(process.argv[2]).nlink >= 2 ? 0 : 1);' \
    "$PSF_ROOT/pr-outside/linked.txt" "$SPR/sprnrf-detail.md" 2>/dev/null; then
    spr_run sprnrf-detail.md sprnrf "$PSF_PROJECT"
    sps_expect_msg_has "R8 precondition: the sync result is skipped / not a regular file" "$SPS_NRF_LINE"
    SPR_LEAK="$(psf_path_leak "$HOOK_CTX" "$SPR")"
    if [ "$HOOK_EVT" = PostToolUse ] && [[ "$HOOK_CTX" == *detail* ]] && [ -z "$SPR_LEAK" ]; then
      pass "R8 not a regular file: model context names the stage without a local path"
    else
      fail "R8 not a regular file: model context names the stage without a local path — leak=$SPR_LEAK ctx=$(printf '%q' "$HOOK_CTX")"
    fi
  else
    echo "SKIP: R8 host cannot create hard links (or does not report nlink)"
  fi
  unset GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_SSH_STUB_BARE GIT_SSH_STUB_LOG
else
  fail "R1-R8 fixture — bare / provisioned repo / gitlab-origin project failed"
fi

echo "=== R9: the record is written before the push is attempted (unreachable destination) ==="
if [ -d "$SPS_PD/.git" ] && [ -d "$SPS_DEAD_PROJ/.git" ]; then
  printf 'r9 body\n' > "$SPS_PD/sprdead-outline.md"
  WORKFLOW_PLANS_DIR="$SPS_PD" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_DEAD" psf_with_ssh_offline \
    sps_run_hook "$(psf_write_json "$SPS_PD/sprdead-outline.md" sprdead "$(psf_np "$SPS_DEAD_PROJ")")"
  spr_expect_record "R9 push failed: the record already matches the destination host" "$SPS_PD" sprdead-outline.md "$PSF_ORIGIN_DEAD" match
  sps_expect_msg_has "R9 push failed: systemMessage reports the failure" "Plan file: " "sprdead-outline.md" "[plan-sync] " "$SPS_RUN_HINT"
  spr_expect_reason_line "R9 push failed: local path + not-published, systemMessage shown" not-published "$SPS_PD" shown
else
  fail "R9 fixture — the H5 provisioned repo / dead-origin project is missing"
fi
