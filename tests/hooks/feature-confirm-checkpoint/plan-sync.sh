# #2513 confirmation cases: T13 real publish -> blob URL, T14 push failure -> local path,
# T15 TERM_PROGRAM=vscode -> no editor launch. Sourced by ../feature-confirm-checkpoint.sh
# (needs run_hook, make_bash_json, extract_system_message, write_marker, clear_markers).
# Publishing goes through bin/plan-sync-init + syncPlanFile (production deps) over the
# test-only ssh stub into a local bare repo; GitHub-form origin, no network (gh off PATH in T13).

CCP_PS_ROOT="${NODE_TMPDIR}/ccp-ps-$$"
PUB="$CCP_PS_ROOT/plans"
PUB_ABS="$PUB/sess-pub-intent.md"
PUB_BARE="$CCP_PS_ROOT/bare.git"
CCP_CLI="$(psf_np "$AGENTS_DIR/bin/plan-sync-init")"
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
T13_MSG=$(ccp_ps_env; ccp_confirm_msg)
if echo "$T13_MSG" | grep -qF "$CCP_BLOB"; then
  pass "T13 systemMessage shows the GitHub blob URL"
else
  fail "T13 systemMessage missing the blob URL — got: $T13_MSG"
fi
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
  T14_MSG=$(ccp_ps_env; export GIT_SSH_COMMAND=false; ccp_confirm_msg)
  if echo "$T14_MSG" | grep -qF "$PUB_ABS" && ! echo "$T14_MSG" | grep -qF "https://"; then
    pass "T14 unpushed blob -> absPath shown, no URL"
  else
    fail "T14 unpushed blob — expected absPath and no URL, got: $T14_MSG"
  fi
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
  unset CLAUDE_CODE_ENTRYPOINT SHOW_PLAN_LINK_NO_AUTO_OPEN SHOW_PLAN_LINK_NO_SPAWN SHOW_PLAN_LINK_MARKER_FILE 2>/dev/null || true
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
