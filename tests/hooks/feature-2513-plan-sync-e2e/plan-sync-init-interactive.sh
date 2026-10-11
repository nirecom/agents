# Tests: bin/plan-sync-init, hooks/lib/plan-sync/init-interactive.js
# Tags: plan-sync, interactive, env-write, gh-stub, scope:issue-specific
# shellcheck shell=bash
# bin/plan-sync-init interactive mode (#2513 G5). Sourced by ../feature-2513-plan-sync-e2e.sh
# (needs harness pass/fail/case_*, psf_* helpers, CLI, PSF_ROOT, expect_has, psf_drop_gh_from_path).
# Seam: PLAN_SYNC_INIT_ASSUME_TTY=1 makes the CLI treat stdin as a TTY; answers are stdin lines.
# gh is a node link answered by ./gh-dispatch-preload.js; git ssh goes to the ssh stub serving
# test-owner/agent-plans.git. The .env read and written is $AGENTS_MAIN_ROOT/.env (a fixture dir).
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
IA_TPL="git@github.com:YOUR_USERNAME/agent-plans.git"

# ia_run <id> <gh: on|off> <answers> [VAR=val...] — runs the CLI in a subshell with a fresh
# plans dir / bare; the agents main root is $PSF_ROOT/ia-<id>-cfg, env PLAN_SYNC_REMOTE_URL is
# unset (a VAR=val may export it again). Sets IA_RC, IA_OUT, IA_LOG (gh argv JSON lines),
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
    export AGENTS_MAIN_ROOT="$IA_CFG" WORKFLOW_PLANS_DIR="$IA_PLANS" PLAN_SYNC_INIT_ASSUME_TTY=1
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
ia_env_same() { [ "$(cat "$IA_CFG/.env" 2>/dev/null; printf 'x')" = "${1}x" ]; }
ia_rc() { if [ "$IA_RC" = "$2" ]; then pass "$1"; else fail "$1" "rc=$IA_RC want=$2 out=$IA_OUT"; fi; }
ia_rc_nonzero() { if [ "$IA_RC" != NI ] && [ "$IA_RC" != 0 ]; then pass "$1"; else fail "$1" "rc=$IA_RC out=$IA_OUT"; fi; }

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

# ia_seed <id> <body> — the case's agents main root .env before the run.
ia_seed() { mkdir -p "$PSF_ROOT/ia-$1-cfg"; printf '%s' "$2" > "$PSF_ROOT/ia-$1-cfg/.env"; }

case_begin "init-interactive-non-tty-legacy" "bin/plan-sync-init"
IA_PLANS="$PSF_ROOT/ia-ntty-plans"; IA_CFG="$PSF_ROOT/ia-ntty-cfg"; mkdir -p "$IA_PLANS" "$IA_CFG"
: > "$PSF_ROOT/ia-ntty-gh.log"
IA_OUT="$(
  unset PLAN_SYNC_REMOTE_URL PLAN_SYNC_INIT_ASSUME_TTY
  export AGENTS_MAIN_ROOT="$IA_CFG" WORKFLOW_PLANS_DIR="$IA_PLANS" GH_DISPATCH_LOG="$PSF_ROOT/ia-ntty-gh.log"
  export PATH="$IA_GH_PATH:$PATH" NODE_OPTIONS="--require \"$IA_PRELOAD\""
  printf 'y\ny\n' | psf_timeout 60 node "$CLI" 2>&1
)"
IA_RC=$?
ia_rc "IA1 non-interactive -> exit 0" 0
expect_has "IA1 non-interactive -> legacy not configured" "$IA_OUT" "plan-sync: not configured"
if [ ! -s "$PSF_ROOT/ia-ntty-gh.log" ]; then pass "IA1 non-interactive -> gh never called"
else fail "IA1 non-interactive -> gh never called" "$(cat "$PSF_ROOT/ia-ntty-gh.log")"; fi
case_end

