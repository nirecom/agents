# #2513 confirmation cases: T13 real publish -> blob URL, T14 push failure -> local path,
# T15 TERM_PROGRAM=vscode -> no editor launch; T19 every stage, T20 no artifact; T21-T24 one case
# per record state. Plan files are <SID>-<stage>.md (the only artifact the judge accepts). #2729:
# each dialog case seeds the presentation receipt first; T14/T18/T20/T24 are fail-closed denies.
# Sourced by ../feature-confirm-checkpoint.sh (needs run_hook, make_bash_json,
# extract_system_message, extract_decision, seed_receipt, write_marker, clear_markers).
# Publishing goes through bin/plan-sync-init + syncPlanFile (production deps) over the
# test-only ssh stub into a local bare repo; GitHub-form origin, no network (gh off PATH in T13).

CCP_PS_ROOT="${NODE_TMPDIR}/ccp-ps-$$"
PUB="$CCP_PS_ROOT/plans"
PUB_ABS="$PUB/$SID-intent.md"
PUB_BARE="$CCP_PS_ROOT/bare.git"
CCP_CLI="$(psf_np "$SCRIPT_CHECKOUT_ROOT_NATIVE/bin/plan-sync-init")"
CCP_BLOB_BASE="https://github.com/test-owner/test-repo/blob/main"
CCP_BLOB="$CCP_BLOB_BASE/$SID-intent.md"
mkdir -p "$PUB" "$CCP_PS_ROOT/neutral"
printf '[core]\n\thooksPath = /dev/null\n[user]\n\tname = ccp-test\n\temail = ccp-test@example.invalid\n' \
  > "$CCP_PS_ROOT/gitconfig"
trap 'cd / 2>/dev/null; rm -rf "$PLANS_DIR" "$WORKFLOW_DIR_TEST" "$ISOLATED_CFG_DIR" "$CCP_PS_ROOT"' EXIT

# ccp_ps_env — subshell only: isolated git config, PLANS_DIR=PUB, GitHub-form URL, ssh stub.
ccp_ps_env() {
  PSF_ROOT="$CCP_PS_ROOT"
  export GIT_CONFIG_GLOBAL="$CCP_PS_ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
  export PSF_LIB_PATH; PSF_LIB_PATH="$(psf_np "$PSF_LIB")"
  export WORKFLOW_PLANS_DIR="$PUB" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E"
  export GITLAB_HOSTNAME="" GITLAB_SSH_HOSTNAME=""
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_SSH 2>/dev/null || true
  setup_ssh_stub "$PUB_BARE"
  cd "$CCP_PS_ROOT/neutral" || return 1
}

# ccp_record <rel> <host|none> — the project-host record beside <rel>, written in the publish env.
ccp_record() { (ccp_ps_env >/dev/null 2>&1; psf_record "$PUB" "$1" "$2"); }

# ccp_sync <rel> — match record + syncPlanFile with production deps; prints "<status>|<reason>".
ccp_sync() {
  psf_record "$PUB" "$1" github.com
  psf_node 'Promise.resolve(ps.syncPlanFile(process.argv[1], path.join(process.argv[1], process.argv[2]),
  { budgetMs: 20000 })).then((r) => process.stdout.write(r.status + "|" + (r.reason || "")));' "$PUB" "$1"
}

# ccp_seed_pub <stage> — seed_receipt inside the publish env, so the receipt binds the same link
# (blob URL, or the local path for an unpublishable reason) the hook resolves there (#2729).
ccp_seed_pub() { (ccp_ps_env >/dev/null 2>&1; seed_receipt "$1"); }

# ccp_expect_deny <name> — the last run denied the echo and showed no dialog (#2729 fail-closed;
# #2731: the dialog has no "Click Allow" wording, so "no dialog" is "no systemMessage at all").
ccp_expect_deny() {
  if [ "$(extract_decision "$CCP_OUT")" = "deny" ] && [ -z "$CCP_MSG" ]; then pass "$1"
  else fail "$1 — expected a deny without the dialog, got: $CCP_OUT"; fi
}

ccp_confirm_msg() {
  extract_system_message "$(run_hook "$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")")"
}

