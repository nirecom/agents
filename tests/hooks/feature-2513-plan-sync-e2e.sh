#!/usr/bin/env bash
# tests/hooks/feature-2513-plan-sync-e2e.sh
# Tests: hooks/show-plan-link.js, bin/plan-sync-init, hooks/confirm-checkpoint.js
# Tags: plan-sync, e2e, ssh-stub, show-plan-link, confirm-checkpoint, TL2, scope:issue-specific, cli, init, redact, visibility, gh-stub, remote-url-mismatch, cli-args, interactive, additional-context, env-write
# #2513 end-to-end (detail.md "テストの構成" 4, S3-5): real CLI + real hooks over the
# test-only ssh stub (tests/lib/git-ssh-stub.sh) into a local bare repo. No network.
set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - real GitHub ssh auth, host keys and the rendered blob page
# - Claude Code delivering the PostToolUse / PreToolUse payloads to these hooks
# - installer wiring (install.sh / install.ps1 invoking bin/plan-sync-init)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-fixture.sh"

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
psf_tag_unimplemented_fails
trap psf_cleanup EXIT
CLI="$(psf_np "$SCRIPT_CHECKOUT_ROOT/bin/plan-sync-init")"
SPL="$(psf_np "$SCRIPT_CHECKOUT_ROOT/hooks/show-plan-link.js")"
CCP="$(psf_np "$SCRIPT_CHECKOUT_ROOT/hooks/confirm-checkpoint.js")"
PLANS="$WORKFLOW_PLANS_DIR"
BARE="$PSF_ROOT/bare.git"
BLOB="https://github.com/test-owner/test-repo/blob/main"
psf_make_bare "$BARE"
setup_ssh_stub "$BARE"
export PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E"
# The real CLI probes visibility with the real gh (network): keep it off PATH throughout.
psf_drop_gh_from_path

# hook_run <hook.js> <json> [plansDir] — sets H_MSG, H_CTX, H_EVT from one hook run.
hook_run() {
  local out
  out="$(printf '%s' "$2" | WORKFLOW_PLANS_DIR="${3:-$PLANS}" psf_timeout 60 node "$1" 2>/dev/null)"
  H_MSG="$(psf_sysmsg "$out")"
  H_CTX="$(psf_hso "$out" additionalContext)"
  H_EVT="$(psf_hso "$out" hookEventName)"
}

# expect_ctx_url <name> <event> <url> <plansDir> — D1: the URL rides additionalContext, no local path.
expect_ctx_url() {
  local leak
  leak="$(psf_path_leak "$H_CTX" "$4")"
  if [ "$H_EVT" != "$2" ]; then fail "$1" "hookEventName=$(printf '%q' "$H_EVT") want $2"
  elif [[ "$H_CTX" != *"$3"* ]]; then fail "$1" "ctx lacks $3: $(printf '%q' "$H_CTX")"
  elif [ -n "$leak" ]; then fail "$1" "ctx leaks a local path ($leak)"
  else pass "$1"; fi
}

# init_cli <plansDir> — prints the CLI rc; "NI" when the CLI is absent.
init_cli() {
  if [ ! -f "$CLI" ]; then printf 'NI'; return; fi
  WORKFLOW_PLANS_DIR="$1" psf_timeout 60 node "$CLI" > "$PSF_ROOT/init.out" 2>&1
  printf '%s' "$?"
}

# stub_log_ok <name> — the stub log is non-empty and every line is the fixture repo path.
stub_log_ok() {
  local bad
  if [ ! -s "$GIT_SSH_STUB_LOG" ]; then fail "$1" "ssh stub was never invoked"; return; fi
  bad="$(grep -vxF '/test-owner/test-repo.git' "$GIT_SSH_STUB_LOG")"
  if [ -z "$bad" ]; then pass "$1"; else fail "$1" "unexpected repo paths: $bad"; fi
}

# expect_has <name> <haystack> <needle>
expect_has() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "missing $(printf '%q' "$3") in $(printf '%q' "$2")" ;;
  esac
}

