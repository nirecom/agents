# The record of the project's host, written by hooks/show-plan-link.js when a plan is written:
# <session id>-note-project-host-<stage>.json next to the plan. Sourced by
# ../feature-2513-plan-sync-send-selection.sh inside its case block, before plan-sync-flow.sh.
# The destination is GitHub ($PSF_ORIGIN_E2E, served by the ssh stub), so "sent" is read off
# the bare repo. The project is decided from the hook input's cwd alone: every run also gets
# a decoy project (as CLAUDE_PROJECT_DIR and as the process cwd, or as the cwd saved in the
# session state) whose host gives the opposite verdict.
# The record format is the library's own: a record is judged only through
# readProjectHostState (psf_record_state), never parsed here.

PH="$PSF_ROOT/ph-plans"
PH_BARE="$PSF_ROOT/ph-bare.git"
psf_make_bare "$PH_BARE"
setup_ssh_stub "$PH_BARE"
export PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E"

PH_GH="$PSF_ROOT/ph-github"; psf_make_project "$PH_GH" "$PSF_ORIGIN_GH"
PH_GL="$PSF_ROOT/ph-gitlab"; psf_make_project "$PH_GL" "$PSF_ORIGIN_GL"
PH_GLS="$PSF_ROOT/ph-gitlab-self"; psf_make_project "$PH_GLS" "$PSF_ORIGIN_GL_SELF"
PH_BARE_PROJECT="$PSF_ROOT/ph-no-origin"; psf_make_project "$PH_BARE_PROJECT"
PH_ALT="$PSF_ROOT/ph-github-alt"; psf_make_project "$PH_ALT" "ssh://git@ssh.github.com:443/test-owner/other-repo.git"
PH_WT="$PSF_ROOT/ph-wt"; psf_add_worktree "$PH_GH" "$PH_WT"
PH_SUB="$PH_GH/sub/dir"; mkdir -p "$PH_SUB"
PH_ONLY="$PSF_ROOT/ph-wtcfg-only"; psf_make_project "$PH_ONLY"
PH_ONLY_WT="$PSF_ROOT/ph-wtcfg-only-wt"
psf_add_worktree_origin "$PH_ONLY" "$PH_ONLY_WT" only "$PSF_ORIGIN_GL" "$PSF_ORIGIN_GH"
PH_EXTRA="$PSF_ROOT/ph-wtcfg-extra"; psf_make_project "$PH_EXTRA" "$PSF_ORIGIN_GH"
PH_EXTRA_WT="$PSF_ROOT/ph-wtcfg-extra-wt"
psf_add_worktree_origin "$PH_EXTRA" "$PH_EXTRA_WT" extra "$PSF_ORIGIN_GL"
PH_SAME="$PSF_ROOT/ph-two-urls"; psf_make_project "$PH_SAME" "$PSF_ORIGIN_GH"
PH_SAME_WT="$PSF_ROOT/ph-two-urls-wt"
psf_add_worktree_origin "$PH_SAME" "$PH_SAME_WT" extra "https://github.com/test-owner/other-repo.git"
# insteadOf: the host is the one git resolves the origin to, not the one written in the config.
PH_TO_GH="$PSF_ROOT/ph-rewritten-to-github"; psf_make_project "$PH_TO_GH" "gh:test-owner/test-repo.git"
git -C "$PH_TO_GH" config "url.git@github.com:.insteadOf" "gh:"
PH_TO_GL="$PSF_ROOT/ph-rewritten-to-gitlab"; psf_make_project "$PH_TO_GL" "$PSF_ORIGIN_GH"
git -C "$PH_TO_GL" config "url.git@gitlab.com:.insteadOf" "git@github.com:"

# ph_write <sid> <cwd|-|""|null> <decoy-project|-> [content] — writes $PH/<sid>-intent.md, then
# runs the hook on it with <cwd> as the hook input's cwd ("-" = no cwd field; '""' and null =
# that JSON value as the cwd). Sets PH_OUT.
# Decoy "-": CLAUDE_PROJECT_DIR unset and the process cwd outside git.
ph_write() {
  local rel="$1-intent.md" cwd="" cwd_json="" at="$3"
  case "$2" in
    -) ;;
    '""'|null) cwd_json="$2" ;;
    *) cwd="$(psf_np "$2")" ;;
  esac
  [ "$3" = "-" ] && at="$PSF_ROOT/neutral"
  printf '%s\n' "${4:-plan $1}" > "$PH/$rel"
  PH_OUT="$(export WORKFLOW_PLANS_DIR="$PH"; cd "$at" || exit 1
    psf_hook "$3" show-plan-link.js "$(psf_write_json "$(psf_np "$PH/$rel")" "$1" "$cwd" "$cwd_json")" 2>/dev/null)"
}

