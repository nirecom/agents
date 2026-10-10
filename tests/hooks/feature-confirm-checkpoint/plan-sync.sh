# #2513 confirmation cases: T13 real publish -> blob URL, T14 push failure -> local path,
# T15 TERM_PROGRAM=vscode -> no editor launch; T19 every stage, T20 no artifact;
# T13/T14/T16-T20 also pin the model-facing
# PreToolUse additionalContext (URL or reason, never a local path). Sourced by ../feature-confirm-checkpoint.sh
# (needs run_hook, make_bash_json, extract_system_message, write_marker, clear_markers).
# Publishing goes through bin/plan-sync-init + syncPlanFile (production deps) over the
# test-only ssh stub into a local bare repo; GitHub-form origin, no network (gh off PATH in T13).

CCP_PS_ROOT="${NODE_TMPDIR}/ccp-ps-$$"
PUB="$CCP_PS_ROOT/plans"
PUB_ABS="$PUB/sess-pub-intent.md"
PUB_BARE="$CCP_PS_ROOT/bare.git"
CCP_CLI="$(psf_np "$SCRIPT_CHECKOUT_ROOT_NATIVE/bin/plan-sync-init")"
CCP_BLOB="https://github.com/test-owner/test-repo/blob/main/sess-pub-intent.md"
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
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_SSH 2>/dev/null || true
  setup_ssh_stub "$PUB_BARE"
  cd "$CCP_PS_ROOT/neutral" || return 1
}

# ccp_sync <rel> — syncPlanFile with production deps; prints "<status>|<reason>".
ccp_sync() {
  psf_node 'Promise.resolve(ps.syncPlanFile(process.argv[1], path.join(process.argv[1], process.argv[2]),
  { budgetMs: 20000 })).then((r) => process.stdout.write(r.status + "|" + (r.reason || "")));' "$PUB" "$1"
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

# ccp_expect_ctx <name> <needle> <plans-dir> — PreToolUse additionalContext has <needle>, no local path.
ccp_expect_ctx() {
  local leak
  leak="$(psf_path_leak "$CCP_CTX" "$3")"
  if [ "$CCP_EVT" != PreToolUse ]; then fail "$1 — hookEventName=$CCP_EVT out=$CCP_OUT"
  elif [[ "$CCP_CTX" != *"$2"* ]]; then fail "$1 — additionalContext lacks $2: $CCP_CTX"
  elif [ -n "$leak" ]; then fail "$1 — additionalContext leaks a local path ($leak)"
  else pass "$1"; fi
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
  printf 'init=%s|sync=%s' "$rc" "$(ccp_sync sess-pub-intent.md 2>&1)"
)
case "$PUB_READY" in
  "init=0|sync=pushed|"*) pass "T13 plan-sync-init + syncPlanFile published to the stub remote" ;;
  *) fail "T13 publish through the stub — not implemented or failed: $PUB_READY" ;;
esac
T13_REMOTE=$(git -C "$PUB_BARE" show refs/heads/main:sess-pub-intent.md 2>/dev/null)
if [ "$T13_REMOTE" = "published" ]; then
  pass "T13 bare main holds the published blob"
else
  fail "T13 bare main missing the published blob — not implemented? got: $T13_REMOTE"
fi
write_marker "intent" "$PUB_ABS"
T13_OUT=$(ccp_ps_env; ccp_confirm_run; printf '%s' "$CCP_OUT")
CCP_OUT="$T13_OUT"; CCP_MSG="$(psf_sysmsg "$T13_OUT")"
CCP_CTX="$(psf_hso "$T13_OUT" additionalContext)"; CCP_EVT="$(psf_hso "$T13_OUT" hookEventName)"
if echo "$CCP_MSG" | grep -qF "$CCP_BLOB"; then
  pass "T13 systemMessage shows the GitHub blob URL"
else
  fail "T13 systemMessage missing the blob URL — got: $CCP_MSG"
fi
ccp_expect_ctx "T13 PreToolUse additionalContext carries the same blob URL, no local path" "$CCP_BLOB" "$PUB"
clear_markers