if psf_git_version_ok; then pass "git-version>=2.32"; else fail "git-version>=2.32" "$(git version)"; fi

case_begin "ssh-stub-precondition" "bin/plan-sync-init"
GH_SEEN="$(psf_node_finds_gh)"
if [ "$GH_SEEN" = "ENOENT" ]; then pass "real gh unreachable from node"; else fail "real gh unreachable from node" "spawnSync(gh): $GH_SEEN"; fi
psf_timeout 30 git ls-remote "$PSF_ORIGIN_E2E" >/dev/null 2>&1
RC=$?
if [ "$RC" = 0 ]; then pass "stub serves the fixture repo to plain git"; else fail "stub serves the fixture repo to plain git" "rc=$RC"; fi
stub_log_ok "stub log records only /test-owner/test-repo.git"
if psf_timeout 30 git ls-remote "ssh://git@github.com/test-owner/other.git" >/dev/null 2>&1; then
  fail "stub refuses an unknown repo path" "ls-remote succeeded"
else pass "stub refuses an unknown repo path"; fi
setup_ssh_stub "$BARE"
case_end

case_begin "init-then-breadcrumb-url" "hooks/show-plan-link.js"
RC="$(init_cli "$PLANS")"
if [ "$RC" = 0 ]; then pass "E1 plan-sync-init exit 0"
else fail "E1 plan-sync-init exit 0" "rc=$RC out=$(cat "$PSF_ROOT/init.out" 2>/dev/null || echo 'NOT_IMPLEMENTED: bin/plan-sync-init missing')"; fi
# gh is off PATH, so init must warn; matched on the stable word "visibility", any case.
if grep -qi 'visibility' "$PSF_ROOT/init.out" 2>/dev/null; then pass "E1 init warns that visibility was not verified"
else fail "E1 init warns that visibility was not verified" "out=$(cat "$PSF_ROOT/init.out" 2>/dev/null)"; fi
printf 'e2e intent\n' > "$PLANS/s2513e2e-intent.md"
hook_run "$SPL" "$(psf_write_json "$PLANS/s2513e2e-intent.md" test-sid-e2e)"
expect_ctx_url "E1 additionalContext carries the GitHub blob URL" PostToolUse "$BLOB/s2513e2e-intent.md" "$PLANS"
if [ -z "$H_MSG" ]; then pass "E1 success emits no systemMessage (D2)"
else fail "E1 success emits no systemMessage (D2)" "msg=$(printf '%q' "$H_MSG")"; fi
expect_has "E1 bare main holds the written content" "$(git -C "$BARE" show refs/heads/main:s2513e2e-intent.md 2>&1)" "e2e intent"
BM="$(git -C "$BARE" rev-parse --verify -q refs/heads/main)"
expect_has "E1 local origin/main == bare main" "$(git -C "$PLANS" rev-parse --verify -q refs/remotes/origin/main 2>&1)/" "${BM:-no-bare-main}/"
stub_log_ok "E1 every ssh request targets /test-owner/test-repo.git"
case_end