case_begin "init-interactive-no-gh" "bin/plan-sync-init"
ia_run nogh off $'y\ny\n'
expect_has "IA2 no gh -> guidance names gh" "$IA_OUT" "gh"
expect_has "IA2 no gh -> falls back to legacy not configured" "$IA_OUT" "plan-sync: not configured"
ia_rc "IA2 no gh -> exit 0" 0
if [ "$IA_RC" != NI ] && [ ! -e "$IA_PLANS/.git" ] && [ ! -e "$IA_CFG/.env" ]; then pass "IA2 no gh -> nothing provisioned or written"
else fail "IA2 no gh -> nothing provisioned or written" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-gh-unauthenticated" "bin/plan-sync-init"
ia_run noauth on $'y\ny\n' GH_DISPATCH_AUTH=no
if printf '%s' "$IA_OUT" | grep -qi 'auth'; then pass "IA3 unauthenticated -> guidance mentions auth"
else fail "IA3 unauthenticated -> guidance mentions auth" "out=$IA_OUT"; fi
expect_has "IA3 unauthenticated -> falls back to legacy not configured" "$IA_OUT" "plan-sync: not configured"
ia_no_create "IA3 unauthenticated -> no repo create"
if [ "$IA_RC" != NI ] && [ ! -e "$IA_PLANS/.git" ] && [ ! -e "$IA_CFG/.env" ]; then pass "IA3 unauthenticated -> nothing provisioned or written"
else fail "IA3 unauthenticated -> nothing provisioned or written" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-absent-create-and-write" "bin/plan-sync-init"
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\nB=2\n'
ia_seed create "$IA_BODY"
ia_run create on $'y\ny\n'
expect_has "IA4 gh api user asked for the login" "$IA_LOG" '"api","user"'
expect_has "IA4 proposal names test-owner/agent-plans" "$IA_OUT" "test-owner/agent-plans"
if printf '%s\n' "$IA_LOG" | grep -qxF "$IA_CREATE"; then pass "IA4 gh repo create test-owner/agent-plans --private (exact args)"
else fail "IA4 gh repo create test-owner/agent-plans --private (exact args)" "log=$IA_LOG out=$IA_OUT"; fi
ia_rc "IA4 exit 0" 0
ia_provisioned "IA4 plans dir provisioned"
ia_env_replaced "IA4 empty PLAN_SYNC_REMOTE_URL line replaced, other lines byte-identical" "$IA_BODY"
if [ -z "$(find "$IA_CFG" -mindepth 1 -maxdepth 1 ! -name .env 2>/dev/null)" ]; then pass "IA4 the atomic write leaves no temp file beside .env"
else fail "IA4 the atomic write leaves no temp file beside .env" "$(ls -A "$IA_CFG")"; fi
IA_AFTER="$(cat "$IA_CFG/.env" 2>/dev/null; printf 'x')"
# IA5 is meaningful only after IA4 wrote the URL (else "unchanged" holds vacuously).
if printf '%s' "$IA_AFTER" | grep -Eq "${IA_URL_RE%\$}"; then pass "IA5 precondition: IA4 wrote the URL line"
else fail "IA5 precondition: IA4 wrote the URL line" "env=$(printf '%q' "$IA_AFTER")"; fi
ia_run create on $'y\ny\n'
IA_AGAIN="$(cat "$IA_CFG/.env" 2>/dev/null; printf 'x')"
if [ "$IA_AFTER" = "$IA_AGAIN" ]; then pass "IA5 rerun leaves .env byte-identical (idempotent)"
else fail "IA5 rerun leaves .env byte-identical (idempotent)" "before=$(printf '%q' "$IA_AFTER") after=$(printf '%q' "$IA_AGAIN")"; fi
ia_no_create "IA5 rerun -> no second repo create"
ia_rc "IA5 rerun exit 0" 0
case_end

case_begin "init-interactive-absent-declined" "bin/plan-sync-init"
ia_seed decl $'A=1\n'
ia_run decl on $'n\nn\n'
expect_has "IA6 absent + N -> the repo was looked up" "$IA_LOG" "agent-plans"
ia_no_create "IA6 absent + N -> no repo create"
if [ ! -e "$IA_PLANS/.git" ] && ia_env_same $'A=1\n'; then pass "IA6 absent + N -> nothing provisioned, .env untouched"
else fail "IA6 absent + N -> nothing provisioned, .env untouched" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-private-no-write" "bin/plan-sync-init"
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\n'
ia_seed priv "$IA_BODY"
ia_run priv on $'y\nn\n' GH_DISPATCH_REPO=private
ia_no_create "IA7 existing private repo -> no repo create"
ia_provisioned "IA7 existing private repo used -> provisioned"
if printf '%s\n' "$IA_OUT" | grep -Eq "${IA_URL_RE#^}"; then pass "IA7 .env write declined -> the line is printed"
else fail "IA7 .env write declined -> the line is printed" "out=$IA_OUT"; fi
if ia_env_same "$IA_BODY"; then pass "IA7 .env write declined -> .env byte-identical"
else fail "IA7 .env write declined -> .env byte-identical" "env=$(printf '%q' "$(cat "$IA_CFG/.env")")"; fi
case_end