echo "=== T19: every stage (intent/outline/detail) published -> [stage] systemMessage + additionalContext blob URL ==="
for T19_STAGE in intent outline detail; do
  T19_UP="$(printf '%s' "$T19_STAGE" | tr '[:lower:]' '[:upper:]')"
  T19_REL="sess-pub-$T19_STAGE.md"
  T19_BLOB="https://github.com/test-owner/test-repo/blob/main/$T19_REL"
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
  T19_OUT=$(ccp_ps_env; ccp_confirm_run "$T19_UP"; printf '%s' "$CCP_OUT")
  CCP_OUT="$T19_OUT"; CCP_MSG="$(psf_sysmsg "$T19_OUT")"
  CCP_CTX="$(psf_hso "$T19_OUT" additionalContext)"; CCP_EVT="$(psf_hso "$T19_OUT" hookEventName)"
  case "$CCP_MSG" in
    "[$T19_STAGE] Plan file: $T19_BLOB"*) pass "T19 $T19_STAGE systemMessage is '[$T19_STAGE] Plan file: <blob URL>'" ;;
    *) fail "T19 $T19_STAGE systemMessage is '[$T19_STAGE] Plan file: <blob URL>' — got: $CCP_MSG" ;;
  esac
  ccp_expect_ctx "T19 $T19_STAGE additionalContext carries the blob URL, no local path" "$T19_BLOB" "$PUB"
done
clear_markers

echo "=== T20: plan-sync on, no artifact for the stage -> additionalContext names no-artifact, no path ==="
# Assumption: with plan-sync configured and neither a turn marker nor a <sid>-<stage>.md file,
# the reason is no-artifact (not plan-sync-off); the systemMessage keeps the Click Allow line.
clear_markers
T20_OUT=$(ccp_ps_env; ccp_confirm_run OUTLINE; printf '%s' "$CCP_OUT")
CCP_OUT="$T20_OUT"; CCP_MSG="$(psf_sysmsg "$T20_OUT")"
CCP_CTX="$(psf_hso "$T20_OUT" additionalContext)"; CCP_EVT="$(psf_hso "$T20_OUT" hookEventName)"
ccp_expect_ctx "T20 no artifact -> additionalContext names no-artifact, no local path" "no-artifact" "$PUB"
case "$CCP_CTX" in
  "") fail "T20 no artifact -> additionalContext carries no URL — no additionalContext emitted" ;;
  *https://*) fail "T20 no artifact -> additionalContext carries no URL — ctx=$CCP_CTX" ;;
  *) pass "T20 no artifact -> additionalContext carries no URL" ;;
esac
if echo "$CCP_MSG" | grep -qF "Click Allow"; then pass "T20 no artifact -> systemMessage still asks for confirmation"
else fail "T20 no artifact -> systemMessage still asks for confirmation — got: $CCP_MSG"; fi
clear_markers

echo "=== T14: push failure (local main ahead of origin/main) -> local path, no blob URL ==="
clear_markers
T14_STATE=$(
  ccp_ps_env || exit 0
  export GIT_SSH_COMMAND=false
  printf 'edited locally\n' > "$PUB_ABS"
  s="$(ccp_sync sess-pub-intent.md 2>&1)"
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
  T14_OUT=$(ccp_ps_env; export GIT_SSH_COMMAND=false; ccp_confirm_run; printf '%s' "$CCP_OUT")
  T14_MSG="$(psf_sysmsg "$T14_OUT")"
  if echo "$T14_MSG" | grep -qF "$PUB_ABS" && ! echo "$T14_MSG" | grep -qF "https://"; then
    pass "T14 unpushed blob -> absPath shown, no URL"
  else
    fail "T14 unpushed blob — expected absPath and no URL, got: $T14_MSG"
  fi
  CCP_OUT="$T14_OUT"; CCP_CTX="$(psf_hso "$T14_OUT" additionalContext)"; CCP_EVT="$(psf_hso "$T14_OUT" hookEventName)"
  ccp_expect_ctx "T14 additionalContext names not-published, no local path" "not-published" "$PUB"
  case "$CCP_CTX" in
    "") fail "T14 additionalContext carries no URL — no additionalContext emitted" ;;
    *https://*) fail "T14 additionalContext carries no URL — ctx=$CCP_CTX" ;;
    *) pass "T14 additionalContext carries no URL" ;;
  esac