case_begin "confirm-checkpoint-same-url" "hooks/confirm-checkpoint.js"
CCP_JSON="$(psf_timeout 30 node -e 'process.stdout.write(JSON.stringify({ tool_name: "Bash",
  tool_input: { command: "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"" }, session_id: "test-sid-e2e" }));')"
hook_run "$CCP" "$CCP_JSON"
expect_has "E2 confirm-checkpoint shows the same blob URL" "$H_MSG" "$BLOB/s2513e2e-intent.md"
expect_ctx_url "E2 confirm-checkpoint additionalContext carries the same blob URL" PreToolUse "$BLOB/s2513e2e-intent.md" "$PLANS"
case_end

case_begin "non-ff-through-stub" "hooks/show-plan-link.js"
setup_ssh_stub "$BARE"
P2="$PSF_ROOT/plans-2"; mkdir -p "$P2"
RC="$(init_cli "$P2")"
if [ "$RC" = 0 ]; then pass "E3 second machine init exit 0"; else fail "E3 second machine init exit 0" "rc=$RC"; fi
printf 'other machine\n' > "$P2/s2513other-intent.md"
hook_run "$SPL" "$(psf_write_json "$P2/s2513other-intent.md" test-sid-e2e2)" "$P2"
expect_ctx_url "E3 second machine pushes first" PostToolUse "$BLOB/s2513other-intent.md" "$P2"
printf 'e2e outline\n' > "$PLANS/s2513e2e-outline.md"
hook_run "$SPL" "$(psf_write_json "$PLANS/s2513e2e-outline.md" test-sid-e2e)"
expect_ctx_url "E3 behind machine still gets the blob URL" PostToolUse "$BLOB/s2513e2e-outline.md" "$PLANS"
TREE="$(git -C "$BARE" ls-tree -r --name-only refs/heads/main 2>/dev/null | tr '\n' ' ')"
expect_has "E3 remote keeps the earlier push and both local files" "$TREE" \
  ".gitignore s2513e2e-intent.md s2513e2e-outline.md s2513other-intent.md "
BM="$(git -C "$BARE" rev-parse --verify -q refs/heads/main)"
expect_has "E3 local origin/main == bare main" "$(git -C "$PLANS" rev-parse --verify -q refs/remotes/origin/main 2>&1)/" "${BM:-no-bare-main}/"
if [ -e "$PLANS/s2513other-intent.md" ]; then fail "E3 remote-only file not checked out" "found in PLANS"
elif [ -z "$BM" ]; then fail "E3 remote-only file not checked out" "bare main missing"
else pass "E3 remote-only file not checked out"; fi
stub_log_ok "E3 every ssh request targets /test-owner/test-repo.git"
case_end

# CLI refusal paths (merged from the former tests/bin/feature-2513-plan-sync-init.sh):
# each case gets its own plans dir so the provisioned $PLANS above is never touched.
# run_cli [args...] — sets CLI_RC / CLI_OUT (stdout+stderr); CLI_RC=NI when the CLI is absent.
run_cli() {
  if [ ! -f "$CLI" ]; then CLI_RC=NI; CLI_OUT="NOT_IMPLEMENTED: bin/plan-sync-init missing"; return; fi
  CLI_OUT="$(psf_timeout 60 node "$CLI" "$@" 2>&1)"
  CLI_RC=$?
}

# expect_rc <name> <want>
expect_rc() {
  if [ "$CLI_RC" = "NI" ]; then fail "$1" "not implemented ($CLI_OUT)"
  elif [ "$CLI_RC" = "$2" ]; then pass "$1"
  else fail "$1" "rc=$CLI_RC want=$2 out=$CLI_OUT"; fi
}

case_begin "cli-empty-url-not-configured" "bin/plan-sync-init"
CL1="$PSF_ROOT/cl1-plans"; mkdir -p "$CL1"
WORKFLOW_PLANS_DIR="$CL1" PLAN_SYNC_REMOTE_URL="" run_cli
expect_rc "CLI1 exit 0" 0
expect_has "CLI1 prints plan-sync: not configured" "$CLI_OUT" "plan-sync: not configured"
if [ "$CLI_RC" != "NI" ] && [ ! -e "$CL1/.git" ] && [ ! -e "$CL1/.gitignore" ]; then pass "CLI1 no .git, no .gitignore"
else fail "CLI1 no .git, no .gitignore" "rc=$CLI_RC"; fi
case_end

case_begin "cli-deny-local-path-url" "bin/plan-sync-init"
CL2="$PSF_ROOT/cl2-plans"; mkdir -p "$CL2"
WORKFLOW_PLANS_DIR="$CL2" run_cli --remote-url "$PSF_ROOT/local-bare.git"
expect_rc "CLI2 exit 1" 1
if [ "$CLI_RC" != "NI" ] && [ ! -e "$CL2/.git" ]; then pass "CLI2 no .git created"
else fail "CLI2 no .git created" "rc=$CLI_RC"; fi
case_end

case_begin "cli-git-file-refused" "bin/plan-sync-init"
CL3="$PSF_ROOT/cl3-plans"; mkdir -p "$CL3"
printf 'gitdir: %s\n' "$PSF_ROOT/elsewhere" > "$CL3/.git"
WORKFLOW_PLANS_DIR="$CL3" run_cli --remote-url "$PSF_ORIGIN_GH"
expect_rc "CLI3 exit 1" 1
if [ "$CLI_RC" != "NI" ] && [ -f "$CL3/.git" ] && [ ! -e "$CL3/.gitignore" ]; then pass "CLI3 .git file untouched, no .gitignore"
else fail "CLI3 .git file untouched, no .gitignore" "rc=$CLI_RC"; fi
case_end

case_begin "cli-unreachable-not-provisioned" "bin/plan-sync-init"
CL4="$PSF_ROOT/cl4-plans"; mkdir -p "$CL4"
WORKFLOW_PLANS_DIR="$CL4" GIT_SSH_COMMAND=false run_cli --remote-url "$PSF_ORIGIN_DEAD"
expect_rc "CLI4 exit 1" 1
if [ "$CLI_RC" = "NI" ]; then fail "CLI4 plansync.version not written" "not implemented ($CLI_OUT)"
else CL4_VER="$(git -C "$CL4" config --get plansync.version 2>/dev/null)"
  if [ -z "$CL4_VER" ]; then pass "CLI4 plansync.version not written"
  else fail "CLI4 plansync.version not written" "plansync.version=$CL4_VER"; fi
fi
case_end

case_begin "cli-userinfo-redacted" "bin/plan-sync-init"
CL5="$PSF_ROOT/cl5-plans"; mkdir -p "$CL5"
WORKFLOW_PLANS_DIR="$CL5" GIT_SSH_COMMAND=false run_cli --remote-url "https://test-user:s3cr3t-token@127.0.0.1:1/o/r.git"
case "$CLI_OUT" in
  NOT_IMPLEMENTED:*) fail "CLI5 output redacts userinfo" "not implemented ($CLI_OUT)" ;;
  *s3cr3t-token*) fail "CLI5 output redacts userinfo" "token leaked: $CLI_OUT" ;;
  "") fail "CLI5 output redacts userinfo" "CLI printed nothing" ;;
  *) pass "CLI5 output redacts userinfo" ;;