# ph_remote <sid> — the content of <sid>-intent.md at the destination, or "absent".
ph_remote() { git -C "$PH_BARE" show "refs/heads/main:$1-intent.md" 2>/dev/null || printf 'absent'; }
ph_tip() { git -C "$PH_BARE" rev-parse --verify -q refs/heads/main || printf 'missing'; }

# ph_host_check <label> <rel> <github.com|other host|none> — the record's verdict against the
# destination, and (for a host) against a URL on that host, so the recorded host is pinned
# without reading the record format.
ph_host_check() {
  local label="$1" rel="$2" host="$3" want_dest
  case "$host" in
    none) want_dest="no-project-host" ;;
    github.com) want_dest="match" ;;
    *) want_dest="host-mismatch" ;;
  esac
  expect_eq "$label: record vs the destination" "$(psf_record_state "$PH" "$rel" "$PSF_ORIGIN_E2E")" "$want_dest"
  [ "$host" = none ] && return
  expect_eq "$label: record names $host" \
    "$(psf_record_state "$PH" "$rel" "ssh://git@$host/test-owner/test-repo.git")" "match"
}

# ph_saved_cwd_fallback <sid> — what resolveRepoCwd answers when only the cwd saved in <sid>'s
# session state is known (no CLAUDE_PROJECT_DIR, no hook-input cwd).
ph_saved_cwd_fallback() {
  env -u CLAUDE_PROJECT_DIR bash "$PSF_AGENTS_DIR/bin/run-with-timeout.sh" 30 node -e '
const ws = require(process.argv[1]); const pn = require(process.argv[2]);
const st = ws.readState(process.argv[3]) || {};
process.stdout.write(String(pn.resolveRepoCwd({ input: {}, stateCwd: st.cwd })).replace(/\\/g, "/"));' \
    "$(psf_np "$PSF_AGENTS_DIR/hooks/workflow-state.js")" "$(psf_np "$PSF_AGENTS_DIR/hooks/lib/path-normalize.js")" "$1"
}

# ph_saved_cwd_write <name> <sid> <cwd|-> <saved-project> <want-host> <reason word|sent> — one
# write whose only decoy is <saved-project>, the cwd saved in <sid>'s session state.
ph_saved_cwd_write() {
  local name="$1" sid="$2" before ctx
  psf_save_session_cwd "$sid" "$4"
  expect_eq "$name precondition: resolveRepoCwd would answer the saved cwd" \
    "$(ph_saved_cwd_fallback "$sid" | tr '[:upper:]' '[:lower:]')" "$(psf_np "$4" | tr '[:upper:]' '[:lower:]')"
  before="$(ph_tip)"
  ph_write "$sid" "$3" -
  ctx="$(psf_hso "$PH_OUT" additionalContext)"
  ph_host_check "$name" "$sid-intent.md" "$5"
  if [ "$6" = sent ]; then
    expect_eq "$name: at the destination" "$(ph_remote "$sid")" "plan $sid"
    case "$ctx" in
      *"/blob/main/$sid-intent.md"*) pass "$name: the hook output offers the blob URL" ;;
      *) fail "$name: the hook output offers the blob URL" "ctx=$(printf '%q' "$ctx")" ;;
    esac
    return
  fi
  expect_eq "$name: at the destination" "$(ph_remote "$sid")" "absent"
  expect_eq "$name: destination main did not move" "$(ph_tip)" "$before"
  case "$ctx" in
    *"$6"*) pass "$name: the hook output names $6" ;;
    *) fail "$name: the hook output names $6" "ctx=$(printf '%q' "$ctx")" ;;
  esac
  if [ -n "$(psf_path_leak "$ctx" "$PH")" ]; then pass "$name: the hook output carries the local path"
  else fail "$name: the hook output carries the local path" "ctx=$(printf '%q' "$ctx")"; fi
  case "$PH_OUT" in
    *"/blob/"*) fail "$name: the hook output offers no blob URL" "out=$PH_OUT" ;;
    "") fail "$name: the hook output offers no blob URL" "the hook printed nothing" ;;
    *) pass "$name: the hook output offers no blob URL" ;;
  esac
}