# ccp_confirm_run [STAGE] — one CONFIRM_<STAGE> hook run (default INTENT); sets CCP_OUT, CCP_MSG, CCP_CTX, CCP_EVT.
ccp_confirm_run() {
  CCP_OUT="$(run_hook "$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_${1:-INTENT}>>\"")")"
  CCP_MSG="$(psf_sysmsg "$CCP_OUT")"
  CCP_CTX="$(psf_hso "$CCP_OUT" additionalContext)"
  CCP_EVT="$(psf_hso "$CCP_OUT" hookEventName)"
}

# ccp_confirm_pub [STAGE] — ccp_confirm_run inside the publish env (ssh stub, PLANS_DIR=PUB).
ccp_confirm_pub() {
  CCP_OUT="$(ccp_ps_env; ccp_confirm_run "${1:-INTENT}"; printf '%s' "$CCP_OUT")"
  CCP_MSG="$(psf_sysmsg "$CCP_OUT")"
  CCP_CTX="$(psf_hso "$CCP_OUT" additionalContext)"
  CCP_EVT="$(psf_hso "$CCP_OUT" hookEventName)"
}

# ccp_has_dir <text> <plans-dir> — <text> names the plans dir, forward-slash or native.
ccp_has_dir() {
  case "$1" in *"$2"*|*"${2//\//\\}"*) return 0 ;; esac
  return 1
}

# ccp_expect_ctx <name> <needle> <plans-dir> — one PreToolUse additionalContext line holds <needle>
# and the local path.
ccp_expect_ctx() {
  local line
  line="$(printf '%s\n' "$CCP_CTX" | grep -F -- "$2" | head -n 1)"
  if [ "$CCP_EVT" != PreToolUse ]; then fail "$1 — hookEventName=$CCP_EVT out=$CCP_OUT"
  elif [ -z "$line" ]; then fail "$1 — additionalContext lacks $2: $CCP_CTX"
  elif ! ccp_has_dir "$line" "$3"; then fail "$1 — the $2 line lacks the local path: $CCP_CTX"
  else pass "$1"; fi
}

# ccp_expect_no_url <name> — neither the additionalContext nor the systemMessage carries a URL.
ccp_expect_no_url() {
  case "$CCP_EVT|$CCP_CTX|$CCP_MSG" in
    PreToolUse\|*https://*) fail "$1 — ctx=$CCP_CTX msg=$CCP_MSG" ;;
    PreToolUse\|*) pass "$1" ;;
    *) fail "$1 — no PreToolUse additionalContext emitted: $CCP_OUT" ;;
  esac
}

# ccp_expect_msg_path <name> <plans-dir> — the systemMessage carries the local path.
ccp_expect_msg_path() {
  if ccp_has_dir "$CCP_MSG" "$2"; then pass "$1"; else fail "$1 — got: $CCP_MSG"; fi
}

echo "=== T13: init + sync publish through the ssh stub -> systemMessage shows the blob URL ==="
clear_markers
PUB_READY=$(
  ccp_ps_env || exit 0
  # The real CLI probes the codehost with the real gh (visibility, private-repo list): keep
  # gh off PATH so provisioning never reaches the network; refuse to run if it is still found.
  psf_drop_gh_from_path
  gh_seen="$(psf_node_finds_gh)"
  [ "$gh_seen" = "ENOENT" ] || { printf 'gh-still-reachable:%s' "$gh_seen"; exit 0; }
  psf_make_bare "$PUB_BARE" >/dev/null 2>&1 || { printf 'bare-failed'; exit 0; }
  if [ ! -f "$CCP_CLI" ]; then printf 'NOT_IMPLEMENTED: bin/plan-sync-init missing'; exit 0; fi
  psf_timeout 60 node "$CCP_CLI" >/dev/null 2>&1
  rc=$?
  printf 'published\n' > "$PUB_ABS"
  printf 'init=%s|sync=%s' "$rc" "$(ccp_sync "$SID-intent.md" 2>&1)"
)
case "$PUB_READY" in
  "init=0|sync=pushed|"*) pass "T13 plan-sync-init + syncPlanFile published to the stub remote" ;;
  *) fail "T13 publish through the stub — not implemented or failed: $PUB_READY" ;;
esac
T13_REMOTE=$(git -C "$PUB_BARE" show "refs/heads/main:$SID-intent.md" 2>/dev/null)
if [ "$T13_REMOTE" = "published" ]; then
  pass "T13 bare main holds the published blob"