esac
expect_rc "CLI5 exit 1" 1
case_end

case_begin "cli-env-example-placeholder-not-provisioned" "bin/plan-sync-init"
# A copied .env.example must not provision its placeholder remote; the value is read at runtime.
CL6_URL="$(grep -m1 '^PLAN_SYNC_REMOTE_URL=' "$SCRIPT_CHECKOUT_ROOT/.env.example" 2>/dev/null)"
CL6_URL="${CL6_URL#PLAN_SYNC_REMOTE_URL=}"
CL6="$PSF_ROOT/cl6-plans"; mkdir -p "$CL6"
: > "$GIT_SSH_STUB_LOG"
if [ -z "$CL6_URL" ]; then fail "CLI6 placeholder read from .env.example" "no non-empty PLAN_SYNC_REMOTE_URL line"
else
  WORKFLOW_PLANS_DIR="$CL6" PLAN_SYNC_REMOTE_URL="$CL6_URL" run_cli
  if [ "$CLI_RC" = "NI" ]; then fail "CLI6 placeholder URL not provisioned" "not implemented ($CLI_OUT)"
  elif [ -e "$CL6/.git" ] || [ -e "$CL6/.gitignore" ]; then fail "CLI6 placeholder URL not provisioned" "rc=$CLI_RC created .git/.gitignore out=$CLI_OUT"
  elif [ -s "$GIT_SSH_STUB_LOG" ]; then fail "CLI6 placeholder URL not provisioned" "ssh contacted: $(cat "$GIT_SSH_STUB_LOG")"
  else pass "CLI6 placeholder URL not provisioned (rc=$CLI_RC, no .git, no ssh)"; fi
fi
case_end

