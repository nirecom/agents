# Tests: bin/plan-sync-init
# Tags: plan-sync, interactive, scope:common
# bin/plan-sync-init interactive mode (#2513 4d). Sourced by ../feature-2513-plan-sync-e2e.sh
# (needs harness pass/fail/case_*, psf_* helpers, CLI, PSF_ROOT, expect_has, psf_drop_gh_from_path).
# Seam: PLAN_SYNC_INIT_ASSUME_TTY=1 makes the CLI treat stdin as a TTY; answers are stdin lines.
# gh is a node link answered by ./gh-dispatch-preload.js; git ssh goes to the ssh stub serving
# test-owner/agent-plans.git. The real gh never runs (psf_drop_gh_from_path already applied).
# Assumed proposed remote: git@github.com:test-owner/agent-plans.git (scp form, as in .env.example);
# the written .env value is matched against the scp and ssh:// GitHub forms of that repo.

IA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IA_PRELOAD="$(psf_np "$IA_DIR/gh-dispatch-preload.js")"
IA_GH_DIR="$PSF_ROOT/gh-dispatch"
mkdir -p "$IA_GH_DIR"
IA_NODE="$(node -p 'process.execPath')"
for ia_n in gh gh.exe; do
  [ -e "$IA_GH_DIR/$ia_n" ] || ln "$IA_NODE" "$IA_GH_DIR/$ia_n" 2>/dev/null || cp "$IA_NODE" "$IA_GH_DIR/$ia_n"
done
IA_GH_PATH="$(psf_up "$IA_GH_DIR")"
IA_URL_RE='^PLAN_SYNC_REMOTE_URL=(git@github\.com:|ssh://git@github\.com/)test-owner/agent-plans(\.git)?$'
IA_CREATE='["repo","create","test-owner/agent-plans","--private"]'

# ia_run <id> <gh: on|off> <answers> [VAR=val...] — runs the CLI in a subshell with a fresh
# plans dir / config dir / bare (unless IA_KEEP=1), env PLAN_SYNC_REMOTE_URL unset so the
# config dir .env is the only source. Sets IA_RC, IA_OUT, IA_LOG (gh argv JSON lines),
# IA_PLANS, IA_CFG, IA_BARE.
ia_run() {
  local id="$1" gh="$2" answers="$3"
  shift 3
  IA_PLANS="$PSF_ROOT/ia-$id-plans"; IA_CFG="$PSF_ROOT/ia-$id-cfg"; IA_BARE="$PSF_ROOT/ia-$id-bare.git"
  IA_LOGF="$PSF_ROOT/ia-$id-gh.log"; IA_STATE="$PSF_ROOT/ia-$id-gh.state"
  mkdir -p "$IA_PLANS" "$IA_CFG"
  [ -d "$IA_BARE" ] || psf_make_bare "$IA_BARE" >/dev/null 2>&1
  : > "$IA_LOGF"
  if [ ! -f "$CLI" ]; then IA_RC=NI; IA_OUT="NOT_IMPLEMENTED: bin/plan-sync-init missing"; IA_LOG=""; return; fi
  IA_OUT="$(
    unset PLAN_SYNC_REMOTE_URL
    export AGENTS_CONFIG_DIR="$IA_CFG" WORKFLOW_PLANS_DIR="$IA_PLANS" PLAN_SYNC_INIT_ASSUME_TTY=1
    export GH_DISPATCH_LOG="$IA_LOGF" GH_DISPATCH_STATE="$IA_STATE" GH_DISPATCH_LOGIN=test-owner GH_DISPATCH_REPO=absent
    setup_ssh_stub "$IA_BARE"
    export GIT_SSH_STUB_REPO=test-owner/agent-plans.git
    for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
    if [ "$gh" = on ]; then
      export PATH="$IA_GH_PATH:$PATH" NODE_OPTIONS="--require \"$IA_PRELOAD\""
    fi
    printf '%s' "$answers" | psf_timeout 60 node "$CLI" 2>&1
  )"
  IA_RC=$?
  IA_LOG="$(cat "$IA_LOGF" 2>/dev/null)"
}