case_begin "init-interactive-private-declined" "bin/plan-sync-init"
# Declining "use the existing private repo" is a user choice, not an error -> exit 0,
# nothing provisioned, .env untouched (mirrors the absent + N path).
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\n'
ia_seed privn "$IA_BODY"
ia_run privn on $'n\nn\n' GH_DISPATCH_REPO=private
expect_has "IA12 private repo + N -> the repo was looked up" "$IA_LOG" "agent-plans"
ia_no_create "IA12 private repo + N -> no repo create"
ia_rc "IA12 private repo + N -> exit 0" 0
if [ ! -e "$IA_PLANS/.git" ] && ia_env_same "$IA_BODY"; then pass "IA12 private repo + N -> nothing provisioned, .env byte-identical"
else fail "IA12 private repo + N -> nothing provisioned, .env byte-identical" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-configured-url-skips-prompt" "bin/plan-sync-init"
# A real (non-placeholder) URL is already configured: even with a TTY the CLI must not prompt,
# make no interactive gh call (api user / repo create; the repos/<owner>/agent-plans visibility
# query stays allowed as the public-repo guard), keep .env byte-identical, and still provision.
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=ssh://git@github.com/test-owner/agent-plans.git\nB=2\n'
ia_seed conf "$IA_BODY"
ia_run conf on $'y\ny\n'
ia_rc "IA13 configured URL -> exit 0" 0
case "$IA_RC|$IA_LOG" in
  NI\|*|*'"api","user"'*|*'"repo","create"'*) fail "IA13 configured URL -> no interactive gh call (api user / repo create)" "rc=$IA_RC log=$IA_LOG" ;;
  *) pass "IA13 configured URL -> no interactive gh call (api user / repo create)" ;;
esac
if ia_env_same "$IA_BODY"; then pass "IA13 configured URL -> .env byte-identical"
else fail "IA13 configured URL -> .env byte-identical" "env=$(printf '%q' "$(cat "$IA_CFG/.env")")"; fi
ia_provisioned "IA13 configured URL -> provisioning still runs"
case_end

case_begin "init-interactive-create-fails" "bin/plan-sync-init"
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\n'
ia_seed cfail "$IA_BODY"
ia_run cfail on $'y\ny\n' GH_DISPATCH_CREATE=fail
# The no-provision / .env checks only mean something once the create was really attempted.
IA14_TRIED=no
if printf '%s\n' "$IA_LOG" | grep -qxF "$IA_CREATE"; then IA14_TRIED=yes; pass "IA14 precondition: gh repo create was attempted"
else fail "IA14 precondition: gh repo create was attempted" "log=$IA_LOG out=$IA_OUT"; fi
ia_rc_nonzero "IA14 repo create fails -> non-zero exit"
if [ "$IA14_TRIED" = yes ] && [ ! -e "$IA_PLANS/.git" ] && [ ! -e "$IA_PLANS/.gitignore" ]; then pass "IA14 repo create fails -> nothing provisioned"
else fail "IA14 repo create fails -> nothing provisioned" "tried=$IA14_TRIED out=$IA_OUT"; fi
if [ "$IA14_TRIED" = yes ] && ia_env_same "$IA_BODY"; then pass "IA14 repo create fails -> .env byte-identical"
else fail "IA14 repo create fails -> .env byte-identical" "tried=$IA14_TRIED env=$(printf '%q' "$(cat "$IA_CFG/.env")")"; fi
case_end

case_begin "init-interactive-open-visibility-refused" "bin/plan-sync-init"
for ia_vis in public internal; do
  IA_BODY=$'PLAN_SYNC_REMOTE_URL=\n'
  ia_seed "open-$ia_vis" "$IA_BODY"
  ia_run "open-$ia_vis" on $'y\ny\n' GH_DISPATCH_REPO="$ia_vis"
  ia_rc_nonzero "IA8 existing $ia_vis repo -> non-zero exit"
  ia_no_create "IA8 existing $ia_vis repo -> no repo create"
  if [ ! -e "$IA_PLANS/.git" ] && [ ! -e "$IA_PLANS/.gitignore" ] && ia_env_same "$IA_BODY"; then
    pass "IA8 existing $ia_vis repo -> nothing provisioned, .env untouched"
  else fail "IA8 existing $ia_vis repo -> nothing provisioned, .env untouched" "out=$IA_OUT"; fi
done
case_end