case_begin "cli-env-example-copied-config-load" "bin/plan-sync-init"
# .env.example copied verbatim as the fixture agents main root's .env; the env var stays unset so the
# real AGENTS_MAIN_ROOT load path is the only source. CLI9b rewrites the line to prove it is read.
CL9_SAVED_URL="$PLAN_SYNC_REMOTE_URL"; unset PLAN_SYNC_REMOTE_URL
CL9_CFG="$PSF_ROOT/cl9-cfg"; CL9="$PSF_ROOT/cl9-plans"; mkdir -p "$CL9_CFG" "$CL9"
cp "$SCRIPT_CHECKOUT_ROOT/.env.example" "$CL9_CFG/.env"
: > "$GIT_SSH_STUB_LOG"
AGENTS_MAIN_ROOT="$CL9_CFG" WORKFLOW_PLANS_DIR="$CL9" run_cli
expect_rc "CLI9a copied placeholder -> exit 1" 1
expect_has "CLI9a refusal names the placeholder read from the file" "$CLI_OUT" "url-placeholder"
if [ "$CLI_RC" = "NI" ]; then fail "CLI9a nothing written, remote never contacted" "not implemented ($CLI_OUT)"
elif [ -e "$CL9/.git" ] || [ -e "$CL9/.gitignore" ]; then fail "CLI9a nothing written, remote never contacted" "created .git/.gitignore"
elif [ -s "$GIT_SSH_STUB_LOG" ]; then fail "CLI9a nothing written, remote never contacted" "ssh contacted: $(tr '\n' ' ' < "$GIT_SSH_STUB_LOG")"
else pass "CLI9a nothing written, remote never contacted"; fi
CL9B="$PSF_ROOT/cl9b-plans"; mkdir -p "$CL9B"
sed "s#^PLAN_SYNC_REMOTE_URL=.*#PLAN_SYNC_REMOTE_URL=$PSF_ORIGIN_E2E#" "$SCRIPT_CHECKOUT_ROOT/.env.example" > "$CL9_CFG/.env"
AGENTS_MAIN_ROOT="$CL9_CFG" WORKFLOW_PLANS_DIR="$CL9B" run_cli
expect_rc "CLI9b non-placeholder value in the same file provisions -> exit 0" 0
if [ -d "$CL9B/.git" ]; then pass "CLI9b .git created from the file's URL"; else fail "CLI9b .git created from the file's URL" "out=$CLI_OUT"; fi
stub_log_ok "CLI9b ssh request targets the file's /test-owner/test-repo.git"
export PLAN_SYNC_REMOTE_URL="$CL9_SAVED_URL"
case_end