else
  fail "T13 bare main missing the published blob — not implemented? got: $T13_REMOTE"
fi
write_marker "intent" "$PUB_ABS"
ccp_seed_pub intent >/dev/null
ccp_confirm_pub
if echo "$CCP_MSG" | grep -qF "$CCP_BLOB"; then
  pass "T13 systemMessage shows the GitHub blob URL"
else
  fail "T13 systemMessage missing the blob URL — got: $CCP_MSG"
fi
ccp_expect_msg_path "T13 systemMessage also shows the local path" "$PUB"
ccp_expect_ctx "T13 PreToolUse additionalContext line carries the same blob URL and the local path" "$CCP_BLOB" "$PUB"
clear_markers

echo "=== T20 (#2729, inverted): plan-sync on, no artifact for the stage -> deny, no dialog ==="
clear_markers
ccp_confirm_pub OUTLINE
ccp_expect_deny "T20 no artifact -> denied (unverifiable-artifact), no dialog systemMessage"
clear_markers

echo "=== T24 (#2729, inverted): no record, plan never sent (URL-capable env) -> deny as unpublished ==="
printf 'never sent\n' > "$PUB/$SID-detail.md"
psf_record_remove "$PUB" "$SID-detail.md"
write_marker "detail" "$PUB/$SID-detail.md"
T24_SEED="$(ccp_seed_pub detail)"
if [ "$T24_SEED" = NONE ]; then pass "T24 precondition: an unpublished plan yields no receipt link (not-published)"
else fail "T24 precondition: an unpublished plan yields no receipt link — seeded: $T24_SEED"; fi
ccp_confirm_pub DETAIL
ccp_expect_deny "T24 no record, absent: the path-only echo is denied (unpublished), no dialog"
case "$(psf_sysmsg "$CCP_OUT")$CCP_OUT" in
  *"--stage detail"*) pass "T24 deny reason points at bin/plan-link --stage detail" ;;
  *) fail "T24 deny reason points at bin/plan-link --stage detail — got: $CCP_OUT" ;;
esac
clear_markers

echo "=== T19: every stage (intent/outline/detail) published -> [stage] systemMessage + additionalContext blob URL ==="
for T19_STAGE in intent outline detail; do
  T19_UP="$(printf '%s' "$T19_STAGE" | tr '[:lower:]' '[:upper:]')"
  T19_REL="$SID-$T19_STAGE.md"
  T19_BLOB="$CCP_BLOB_BASE/$T19_REL"
  clear_markers
  if [ "$T19_STAGE" = intent ]; then
    # Published by T13; re-checked on the bare remote instead of re-syncing.
    if [ "$T13_REMOTE" = published ]; then T19_SYNC="pushed|"; else T19_SYNC="t13-not-published"; fi
  else
    T19_SYNC=$(
      ccp_ps_env || exit 0
      psf_drop_gh_from_path
      printf '%s stage body\n' "$T19_STAGE" > "$PUB/$T19_REL"
      ccp_sync "$T19_REL" 2>&1
    )
  fi
  case "$T19_SYNC" in
    pushed\|*) pass "T19 $T19_STAGE precondition: artifact published" ;;
    *) fail "T19 $T19_STAGE precondition: artifact published — not implemented or failed: $T19_SYNC" ;;
  esac
  write_marker "$T19_STAGE" "$PUB/$T19_REL"
  ccp_seed_pub "$T19_STAGE" >/dev/null
  ccp_confirm_pub "$T19_UP"
  if [[ "$CCP_MSG" == "[$T19_STAGE]"* && "$CCP_MSG" == *"$T19_BLOB"* ]] && ccp_has_dir "$CCP_MSG" "$PUB"; then
    pass "T19 $T19_STAGE systemMessage is [$T19_STAGE] + blob URL + local path"
  else
    fail "T19 $T19_STAGE systemMessage is [$T19_STAGE] + blob URL + local path — got: $CCP_MSG"
  fi
  ccp_expect_ctx "T19 $T19_STAGE additionalContext line carries the blob URL and the local path" "$T19_BLOB" "$PUB"
done
clear_markers