if ! psf_make_provisioned "$PH" "$PSF_ORIGIN_E2E" >/dev/null 2>&1; then
  fail "project-host record" "fixture: psf_make_provisioned failed"
else
  echo "=== R1: the host recorded per kind of project, and whether the plan is then sent ==="
  while IFS='|' read -r name sid cwd decoy want_host want_sent; do
    [ -z "$name" ] && continue
    ph_write "$sid" "$cwd" "$decoy"
    ph_host_check "R1 $name" "$sid-intent.md" "$want_host"
    if [ "$want_sent" = yes ]; then want="plan $sid"; else want="absent"; fi
    expect_eq "R1 $name: at the destination" "$(ph_remote "$sid")" "$want"
    expect_eq "R1 $name: the plan file stays on disk" "$(cat "$PH/$sid-intent.md" 2>&1)" "plan $sid"
  done <<TABLE
github-project|ph01|$PH_GH|$PH_GL|github.com|yes
gitlab-com-project|ph02|$PH_GL|$PH_GH|gitlab.com|no
self-hosted-gitlab-project|ph03|$PH_GLS|$PH_GH|gitlab.example.com|no
project-without-origin|ph04|$PH_BARE_PROJECT|$PH_GH|none|no
directory-outside-git|ph05|$PSF_ROOT/neutral|$PH_GH|none|no
cwd-does-not-exist|ph06|$PSF_ROOT/ph-gone|$PH_GH|none|no
no-cwd-in-hook-input|ph07|-|$PH_GH|none|no
linked-worktree-of-github-project|ph08|$PH_WT|$PH_GL|github.com|yes
subdirectory-of-github-project|ph09|$PH_SUB|$PH_GL|github.com|yes
github-ssh-alt-host-project|ph10|$PH_ALT|$PH_GL|github.com|yes
worktree-config-origin-only-linked|ph11|$PH_ONLY_WT|$PH_GH|gitlab.com|no
worktree-config-origin-only-main|ph12|$PH_ONLY|$PH_GL|github.com|yes
worktree-config-origin-extra-linked|ph13|$PH_EXTRA_WT|$PH_GH|none|no
worktree-config-origin-extra-main|ph14|$PH_EXTRA|$PH_GL|github.com|yes
two-origin-urls-on-one-host|ph15|$PH_SAME_WT|$PH_GL|github.com|yes
origin-rewritten-to-github|ph16|$PH_TO_GH|$PH_GL|github.com|yes
origin-rewritten-to-gitlab|ph17|$PH_TO_GL|$PH_GH|gitlab.com|no
TABLE

  echo "=== R2: the record is in place before the sync and follows the latest write ==="
  # A stale mismatch record must not stop a write from a matching project, and a stale match
  # record must not let a write from another project through.
  printf 'stale\n' > "$PH/ph20-intent.md"
  psf_record "$PH" ph20-intent.md gitlab.com
  ph_write ph20 "$PH_GH" "$PH_GL"
  ph_host_check "R2 stale mismatch record replaced by the matching host" ph20-intent.md github.com
  expect_eq "R2 written from the matching project: sent" "$(ph_remote ph20)" "plan ph20"
  ph_write ph20 "$PH_GL" "$PH_GH" "plan ph20 from gitlab"
  ph_host_check "R2 same plan rewritten from another project: record overwritten" ph20-intent.md gitlab.com
  expect_eq "R2 rewritten content is not sent, the earlier version stays" "$(ph_remote ph20)" "plan ph20"
  ph_write ph20 - "$PH_GH" "plan ph20 without cwd"
  ph_host_check "R2 same plan rewritten without cwd: record says no host" ph20-intent.md none
  expect_eq "R2 content written without cwd is not sent" "$(ph_remote ph20)" "plan ph20"
  # Per stage: the outline of the same session carries its own record.
  printf 'outline ph20\n' > "$PH/ph20-outline.md"
  OUT="$(export WORKFLOW_PLANS_DIR="$PH"; cd "$PH_GL" || exit 1
    psf_hook "$PH_GL" show-plan-link.js "$(psf_write_json "$(psf_np "$PH/ph20-outline.md")" ph20 "$(psf_np "$PH_GH")")" 2>/dev/null)"
  ph_host_check "R2 outline record written under its own stage" ph20-outline.md github.com
  ph_host_check "R2 intent record of the same session untouched" ph20-intent.md none
  expect_eq "R2 outline sent" "$(git -C "$PH_BARE" show refs/heads/main:ph20-outline.md 2>/dev/null || printf 'absent')" "outline ph20"

  echo "=== R3: the record cannot be written -> nothing is sent, no usable record is left ==="
  printf 'old\n' > "$PH/ph30-intent.md"
  psf_record "$PH" ph30-intent.md github.com
  psf_record_block "$PH" ph30-intent.md
  ph_write ph30 "$PH_GH" "$PH_GL"
  expect_eq "R3 not sent" "$(ph_remote ph30)" "absent"
  PH_R3="$(psf_record_state "$PH" ph30-intent.md "$PSF_ORIGIN_E2E")"
  case "$PH_R3" in
    NOT_IMPLEMENTED:*|match) fail "R3 no record a later sync could match" "state=$PH_R3" ;;
    *) pass "R3 no record a later sync could match" ;;
  esac
  case "$PH_OUT" in
    *"/blob/main/ph30-intent.md"*) fail "R3 the hook output offers no blob URL" "out=$PH_OUT" ;;
    "") fail "R3 the hook output offers no blob URL" "the hook printed nothing" ;;
    *) pass "R3 the hook output offers no blob URL" ;;
  esac
  rm -rf "$(psf_record_path "$PH" ph30-intent.md)"

  echo "=== the cwd saved in the session state never decides the project ==="
  # The saved cwd is the only decoy here, and it always gives the opposite verdict.
  while IFS='|' read -r name sid cwd saved want_host want; do
    [ -z "$name" ] && continue
    ph_saved_cwd_write "saved cwd, $name" "$sid" "$cwd" "$saved" "$want_host" "$want"
  done <<TABLE