case_begin "cli-remote-url-differs-from-env-warns" "bin/plan-sync-init"
# A successful --remote-url run whose value differs from the .env-resolved PLAN_SYNC_REMOTE_URL
# (empty / unset included) prints one stdout warning line; exit stays 0. Equal values, or no
# --remote-url, print none. The env var is unset so the fixture agents main root's .env is the source.
# The warning is matched loosely: a stdout line starting "plan-sync:" naming PLAN_SYNC_REMOTE_URL and .env.
CLW_SAVED_URL="$PLAN_SYNC_REMOTE_URL"; unset PLAN_SYNC_REMOTE_URL
CLW_CFG="$PSF_ROOT/clw-cfg"; mkdir -p "$CLW_CFG"
# run_cli_stdout [args...] — like run_cli, but CLI_OUT holds stdout only (stderr discarded).
run_cli_stdout() {
  if [ ! -f "$CLI" ]; then CLI_RC=NI; CLI_OUT="NOT_IMPLEMENTED: bin/plan-sync-init missing"; return; fi
  CLI_OUT="$(psf_timeout 60 node "$CLI" "$@" 2>/dev/null)"
  CLI_RC=$?
}
has_env_warning() { printf '%s\n' "$1" | grep '^plan-sync:' | grep -F 'PLAN_SYNC_REMOTE_URL' | grep -qF '.env'; }
# clw_case <id> <.env body> <want: warn|none> [--remote-url]
clw_case() {
  local id="$1" body="$2" want="$3" d="$PSF_ROOT/clw-$1-plans"; shift 3
  mkdir -p "$d"; printf '%s' "$body" > "$CLW_CFG/.env"; setup_ssh_stub "$BARE"
  AGENTS_MAIN_ROOT="$CLW_CFG" WORKFLOW_PLANS_DIR="$d" run_cli_stdout "$@"
  expect_rc "CLIW-$id exit 0" 0
  if [ -n "$(git -C "$d" config --get plansync.version 2>/dev/null)" ]; then pass "CLIW-$id provisioned"
  else fail "CLIW-$id provisioned" "out=$CLI_OUT"; fi
  if has_env_warning "$CLI_OUT"; then got=warn; else got=none; fi
  if [ "$got" = "$want" ]; then pass "CLIW-$id .env mismatch warning on stdout -> $want"
  else fail "CLIW-$id .env mismatch warning on stdout -> $want" "got=$got stdout=$CLI_OUT"; fi
}
clw_case a "PLAN_SYNC_REMOTE_URL=
" warn --remote-url "$PSF_ORIGIN_E2E"
clw_case a2 "OTHER_KEY=1
" warn --remote-url "$PSF_ORIGIN_E2E"
clw_case d "PLAN_SYNC_REMOTE_URL=git@github.com:test-owner/other-repo.git
" warn --remote-url "$PSF_ORIGIN_E2E"
clw_case b "PLAN_SYNC_REMOTE_URL=$PSF_ORIGIN_E2E
" none --remote-url "$PSF_ORIGIN_E2E"
clw_case c "PLAN_SYNC_REMOTE_URL=$PSF_ORIGIN_E2E
" none
# e: differing --remote-url but provisioning fails (unreachable) -> exit 1, no mismatch warning.
CLWE="$PSF_ROOT/clw-e-plans"; mkdir -p "$CLWE"; printf 'PLAN_SYNC_REMOTE_URL=\n' > "$CLW_CFG/.env"
AGENTS_MAIN_ROOT="$CLW_CFG" WORKFLOW_PLANS_DIR="$CLWE" GIT_SSH_COMMAND=false run_cli_stdout --remote-url "$PSF_ORIGIN_DEAD"
expect_rc "CLIW-e unreachable remote -> exit 1" 1
if [ "$CLI_RC" = "NI" ]; then fail "CLIW-e no mismatch warning when provisioning fails" "not implemented ($CLI_OUT)"
elif has_env_warning "$CLI_OUT"; then fail "CLIW-e no mismatch warning when provisioning fails" "stdout=$CLI_OUT"
else pass "CLIW-e no mismatch warning when provisioning fails"; fi
export PLAN_SYNC_REMOTE_URL="$CLW_SAVED_URL"
case_end

# Visibility through the production probe: a gh stub (tests/lib/plan-sync-fixture.sh) answers.
GH_ARGS="api repos/test-owner/test-repo --jq .visibility"
psf_make_gh_stub || fail "gh stub setup" "could not link the node binary as gh"

case_begin "cli-gh-public-refused" "bin/plan-sync-init"
CL7="$PSF_ROOT/cl7-plans"; mkdir -p "$CL7"
: > "$GIT_SSH_STUB_LOG"; : > "$PSF_GH_STUB_LOG"
WORKFLOW_PLANS_DIR="$CL7" psf_with_gh_stub public 0 run_cli
expect_rc "CLI7 public remote -> exit 1" 1
expect_has "CLI7 output names remote-public" "$CLI_OUT" "remote-public"
expect_has "CLI7 gh asked for the repo visibility" "$(cat "$PSF_GH_STUB_LOG" 2>/dev/null)" "$GH_ARGS"
if [ "$CLI_RC" = "NI" ]; then fail "CLI7 nothing written, remote never contacted" "not implemented ($CLI_OUT)"
elif [ -e "$CL7/.git" ] || [ -e "$CL7/.gitignore" ]; then fail "CLI7 nothing written, remote never contacted" "created .git/.gitignore"
elif [ -s "$GIT_SSH_STUB_LOG" ]; then fail "CLI7 nothing written, remote never contacted" "ssh contacted: $(tr '\n' ' ' < "$GIT_SSH_STUB_LOG")"
else pass "CLI7 nothing written, remote never contacted"; fi
case_end