else
  fail "T14 push-failure precondition — not implemented or failed: $T14_STATE"
fi
clear_markers

echo "=== T15: TERM_PROGRAM=vscode — confirmation never launches the editor ==="
clear_markers
T15_ABS="$PLANS_DIR/sess-nocode-intent.md"
touch "$T15_ABS"
write_marker "intent" "$T15_ABS"
: > "$CODE_STUB_LOG"
T15_OUT=$(
  export TERM_PROGRAM=vscode
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  msg="$(ccp_confirm_msg)"
  sleep 1
  case "$msg" in *sess-nocode-intent.md*) shown=yes ;; *) shown=no ;; esac
  printf 'count=%s|shown=%s' "$(code_stub_count)" "$shown"
)
if [ "$T15_OUT" = "count=0|shown=yes" ]; then
  pass "T15 TERM_PROGRAM=vscode — path shown, 0 code invocations"
else
  fail "T15 TERM_PROGRAM=vscode — expected count=0|shown=yes, got: $T15_OUT"
fi
clear_markers
rm -f "$T15_ABS"

echo "=== T16: CONFIRM_INTENT=off -> skipped systemMessage, no additionalContext ==="
clear_markers
T16_ABS="$PLANS_DIR/sess-off-intent.md"
touch "$T16_ABS"
write_marker "intent" "$T16_ABS"
T16_OUT=$(export CONFIRM_INTENT=off; run_hook "$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")")
if [ "$(psf_sysmsg "$T16_OUT")" = "[confirm-skipped: CONFIRM_INTENT=off]" ] && ! psf_has_hso "$T16_OUT"; then
  pass "T16 CONFIRM_INTENT=off -> skipped message only, no hookSpecificOutput"
else
  fail "T16 CONFIRM_INTENT=off -> skipped message only, no hookSpecificOutput — got: $T16_OUT"
fi
clear_markers
rm -f "$T16_ABS"

echo "=== T17: plan-sync off -> additionalContext names plan-sync-off, systemMessage keeps the local path ==="
clear_markers
T17_ABS="$PLANS_DIR/sess-syncoff-intent.md"
touch "$T17_ABS"
write_marker "intent" "$T17_ABS"
ccp_confirm_run
ccp_expect_ctx "T17 sync off -> PreToolUse additionalContext names plan-sync-off, no local path" "plan-sync-off" "$PLANS_DIR"
if echo "$CCP_MSG" | grep -qF "Plan file: $T17_ABS"; then pass "T17 sync off -> systemMessage shows the local path"
else fail "T17 sync off -> systemMessage shows the local path — got: $CCP_MSG"; fi
clear_markers

echo "=== T18: plan-link throws -> fail-open, systemMessage only ==="
# A preload makes require(".../plan-link") throw and leaves a canary, so the case proves the
# hook really reached plan-link (non-vacuous) and still emitted the confirmation message.
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
T18_OUT=$(
  export T18_CANARY NODE_OPTIONS="--require \"$(psf_np "$T18_PRELOAD")\""
  run_hook "$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")"
)
T18_MSG="$(psf_sysmsg "$T18_OUT")"
if [ -f "$T18_CANARY" ]; then pass "T18 precondition: the hook required lib/plan-link"
else fail "T18 precondition: the hook required lib/plan-link — canary absent (plan-link not wired)"; fi
if [ -f "$T18_CANARY" ] && echo "$T18_MSG" | grep -qF "Click Allow" && ! psf_has_hso "$T18_OUT"; then
  pass "T18 plan-link exception -> systemMessage only (fail-open)"
else
  fail "T18 plan-link exception -> systemMessage only (fail-open) — got: $T18_OUT"
fi
clear_markers
rm -f "$T17_ABS"