# ia_env_line — prints the PLAN_SYNC_REMOTE_URL line of the case's .env (empty if none).
ia_env_line() { grep -m1 '^PLAN_SYNC_REMOTE_URL=' "$IA_CFG/.env" 2>/dev/null; }

# ia_no_create <name> — gh repo create was never called.
ia_no_create() {
  case "$IA_LOG" in
    *'"repo","create"'*) fail "$1" "repo create called: $IA_LOG" ;;
    *) pass "$1" ;;
  esac
}

# ia_provisioned <name> — the plans dir carries plansync.version.
ia_provisioned() {
  if [ -n "$(git -C "$IA_PLANS" config --get plansync.version 2>/dev/null)" ]; then pass "$1"
  else fail "$1" "rc=$IA_RC out=$IA_OUT"; fi
}

# ia_env_replaced <name> <original .env body> — the URL line replaced in place, rest byte-identical.
ia_env_replaced() {
  local line want got
  line="$(ia_env_line)"
  if ! printf '%s\n' "$line" | grep -Eq "$IA_URL_RE"; then fail "$1" "line=$(printf '%q' "$line") out=$IA_OUT"; return; fi
  want="$(printf '%s' "$2" | sed "s#^PLAN_SYNC_REMOTE_URL=.*#$line#"; printf 'x')"
  got="$(cat "$IA_CFG/.env"; printf 'x')"
  if [ "$got" = "$want" ]; then pass "$1"; else fail "$1" "got=$(printf '%q' "$got") want=$(printf '%q' "$want")"; fi
}

case_begin "init-interactive-non-tty-legacy" "bin/plan-sync-init"
IA_PLANS="$PSF_ROOT/ia-ntty-plans"; IA_CFG="$PSF_ROOT/ia-ntty-cfg"; mkdir -p "$IA_PLANS" "$IA_CFG"
: > "$PSF_ROOT/ia-ntty-gh.log"
IA_OUT="$(
  unset PLAN_SYNC_REMOTE_URL PLAN_SYNC_INIT_ASSUME_TTY
  export AGENTS_CONFIG_DIR="$IA_CFG" WORKFLOW_PLANS_DIR="$IA_PLANS" GH_DISPATCH_LOG="$PSF_ROOT/ia-ntty-gh.log"
  export PATH="$IA_GH_PATH:$PATH" NODE_OPTIONS="--require \"$IA_PRELOAD\""
  printf 'y\ny\n' | psf_timeout 60 node "$CLI" 2>&1
)"
IA_RC=$?
if [ "$IA_RC" = 0 ]; then pass "IA1 non-interactive -> exit 0"; else fail "IA1 non-interactive -> exit 0" "rc=$IA_RC out=$IA_OUT"; fi
expect_has "IA1 non-interactive -> legacy not configured" "$IA_OUT" "plan-sync: not configured"
if [ ! -s "$PSF_ROOT/ia-ntty-gh.log" ]; then pass "IA1 non-interactive -> gh never called"
else fail "IA1 non-interactive -> gh never called" "$(cat "$PSF_ROOT/ia-ntty-gh.log")"; fi
case_end