# T21-T23: the outline plan is at the destination with identical content (T19); only the record differs.
CCP_OUTLINE_BLOB="$CCP_BLOB_BASE/$SID-outline.md"
for T21_ROW in "T21|gitlab.com|host-mismatch" "T22|none|no-project-host"; do
  T21_ID="${T21_ROW%%|*}"; T21_REASON="${T21_ROW##*|}"; T21_HOST="${T21_ROW#*|}"; T21_HOST="${T21_HOST%%|*}"
  echo "=== $T21_ID: record $T21_HOST, plan at the destination -> local path + $T21_REASON, never a URL ==="
  ccp_record "$SID-outline.md" "$T21_HOST"
  write_marker "outline" "$PUB/$SID-outline.md"
  ccp_seed_pub outline >/dev/null
  ccp_confirm_pub OUTLINE
  ccp_expect_ctx "$T21_ID additionalContext line carries $T21_REASON and the local path" "$T21_REASON" "$PUB"
  ccp_expect_no_url "$T21_ID no URL although the plan is at the destination"
  ccp_expect_msg_path "$T21_ID systemMessage shows the local path" "$PUB"
  clear_markers
done

echo "=== T23: no record, plan identical at the destination -> URL + local path ==="
psf_record_remove "$PUB" "$SID-outline.md"
write_marker "outline" "$PUB/$SID-outline.md"
ccp_seed_pub outline >/dev/null
ccp_confirm_pub OUTLINE
ccp_expect_ctx "T23 no record, identical: additionalContext line carries the URL and the local path" "$CCP_OUTLINE_BLOB" "$PUB"
if [[ "$CCP_MSG" == *"$CCP_OUTLINE_BLOB"* ]] && ccp_has_dir "$CCP_MSG" "$PUB"; then pass "T23 no record, identical: systemMessage shows the URL and the local path"
else fail "T23 no record, identical: systemMessage shows the URL and the local path — got: $CCP_MSG"; fi
clear_markers

echo "=== T14: push failure (local main ahead of origin/main) -> local path, no blob URL ==="
clear_markers
T14_STATE=$(
  ccp_ps_env || exit 0
  export GIT_SSH_STUB_FAIL=offline
  printf 'edited locally\n' > "$PUB_ABS"
  s="$(ccp_sync "$SID-intent.md" 2>&1)"
  l="$(git -C "$PUB" rev-parse --verify -q refs/heads/main 2>/dev/null)"
  o="$(git -C "$PUB" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null)"
  b="$(git -C "$PUB_BARE" rev-parse --verify -q refs/heads/main 2>/dev/null)"
  ahead=no
  if [ -n "$l" ] && [ -n "$o" ] && [ "$l" != "$o" ] && [ "$o" = "$b" ] \
    && git -C "$PUB" merge-base --is-ancestor "$o" "$l" 2>/dev/null; then ahead=yes; fi
  printf 'sync=%s|ahead=%s' "${s%%|*}" "$ahead"
)
if [ "$T14_STATE" = "sync=failed|ahead=yes" ]; then
  pass "T14 unreachable remote -> sync failed, local commit ahead of origin/main"
  write_marker "intent" "$PUB_ABS"
  # #2729 (inverted): the plan could have a URL but is not published, so a path-only presentation
  # never passes; the echo is denied (unpublished) instead of showing the local path.
  T14_OUT=$(ccp_ps_env; export GIT_SSH_STUB_FAIL=offline; ccp_confirm_run; printf '%s' "$CCP_OUT")
  CCP_OUT="$T14_OUT"; CCP_MSG="$(psf_sysmsg "$T14_OUT")"
  ccp_expect_deny "T14 unpushed blob -> denied (unpublished), no dialog with the local path"
else
  fail "T14 push-failure precondition — not implemented or failed: $T14_STATE"
fi
clear_markers

echo "=== T15: TERM_PROGRAM=vscode — confirmation never launches the editor ==="
clear_markers
T15_ABS="$PLANS_DIR/$SID-intent.md"
touch "$T15_ABS"
write_marker "intent" "$T15_ABS"
seed_receipt intent >/dev/null
: > "$CODE_STUB_LOG"
T15_OUT=$(
  export TERM_PROGRAM=vscode
  unset CLAUDE_CODE_ENTRYPOINT SHOW_PLAN_LINK_NO_AUTO_OPEN SHOW_PLAN_LINK_NO_SPAWN SHOW_PLAN_LINK_MARKER_FILE 2>/dev/null || true
  msg="$(ccp_confirm_msg)"
  sleep 1
  case "$msg" in *"$SID-intent.md"*) shown=yes ;; *) shown=no ;; esac
  printf 'count=%s|shown=%s' "$(code_stub_count)" "$shown"
)
if [ "$T15_OUT" = "count=0|shown=yes" ]; then
  pass "T15 TERM_PROGRAM=vscode — path shown, 0 code invocations"