no-cwd-in-hook-input|ph40|-|$PH_GH|none|no-project-host
gitlab-com-project|ph41|$PH_GL|$PH_GH|gitlab.com|host-mismatch
github-project|ph42|$PH_GH|$PH_GL|github.com|sent
empty-string-cwd|ph43|""|$PH_GH|none|no-project-host
null-cwd|ph44|null|$PH_GH|none|no-project-host
TABLE

  echo "=== R4: a record is never published ==="
  PH_TREE="$(git -C "$PH_BARE" ls-tree -r --name-only refs/heads/main 2>/dev/null | tr '\n' ' ')"
  case "$PH_TREE" in
    "") fail "R4 no record file in the destination tree" "destination main is empty: nothing was sent" ;;
    *note-project-host*|*.json*) fail "R4 no record file in the destination tree" "tree=$PH_TREE" ;;
    *) pass "R4 no record file in the destination tree" ;;
  esac
  PH_REC="$(psf_record_path "$PH" ph01-intent.md)"
  ph_host_check "R4 precondition: the record of a sent plan exists" ph01-intent.md github.com
  if git -C "$PH" check-ignore -q --no-index -- "${PH_REC##*/}"; then pass "R4 the record name is ignored by the rendered .gitignore"
  else fail "R4 the record name is ignored by the rendered .gitignore" "${PH_REC##*/} is not ignored"; fi
  OUT="$(psf_node 'process.stdout.write(String(ps.isSyncTarget(process.argv[1], process.argv[2])));' "$PH" "$PH_REC")"
  expect_eq "R4 the record name fails the sync-target condition" "$OUT" "false"
  OUT="$(export WORKFLOW_PLANS_DIR="$PH"; psf_node 'Promise.resolve(ps.syncPlanFile(process.argv[1], process.argv[2], { budgetMs: 20000 }))
  .then((r) => process.stdout.write([r.status, r.reason || ""].join("|")));' "$PH" "$PH_REC")"
  expect_eq "R4 syncing the record file itself -> skipped" "$OUT" "skipped|"
  expect_eq "R4 local main tracks no record either" \
    "$(git -C "$PH" ls-tree -r --name-only refs/heads/main 2>/dev/null | grep -c 'note-project-host')" "0"
fi

export PLAN_SYNC_REMOTE_URL=""
unset GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_SSH_STUB_BARE