case_begin "init-interactive-no-gh" "bin/plan-sync-init"
ia_run nogh off $'y\ny\n'
expect_has "IA2 no gh -> guidance names gh" "$IA_OUT" "gh"
expect_has "IA2 no gh -> falls back to legacy not configured" "$IA_OUT" "plan-sync: not configured"
if [ "$IA_RC" = 0 ]; then pass "IA2 no gh -> exit 0"; else fail "IA2 no gh -> exit 0" "rc=$IA_RC out=$IA_OUT"; fi
if [ ! -e "$IA_PLANS/.git" ] && [ ! -e "$IA_CFG/.env" ]; then pass "IA2 no gh -> nothing provisioned or written"
else fail "IA2 no gh -> nothing provisioned or written" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-gh-unauthenticated" "bin/plan-sync-init"
ia_run noauth on $'y\ny\n' GH_DISPATCH_AUTH=no
if printf '%s' "$IA_OUT" | grep -qi 'auth'; then pass "IA3 unauthenticated -> guidance mentions auth"
else fail "IA3 unauthenticated -> guidance mentions auth" "out=$IA_OUT"; fi
expect_has "IA3 unauthenticated -> falls back to legacy not configured" "$IA_OUT" "plan-sync: not configured"
ia_no_create "IA3 unauthenticated -> no repo create"
if [ ! -e "$IA_PLANS/.git" ] && [ ! -e "$IA_CFG/.env" ]; then pass "IA3 unauthenticated -> nothing provisioned or written"
else fail "IA3 unauthenticated -> nothing provisioned or written" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-absent-create-and-write" "bin/plan-sync-init"
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\nB=2\n'
mkdir -p "$PSF_ROOT/ia-create-cfg"; printf '%s' "$IA_BODY" > "$PSF_ROOT/ia-create-cfg/.env"
ia_run create on $'y\ny\n'
expect_has "IA4 gh api user asked for the login" "$IA_LOG" '"api","user"'
expect_has "IA4 proposal names test-owner/agent-plans" "$IA_OUT" "test-owner/agent-plans"
if printf '%s\n' "$IA_LOG" | grep -qxF "$IA_CREATE"; then pass "IA4 gh repo create test-owner/agent-plans --private (exact args)"
else fail "IA4 gh repo create test-owner/agent-plans --private (exact args)" "log=$IA_LOG out=$IA_OUT"; fi
if [ "$IA_RC" = 0 ]; then pass "IA4 exit 0"; else fail "IA4 exit 0" "rc=$IA_RC out=$IA_OUT"; fi
ia_provisioned "IA4 plans dir provisioned"
ia_env_replaced "IA4 empty PLAN_SYNC_REMOTE_URL line replaced, other lines byte-identical" "$IA_BODY"
IA_AFTER="$(cat "$IA_CFG/.env" 2>/dev/null; printf 'x')"
# IA5 is meaningful only after IA4 wrote the URL (else "unchanged" holds vacuously).
if printf '%s' "$IA_AFTER" | grep -Eq "${IA_URL_RE%\$}"; then pass "IA5 precondition: IA4 wrote the URL line"
else fail "IA5 precondition: IA4 wrote the URL line" "env=$(printf '%q' "$IA_AFTER")"; fi
ia_run create on $'y\ny\n'
IA_AGAIN="$(cat "$IA_CFG/.env" 2>/dev/null; printf 'x')"
if [ "$IA_AFTER" = "$IA_AGAIN" ]; then pass "IA5 rerun leaves .env byte-identical (idempotent)"
else fail "IA5 rerun leaves .env byte-identical (idempotent)" "before=$(printf '%q' "$IA_AFTER") after=$(printf '%q' "$IA_AGAIN")"; fi
ia_no_create "IA5 rerun -> no second repo create"
if [ "$IA_RC" = 0 ]; then pass "IA5 rerun exit 0"; else fail "IA5 rerun exit 0" "rc=$IA_RC out=$IA_OUT"; fi
case_end

case_begin "init-interactive-absent-declined" "bin/plan-sync-init"
mkdir -p "$PSF_ROOT/ia-decl-cfg"; printf 'A=1\n' > "$PSF_ROOT/ia-decl-cfg/.env"
ia_run decl on $'n\nn\n'
expect_has "IA6 absent + N -> the repo was looked up" "$IA_LOG" "agent-plans"
ia_no_create "IA6 absent + N -> no repo create"
if [ ! -e "$IA_PLANS/.git" ] && [ "$(cat "$IA_CFG/.env")" = "A=1" ]; then pass "IA6 absent + N -> nothing provisioned, .env untouched"
else fail "IA6 absent + N -> nothing provisioned, .env untouched" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-private-no-write" "bin/plan-sync-init"
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\n'
mkdir -p "$PSF_ROOT/ia-priv-cfg"; printf '%s' "$IA_BODY" > "$PSF_ROOT/ia-priv-cfg/.env"
ia_run priv on $'y\nn\n' GH_DISPATCH_REPO=private
ia_no_create "IA7 existing private repo -> no repo create"
ia_provisioned "IA7 existing private repo used -> provisioned"
if printf '%s\n' "$IA_OUT" | grep -Eq "${IA_URL_RE#^}"; then pass "IA7 .env write declined -> the line is printed"
else fail "IA7 .env write declined -> the line is printed" "out=$IA_OUT"; fi
if [ "$(cat "$IA_CFG/.env"; printf 'x')" = "${IA_BODY}x" ]; then pass "IA7 .env write declined -> .env byte-identical"
else fail "IA7 .env write declined -> .env byte-identical" "env=$(printf '%q' "$(cat "$IA_CFG/.env")")"; fi
case_end