case_begin "init-interactive-placeholder-replaced" "bin/plan-sync-init"
IA_BODY=$'X=1\nPLAN_SYNC_REMOTE_URL='"$IA_TPL"$'\nY=2\nPLAN_SYNC_REMOTE_URL='"$IA_TPL"$'\n'
ia_seed ph "$IA_BODY"
ia_run ph on $'y\ny\n'
ia_provisioned "IA9 placeholder .env -> interactive flow provisions"
IA_GOT="$(cat "$IA_CFG/.env" 2>/dev/null)"
IA9_LINES="$(printf '%s\n' "$IA_GOT" | grep -c '^PLAN_SYNC_REMOTE_URL=')"
IA9_GOOD="$(printf '%s\n' "$IA_GOT" | grep -cE "$IA_URL_RE")"
if [ "$IA9_LINES" -ge 1 ] && [ "$IA9_LINES" = "$IA9_GOOD" ]; then pass "IA9 every PLAN_SYNC_REMOTE_URL line now holds the login's URL"
else fail "IA9 every PLAN_SYNC_REMOTE_URL line now holds the login's URL" "env=$(printf '%q' "$IA_GOT")"; fi
if printf '%s\n' "$IA_GOT" | grep -qx 'X=1' && printf '%s\n' "$IA_GOT" | grep -qx 'Y=2'; then pass "IA9 other lines kept"
else fail "IA9 other lines kept" "env=$(printf '%q' "$IA_GOT")"; fi
case_end

case_begin "init-interactive-line-appended" "bin/plan-sync-init"
ia_seed app $'X=1\n'
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
ia_no_create "IA11 metachar login -> rejected before any repo create"
if [ ! -e "$IA_CANARY" ]; then pass "IA11 metachar login -> never shell-interpreted (no canary)"
else fail "IA11 metachar login -> never shell-interpreted (no canary)" "canary created; out=$IA_OUT"; fi
case_end

# Export precedence (detail G5): the template URL exported in the shell outranks .env.
case_begin "init-interactive-exported-template-notice" "bin/plan-sync-init"
IA_BODY=$'A=1\nPLAN_SYNC_REMOTE_URL=\n'
ia_seed expw "$IA_BODY"
ia_run expw on $'y\ny\n' PLAN_SYNC_REMOTE_URL="$IA_TPL"
expect_has "IA15 exported template -> the prompt still ran (gh api user)" "$IA_LOG" '"api","user"'
if printf '%s' "$IA_OUT" | grep -F 'PLAN_SYNC_REMOTE_URL' | grep -qiE 'environment|export'; then
  pass "IA15 exported template -> notice that the environment variable outranks .env"
else fail "IA15 exported template -> notice that the environment variable outranks .env" "out=$IA_OUT"; fi
ia_provisioned "IA15 exported template -> repo create and provisioning still run"
ia_env_replaced "IA15 exported template + y -> .env still written" "$IA_BODY"
ia_rc_nonzero "IA15 exported template -> non-zero exit (the setting is not in effect yet)"
if printf '%s' "$IA_OUT" | grep -qi 'export'; then pass "IA15 written-but-not-effective message names the export"
else fail "IA15 written-but-not-effective message names the export" "out=$IA_OUT"; fi
case_end

case_begin "init-interactive-exported-template-declined-write" "bin/plan-sync-init"
IA_BODY=$'A=1\n'
ia_seed expn "$IA_BODY"
ia_run expn on $'y\nn\n' PLAN_SYNC_REMOTE_URL="$IA_TPL" GH_DISPATCH_REPO=private
if printf '%s' "$IA_OUT" | grep -F 'PLAN_SYNC_REMOTE_URL' | grep -qiE 'environment|export'; then
  pass "IA16 exported template -> the notice is shown before any answer is used"
else fail "IA16 exported template -> the notice is shown before any answer is used" "out=$IA_OUT"; fi
if [ "$IA_RC" != NI ] && ia_env_same "$IA_BODY"; then pass "IA16 .env write declined -> .env byte-identical"
else fail "IA16 .env write declined -> .env byte-identical" "rc=$IA_RC env=$(printf '%q' "$(cat "$IA_CFG/.env" 2>/dev/null)")"; fi
case_end

case_begin "init-interactive-env-file-template-no-notice" "bin/plan-sync-init"
# Control for IA15: the same template read from .env (not exported) -> no precedence notice, exit 0.
IA_BODY=$'PLAN_SYNC_REMOTE_URL='"$IA_TPL"$'\n'
ia_seed envtpl "$IA_BODY"
ia_run envtpl on $'y\ny\n'
ia_rc "IA17 template from .env -> exit 0" 0
if [ "$IA_RC" != NI ] && ! printf '%s' "$IA_OUT" | grep -qi 'export'; then pass "IA17 template from .env -> no export notice"
else fail "IA17 template from .env -> no export notice" "rc=$IA_RC out=$IA_OUT"; fi
case_end