case_begin "cli-gh-private-provisions" "bin/plan-sync-init"
CL8="$PSF_ROOT/cl8-plans"; mkdir -p "$CL8"
: > "$PSF_GH_STUB_LOG"
WORKFLOW_PLANS_DIR="$CL8" psf_with_gh_stub $'private\n' 0 run_cli
expect_rc "CLI8 private remote -> exit 0" 0
expect_has "CLI8 gh asked for the repo visibility" "$(cat "$PSF_GH_STUB_LOG" 2>/dev/null)" "$GH_ARGS"
CL8_VER="$(git -C "$CL8" config --get plansync.version 2>/dev/null)"
if [ -n "$CL8_VER" ]; then pass "CLI8 plansync.version written"; else fail "CLI8 plansync.version written" "out=$CLI_OUT"; fi
case_end

case_begin "cli-args-usage-errors" "bin/plan-sync-init"
# Usage errors exit 2 with a stderr diagnostic, print nothing on stdout, and provision nothing.
# cla_case <id> <stderr needle> [args...]
cla_case() {
  local id="$1" needle="$2" d="$PSF_ROOT/cla-$1-plans" err out rc; shift 2
  mkdir -p "$d"
  if [[ ! -f "$CLI" ]]; then fail "CLA-$id" "not implemented: bin/plan-sync-init missing"; return; fi
  out="$(WORKFLOW_PLANS_DIR="$d" psf_timeout 60 node "$CLI" "$@" 2>"$PSF_ROOT/cla-$id.err")"
  rc=$?
  err="$(cat "$PSF_ROOT/cla-$id.err" 2>/dev/null)"
  if [[ "$rc" == 2 ]]; then pass "CLA-$id exit 2"; else fail "CLA-$id exit 2" "rc=$rc stderr=$err stdout=$out"; fi
  expect_has "CLA-$id stderr names the usage error" "$err" "$needle"
  if [[ -z "$out" ]]; then pass "CLA-$id stdout empty"; else fail "CLA-$id stdout empty" "stdout=$out"; fi
  if [[ ! -e "$d/.git" && ! -e "$d/.gitignore" ]]; then pass "CLA-$id nothing provisioned"
  else fail "CLA-$id nothing provisioned" "created .git/.gitignore in $d"; fi
}
# Rows: "<id>|<stderr needle>|<space-separated args>"; @URL@ / @URL2@ expand to distinct placeholder URLs.
unset CLAUDE_CODE_ENTRYPOINT
CLA_ROWS=(
  "1|plan-sync-init: --remote-url needs a value|--remote-url"
  "2|unknown argument: --bogus|--bogus"
  "3|unknown argument: extra|--remote-url @URL@ extra"
  "4|--remote-url given more than once|--remote-url @URL@ --remote-url @URL@"
  "5|--remote-url needs a value|--remote-url --bogus"
  "6|--remote-url given more than once|--remote-url @URL@ --remote-url @URL2@"
)
for cla_row in "${CLA_ROWS[@]}"; do
  IFS='|' read -r cla_id cla_needle cla_argstr <<< "$cla_row"
  read -r -a cla_args <<< "$cla_argstr"
  for cla_i in "${!cla_args[@]}"; do
    case "${cla_args[$cla_i]}" in
      @URL@) cla_args[cla_i]="$PSF_ORIGIN_E2E" ;;
      @URL2@) cla_args[cla_i]="${PSF_ORIGIN_E2E}-other" ;;
    esac
  done
  cla_case "$cla_id" "$cla_needle" "${cla_args[@]}"
done
case_end

# Interactive mode (#2513 4d): own fragment to keep this file under the split threshold.
# shellcheck source=feature-2513-plan-sync-e2e/plan-sync-init-interactive.sh
. "$AGENTS_DIR/tests/hooks/feature-2513-plan-sync-e2e/plan-sync-init-interactive.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