case_begin "init-interactive-private-declined" "bin/plan-sync-init"
# Assumption: declining "use the existing private repo" is a user choice, not an error -> exit 0,
# nothing provisioned, .env untouched (mirrors the absent + N path).
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\n'
mkdir -p "$PSF_ROOT/ia-privn-cfg"; printf '%s' "$IA_BODY" > "$PSF_ROOT/ia-privn-cfg/.env"
ia_run privn on $'n\nn\n' GH_DISPATCH_REPO=private
expect_has "IA12 private repo + N -> the repo was looked up" "$IA_LOG" "agent-plans"
ia_no_create "IA12 private repo + N -> no repo create"
if [ "$IA_RC" = 0 ]; then pass "IA12 private repo + N -> exit 0"; else fail "IA12 private repo + N -> exit 0" "rc=$IA_RC out=$IA_OUT"; fi
if [ ! -e "$IA_PLANS/.git" ] && [ "$(cat "$IA_CFG/.env"; printf 'x')" = "${IA_BODY}x" ]; then
  pass "IA12 private repo + N -> nothing provisioned, .env byte-identical"
else fail "IA12 private repo + N -> nothing provisioned, .env byte-identical" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-configured-url-skips-prompt" "bin/plan-sync-init"
# A real (non-placeholder) URL is already configured: even with a TTY the CLI must not prompt,
# make no interactive gh call (api user / repo create; the repos/<owner>/agent-plans visibility
# query stays allowed as the public-repo guard), keep .env byte-identical, and still provision.
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=ssh://git@github.com/test-owner/agent-plans.git\nB=2\n'
mkdir -p "$PSF_ROOT/ia-conf-cfg"; printf '%s' "$IA_BODY" > "$PSF_ROOT/ia-conf-cfg/.env"
ia_run conf on $'y\ny\n'
if [ "$IA_RC" = 0 ]; then pass "IA13 configured URL -> exit 0"; else fail "IA13 configured URL -> exit 0" "rc=$IA_RC out=$IA_OUT"; fi
case "$IA_RC|$IA_LOG" in
  NI\|*|*'"api","user"'*|*'"repo","create"'*) fail "IA13 configured URL -> no interactive gh call (api user / repo create)" "rc=$IA_RC log=$IA_LOG" ;;
  *) pass "IA13 configured URL -> no interactive gh call (api user / repo create)" ;;
esac
if [ "$(cat "$IA_CFG/.env"; printf 'x')" = "${IA_BODY}x" ]; then pass "IA13 configured URL -> .env byte-identical"
else fail "IA13 configured URL -> .env byte-identical" "env=$(printf '%q' "$(cat "$IA_CFG/.env")")"; fi
ia_provisioned "IA13 configured URL -> provisioning still runs"
case_end

case_begin "init-interactive-create-fails" "bin/plan-sync-init"
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\n'
mkdir -p "$PSF_ROOT/ia-cfail-cfg"; printf '%s' "$IA_BODY" > "$PSF_ROOT/ia-cfail-cfg/.env"
ia_run cfail on $'y\ny\n' GH_DISPATCH_CREATE=fail
# The no-provision / .env checks only mean something once the create was really attempted;
# without that they would pass vacuously on a CLI that never prompts.
IA14_TRIED=no
if printf '%s\n' "$IA_LOG" | grep -qxF "$IA_CREATE"; then IA14_TRIED=yes; pass "IA14 precondition: gh repo create was attempted"
else fail "IA14 precondition: gh repo create was attempted" "log=$IA_LOG out=$IA_OUT"; fi
if [ "$IA_RC" != NI ] && [ "$IA_RC" != 0 ]; then pass "IA14 repo create fails -> non-zero exit"
else fail "IA14 repo create fails -> non-zero exit" "rc=$IA_RC out=$IA_OUT"; fi
if [ "$IA14_TRIED" = yes ] && [ ! -e "$IA_PLANS/.git" ] && [ ! -e "$IA_PLANS/.gitignore" ]; then pass "IA14 repo create fails -> nothing provisioned"
else fail "IA14 repo create fails -> nothing provisioned" "tried=$IA14_TRIED out=$IA_OUT"; fi
if [ "$IA14_TRIED" = yes ] && [ "$(cat "$IA_CFG/.env"; printf 'x')" = "${IA_BODY}x" ]; then pass "IA14 repo create fails -> .env byte-identical"
else fail "IA14 repo create fails -> .env byte-identical" "tried=$IA14_TRIED env=$(printf '%q' "$(cat "$IA_CFG/.env")")"; fi
case_end