else
  fail "T15 TERM_PROGRAM=vscode — expected count=0|shown=yes, got: $T15_OUT"
fi
clear_markers
rm -f "$T15_ABS"

# #2277 S6: intent has no off waiver (T25 pins that), so the off-skip contract is pinned on outline.
echo "=== T16: CONFIRM_OUTLINE=off -> skipped systemMessage, no additionalContext ==="
clear_markers
T16_ABS="$PLANS_DIR/sess-off-outline.md"
touch "$T16_ABS"
write_marker "outline" "$T16_ABS"
T16_OUT=$(confirm_env_root "$ISOLATED_CFG_DIR/t16" CONFIRM_OUTLINE=off; run_hook "$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_OUTLINE>>\"")")
if [ "$(psf_sysmsg "$T16_OUT")" = "[confirm-skipped: CONFIRM_OUTLINE=off]" ] && ! psf_has_hso "$T16_OUT"; then
  pass "T16 CONFIRM_OUTLINE=off -> skipped message only, no hookSpecificOutput"
else
  fail "T16 CONFIRM_OUTLINE=off -> skipped message only, no hookSpecificOutput — got: $T16_OUT"
fi
clear_markers
rm -f "$T16_ABS"

echo "=== T17: plan-sync off -> additionalContext names plan-sync-off, systemMessage keeps the local path ==="
clear_markers
T17_ABS="$PLANS_DIR/$SID-intent.md"
touch "$T17_ABS"
write_marker "intent" "$T17_ABS"
seed_receipt intent >/dev/null
ccp_confirm_run
ccp_expect_ctx "T17 sync off -> PreToolUse additionalContext line carries plan-sync-off and the local path" "plan-sync-off" "$PLANS_DIR"
if [ "$CCP_MSG" = "[intent] $T17_ABS" ]; then pass "T17 sync off -> systemMessage shows the local path"
else fail "T17 sync off -> systemMessage shows the local path — got: $CCP_MSG"; fi
clear_markers

echo "=== T18 (#2729, inverted): plan-link throws -> fail-closed deny ==="
# A preload makes require(".../plan-link") throw and leaves a canary, so the case proves the
# hook really reached plan-link (non-vacuous). A valid receipt is seeded first, so the deny can
# only come from the plan-link failure (unverifiable-link), never from a missing receipt.
T18_CANARY="$CCP_PS_ROOT/t18-plan-link-required"
T18_PRELOAD="$CCP_PS_ROOT/t18-throw-plan-link.js"
printf '%s\n' 'const M = require("module"); const fs = require("fs"); const orig = M._load;' \
  'M._load = function (req) {' \
  '  if (/(^|[\\/])plan-link(\.js)?$/.test(String(req))) {' \
  '    fs.writeFileSync(process.env.T18_CANARY, "1"); throw new Error("t18: plan-link boom");' \
  '  }' \
  '  return orig.apply(this, arguments);' \
  '};' > "$T18_PRELOAD"
rm -f "$T18_CANARY"
write_marker "intent" "$T17_ABS"
seed_receipt intent >/dev/null
T18_OUT=$(
  export T18_CANARY NODE_OPTIONS="--require \"$(psf_np "$T18_PRELOAD")\""
  run_hook "$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")"
)
T18_MSG="$(psf_sysmsg "$T18_OUT")"
if [ -f "$T18_CANARY" ]; then pass "T18 precondition: the hook required lib/plan-link"
else fail "T18 precondition: the hook required lib/plan-link — canary absent (plan-link not wired)"; fi
if [ -f "$T18_CANARY" ] && [ "$(extract_decision "$T18_OUT")" = "deny" ] && [ -z "$T18_MSG" ]; then
  pass "T18 plan-link exception -> denied (unverifiable-link), no dialog"
else
  fail "T18 plan-link exception -> denied (unverifiable-link), no dialog — got: $T18_OUT"
fi
clear_markers
rm -f "$T17_ABS"