case_begin "init-interactive-public-refused" "bin/plan-sync-init"
IA_BODY=$'PLAN_SYNC_REMOTE_URL=\n'
mkdir -p "$PSF_ROOT/ia-pub-cfg"; printf '%s' "$IA_BODY" > "$PSF_ROOT/ia-pub-cfg/.env"
ia_run pub on $'y\ny\n' GH_DISPATCH_REPO=public
if [ "$IA_RC" != NI ] && [ "$IA_RC" != 0 ]; then pass "IA8 existing public repo -> non-zero exit"
else fail "IA8 existing public repo -> non-zero exit" "rc=$IA_RC out=$IA_OUT"; fi
ia_no_create "IA8 existing public repo -> no repo create"
if [ ! -e "$IA_PLANS/.git" ] && [ ! -e "$IA_PLANS/.gitignore" ] && [ "$(cat "$IA_CFG/.env"; printf 'x')" = "${IA_BODY}x" ]; then
  pass "IA8 existing public repo -> nothing provisioned, .env untouched"
else fail "IA8 existing public repo -> nothing provisioned, .env untouched" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-placeholder-replaced" "bin/plan-sync-init"
IA_BODY=$'X=1\nPLAN_SYNC_REMOTE_URL=git@github.com:YOUR_USERNAME/agent-plans.git\nY=2\n'
mkdir -p "$PSF_ROOT/ia-ph-cfg"; printf '%s' "$IA_BODY" > "$PSF_ROOT/ia-ph-cfg/.env"
ia_run ph on $'y\ny\n'
ia_provisioned "IA9 placeholder .env -> interactive flow provisions"
ia_env_replaced "IA9 placeholder line replaced in place, other lines byte-identical" "$IA_BODY"
case_end

case_begin "init-interactive-line-appended" "bin/plan-sync-init"
mkdir -p "$PSF_ROOT/ia-app-cfg"; printf 'X=1\n' > "$PSF_ROOT/ia-app-cfg/.env"
ia_run app on $'y\ny\n'
IA_GOT="$(cat "$IA_CFG/.env" 2>/dev/null)"
IA_TAIL="${IA_GOT#X=1$'\n'}"
if [ "$IA_TAIL" != "$IA_GOT" ] && printf '%s\n' "$IA_TAIL" | grep -Eq "$IA_URL_RE" && [ "$(printf '%s\n' "$IA_TAIL" | wc -l)" -eq 1 ]; then
  pass "IA10 no PLAN_SYNC_REMOTE_URL line -> appended after the existing lines"
else fail "IA10 no PLAN_SYNC_REMOTE_URL line -> appended after the existing lines" "env=$(printf '%q' "$IA_GOT") out=$IA_OUT"; fi
case_end

case_begin "init-interactive-login-metachar-inert" "bin/plan-sync-init"
IA_CANARY="$PSF_ROOT/ia-canary"
IA_EVIL="evil\$(echo x>$IA_CANARY)&echo x>$IA_CANARY;echo x>$IA_CANARY|\`echo x>$IA_CANARY\`"
ia_run evil on $'y\ny\nn\n' GH_DISPATCH_LOGIN="$IA_EVIL"
expect_has "IA11 metachar login -> gh api user was called" "$IA_LOG" '"api","user"'
if [ ! -e "$IA_CANARY" ]; then pass "IA11 metachar login -> never shell-interpreted (no canary)"
else fail "IA11 metachar login -> never shell-interpreted (no canary)" "canary created; out=$IA_OUT"; fi
case_end
