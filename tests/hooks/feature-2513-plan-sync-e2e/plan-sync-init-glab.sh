#!/usr/bin/env bash
# tests/hooks/feature-2513-plan-sync-e2e/plan-sync-init-glab.sh
# Tests: bin/plan-sync-init, hooks/lib/plan-sync/init-interactive.js
# Tags: plan-sync, interactive, gitlab, glab-stub, gh-stub, cli, init, env-write, TL2, scope:issue-specific
# #2513 plan-sync-init with a GitLab template URL: the setup runs through glab, never gh.
# gh / glab are node links answered by ./gh-dispatch-preload.js and ./glab-dispatch-preload.js;
# git ssh goes to the ssh stub serving test-owner/agent-plans.git. No network.
# Run standalone, or through ../feature-2513-plan-sync-e2e.sh, which aggregates its Results line.
set -uo pipefail

# TL3 gap: a real `glab api` round trip (auth, project creation, a 404 for an absent project
# against a live GitLab) and real ssh access to the created project are not exercised.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../../lib/plan-sync-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-fixture.sh"

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
psf_tag_unimplemented_fails
trap psf_cleanup EXIT
CLI="$(psf_np "$SCRIPT_CHECKOUT_ROOT/bin/plan-sync-init")"
IG_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2513-plan-sync-e2e"

psf_drop_gh_from_path
psf_drop_cli_from_path glab

IG_NODE="$(node -p 'process.execPath')"
for ig_n in gh glab; do
  mkdir -p "$PSF_ROOT/$ig_n-dispatch"
  for ig_f in "$ig_n" "$ig_n.exe"; do
    [ -e "$PSF_ROOT/$ig_n-dispatch/$ig_f" ] || ln "$IG_NODE" "$PSF_ROOT/$ig_n-dispatch/$ig_f" 2>/dev/null \
      || cp "$IG_NODE" "$PSF_ROOT/$ig_n-dispatch/$ig_f"
  done
done
IG_GH_PATH="$(psf_up "$PSF_ROOT/gh-dispatch")"
IG_GL_PATH="$(psf_up "$PSF_ROOT/glab-dispatch")"
IG_PRELOADS="--require \"$(psf_np "$IG_DIR/gh-dispatch-preload.js")\" --require \"$(psf_np "$IG_DIR/glab-dispatch-preload.js")\""
IG_TPL="git@gitlab.com:YOUR_USERNAME/agent-plans.git"
IG_URL="git@gitlab.com:test-owner/agent-plans.git"
# Run ids must not contain "glab" or "auth": they end up in paths the CLI prints, and GL8 / GL9
# assert on those words in its output.
IG_SPAWN='const r = require("child_process").spawnSync(process.argv[1], process.argv.slice(2), { encoding: "utf8", windowsHide: true }); process.stdout.write(r.error ? String(r.error.code) : String(r.stdout).trim() + (r.status ? " rc=" + r.status : ""));'

# ig_run <id> <stubs: both|gh-only> <answers> <.env body> [VAR=val...] — runs the CLI in a
# subshell with a fresh plans dir / agents main root / bare. PLAN_SYNC_REMOTE_URL comes from the
# $AGENTS_MAIN_ROOT/.env only (a VAR=val may export it); both GitLab host settings are pinned
# empty unless a VAR=val sets them.
# Sets IG_RC, IG_OUT, IG_PLANS, IG_CFG, IG_BODY, IG_GHLOG, IG_GLLOG (argv JSON), IG_CALLS (classified).
ig_run() {
  local id="$1" stubs="$2" answers="$3"
  IG_BODY="$4"
  shift 4
  IG_PLANS="$PSF_ROOT/ig-$id-plans"; IG_CFG="$PSF_ROOT/ig-$id-cfg"
  IG_GHLOG="$PSF_ROOT/ig-$id-gh.log"; IG_GLLOG="$PSF_ROOT/ig-$id-glab.log"; IG_CALLS="$PSF_ROOT/ig-$id-glab.calls"
  mkdir -p "$IG_PLANS" "$IG_CFG"
  psf_make_bare "$PSF_ROOT/ig-$id-bare.git" >/dev/null 2>&1
  printf '%s' "$IG_BODY" > "$IG_CFG/.env"
  : > "$IG_GHLOG"; : > "$IG_GLLOG"; : > "$IG_CALLS"
  if [ ! -f "$CLI" ]; then IG_RC=NI; IG_OUT="NOT_IMPLEMENTED: bin/plan-sync-init missing"; return; fi
  IG_OUT="$(
    unset PLAN_SYNC_REMOTE_URL
    export AGENTS_MAIN_ROOT="$IG_CFG" WORKFLOW_PLANS_DIR="$IG_PLANS" PLAN_SYNC_INIT_ASSUME_TTY=1
    export GITLAB_HOSTNAME="" GITLAB_SSH_HOSTNAME=""
    export GH_DISPATCH_LOG="$IG_GHLOG" GH_DISPATCH_STATE="$PSF_ROOT/ig-$id-gh.state" GH_DISPATCH_LOGIN=test-owner GH_DISPATCH_REPO=absent
    export GLAB_DISPATCH_LOG="$IG_GLLOG" GLAB_DISPATCH_CALLS="$IG_CALLS" GLAB_DISPATCH_STATE="$PSF_ROOT/ig-$id-glab.state"
    export GLAB_DISPATCH_LOGIN=test-owner GLAB_DISPATCH_PROJECT=absent
    setup_ssh_stub "$PSF_ROOT/ig-$id-bare.git"
    export GIT_SSH_STUB_REPO=test-owner/agent-plans.git
    for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
    if [ "$stubs" = both ]; then export PATH="$IG_GL_PATH:$IG_GH_PATH:$PATH"; else export PATH="$IG_GH_PATH:$PATH"; fi
    export NODE_OPTIONS="$IG_PRELOADS"
    cd "$PSF_ROOT/neutral" || exit 97
    printf '%s' "$answers" | psf_timeout 60 node "$CLI" 2>&1
  )"
  IG_RC=$?
}

ig_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing $(printf '%q' "$3") in $(printf '%q' "$2")" ;; esac; }
ig_rc() { if [ "$IG_RC" = "$2" ]; then pass "$1"; else fail "$1" "rc=$IG_RC want=$2 out=$IG_OUT"; fi; }
ig_rc_nonzero() { if [ "$IG_RC" != NI ] && [ "$IG_RC" != 0 ]; then pass "$1"; else fail "$1" "rc=$IG_RC out=$IG_OUT"; fi; }
# ig_call <name> <exact classified line> / ig_no_call <name> <kind>
ig_call() { if grep -qxF -- "$2" "$IG_CALLS"; then pass "$1"; else fail "$1" "calls=$(tr '\n' '|' < "$IG_CALLS") out=$IG_OUT"; fi; }
ig_no_call() { if grep -q "^$2 " "$IG_CALLS"; then fail "$1" "calls=$(tr '\n' '|' < "$IG_CALLS")"; else pass "$1"; fi; }
ig_gh_silent() { if [ ! -s "$IG_GHLOG" ]; then pass "$1"; else fail "$1" "gh log=$(tr '\n' '|' < "$IG_GHLOG")"; fi; }
ig_glab_silent() { if [ ! -s "$IG_GLLOG" ]; then pass "$1"; else fail "$1" "glab log=$(tr '\n' '|' < "$IG_GLLOG")"; fi; }
# ig_hosts <name> <host> — every user / lookup / create call carried --hostname <host>; at least one did.
ig_hosts() {
  local n bad
  n="$(grep -cE '^(user|lookup|create) ' "$IG_CALLS")"
  bad="$(grep -E '^(user|lookup|create) ' "$IG_CALLS" | awk -v h="$2" '$2 != h')"
  if [ "$n" -gt 0 ] && [ -z "$bad" ]; then pass "$1"; else fail "$1" "n=$n calls=$(tr '\n' '|' < "$IG_CALLS")"; fi
}
ig_env_same() { [ "$(cat "$IG_CFG/.env" 2>/dev/null; printf 'x')" = "${IG_BODY}x" ]; }
# ig_untouched <name> — nothing provisioned and the .env byte-identical.
ig_untouched() {
  if [ "$IG_RC" != NI ] && [ ! -e "$IG_PLANS/.git" ] && [ ! -e "$IG_PLANS/.gitignore" ] && ig_env_same; then pass "$1"
  else fail "$1" "rc=$IG_RC env=$(printf '%q' "$(cat "$IG_CFG/.env" 2>/dev/null)") out=$IG_OUT"; fi
}
ig_provisioned() {
  if [ -n "$(git -C "$IG_PLANS" config --get plansync.version 2>/dev/null)" ]; then pass "$1"
  else fail "$1" "rc=$IG_RC out=$IG_OUT"; fi
}
# ig_env_url <name> <url> — the URL line now holds <url>; every other byte is kept.
ig_env_url() {
  local want
  want="$(printf '%s' "$IG_BODY" | sed "s#^PLAN_SYNC_REMOTE_URL=.*#PLAN_SYNC_REMOTE_URL=$2#"; printf 'x')"
  if [ "$(cat "$IG_CFG/.env" 2>/dev/null; printf 'x')" = "$want" ]; then pass "$1"
  else fail "$1" "env=$(printf '%q' "$(cat "$IG_CFG/.env" 2>/dev/null)") out=$IG_OUT"; fi
}
# ig_rejected_none <name> — the CLI never passed --jq to glab (glab api has no such flag).
ig_rejected_none() { ig_no_call "$1" rejected; }

case_begin "glab-stub-precondition" "bin/plan-sync-init"
IG_SEEN="$(psf_timeout 30 node -e "$IG_SPAWN" gh --version)/$(psf_timeout 30 node -e "$IG_SPAWN" glab api user)"
if [ "$IG_SEEN" = "ENOENT/ENOENT" ]; then pass "real gh and glab unreachable from node"
else fail "real gh and glab unreachable from node" "seen=$IG_SEEN"; fi
IG_SEEN="$(PATH="$IG_GL_PATH:$PATH" NODE_OPTIONS="$IG_PRELOADS" psf_timeout 30 node -e "$IG_SPAWN" glab api --hostname gitlab.com user)"
ig_has "glab stub answers a shell-less spawn with JSON" "$IG_SEEN" '"username":"test-owner"'
IG_SEEN="$(PATH="$IG_GL_PATH:$PATH" NODE_OPTIONS="$IG_PRELOADS" psf_timeout 30 node -e "$IG_SPAWN" glab api --hostname gitlab.com user --jq .username)"
ig_has "glab stub rejects --jq like the real glab api" "$IG_SEEN" "rc=1"
case_end

case_begin "glab-template-absent-create-and-write" "hooks/lib/plan-sync/init-interactive.js"
ig_run create both $'y\ny\n' "A=1"$'\n'"PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n'"B=2"$'\n'
ig_call "GL1 login read through glab api --hostname gitlab.com user" "user gitlab.com -"
ig_call "GL1 test-owner/agent-plans looked up on gitlab.com" "lookup gitlab.com test-owner/agent-plans"
ig_call "GL1 project created through the API as private" "create gitlab.com visibility=private name=agent-plans"
ig_hosts "GL1 every glab api call carries --hostname gitlab.com" gitlab.com
ig_rejected_none "GL1 glab api never given --jq"
ig_gh_silent "GL1 gh never called"
ig_has "GL1 proposal names test-owner/agent-plans" "$IG_OUT" "test-owner/agent-plans"
ig_rc "GL1 exit 0" 0
ig_provisioned "GL1 plans dir provisioned"
ig_env_url "GL1 template line replaced by the login's URL, other lines byte-identical" "$IG_URL"
case_end

case_begin "glab-template-absent-declined" "hooks/lib/plan-sync/init-interactive.js"
ig_run decl both $'n\nn\n' "A=1"$'\n'"PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n'
ig_call "GL2 absent + N -> the project was looked up" "lookup gitlab.com test-owner/agent-plans"
ig_no_call "GL2 absent + N -> no create call" create
ig_rc "GL2 absent + N -> exit 0" 0
ig_untouched "GL2 absent + N -> nothing provisioned, .env byte-identical"
case_end

case_begin "glab-template-private-used" "hooks/lib/plan-sync/init-interactive.js"
ig_run priv both $'y\nn\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n' GLAB_DISPATCH_PROJECT=private
ig_call "GL3 existing private project was looked up" "lookup gitlab.com test-owner/agent-plans"
ig_no_call "GL3 existing private project -> no create call" create
ig_gh_silent "GL3 gh never called"
ig_provisioned "GL3 existing private project used -> provisioned"
ig_has "GL3 .env write declined -> the line is printed" "$IG_OUT" "PLAN_SYNC_REMOTE_URL=$IG_URL"
if ig_env_same; then pass "GL3 .env write declined -> .env byte-identical"
else fail "GL3 .env write declined -> .env byte-identical" "env=$(printf '%q' "$(cat "$IG_CFG/.env")")"; fi
case_end

case_begin "glab-template-private-declined" "hooks/lib/plan-sync/init-interactive.js"
ig_run privn both $'n\nn\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n' GLAB_DISPATCH_PROJECT=private
ig_call "GL4 private + N -> the project was looked up" "lookup gitlab.com test-owner/agent-plans"
ig_no_call "GL4 private + N -> no create call" create
ig_rc "GL4 private + N -> exit 0" 0
ig_untouched "GL4 private + N -> nothing provisioned, .env byte-identical"
case_end

case_begin "glab-template-open-visibility-refused" "hooks/lib/plan-sync/init-interactive.js"
for ig_vis in public internal; do
  ig_run "open-$ig_vis" both $'y\ny\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n' GLAB_DISPATCH_PROJECT="$ig_vis"
  ig_call "GL5 existing $ig_vis project was looked up" "lookup gitlab.com test-owner/agent-plans"
  ig_rc_nonzero "GL5 existing $ig_vis project -> non-zero exit"
  ig_no_call "GL5 existing $ig_vis project -> no create call" create
  ig_untouched "GL5 existing $ig_vis project -> nothing provisioned, .env byte-identical"
done
case_end

case_begin "glab-created-not-private-aborts" "hooks/lib/plan-sync/init-interactive.js"
for ig_vis in internal public; do
  ig_run "made-$ig_vis" both $'y\ny\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n' GLAB_DISPATCH_CREATED_AS="$ig_vis"
  ig_call "GL6 precondition: the create call ran (came out $ig_vis)" "create gitlab.com visibility=private name=agent-plans"
  ig_rc_nonzero "GL6 created project is $ig_vis -> non-zero exit"
  ig_untouched "GL6 created project is $ig_vis -> nothing provisioned, .env byte-identical"
done
case_end

case_begin "glab-create-fails" "hooks/lib/plan-sync/init-interactive.js"
ig_run cfail both $'y\ny\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n' GLAB_DISPATCH_CREATE=fail
ig_call "GL7 precondition: the create call was attempted" "create gitlab.com visibility=private name=agent-plans"
ig_rc_nonzero "GL7 create fails -> non-zero exit"
ig_untouched "GL7 create fails -> nothing provisioned, .env byte-identical"
case_end

case_begin "glab-missing" "hooks/lib/plan-sync/init-interactive.js"
ig_run nocli gh-only $'y\ny\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n'
ig_has "GL8 no glab -> guidance names glab" "$IG_OUT" "glab"
ig_has "GL8 no glab -> falls back to not configured" "$IG_OUT" "plan-sync: not configured"
ig_rc "GL8 no glab -> exit 0" 0
ig_gh_silent "GL8 no glab -> gh is not used instead"
ig_untouched "GL8 no glab -> nothing provisioned, .env byte-identical"
case_end

case_begin "glab-unauthenticated" "hooks/lib/plan-sync/init-interactive.js"
ig_run nologin both $'y\ny\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n' GLAB_DISPATCH_AUTH=no
ig_call "GL9 precondition: glab was asked for the user on gitlab.com" "user gitlab.com -"
if printf '%s' "$IG_OUT" | grep -qi 'auth'; then pass "GL9 unauthenticated -> guidance mentions auth"
else fail "GL9 unauthenticated -> guidance mentions auth" "out=$IG_OUT"; fi
ig_has "GL9 unauthenticated -> falls back to not configured" "$IG_OUT" "plan-sync: not configured"
ig_rc "GL9 unauthenticated -> exit 0" 0
ig_no_call "GL9 unauthenticated -> no create call" create
ig_gh_silent "GL9 unauthenticated -> gh is not used instead"
ig_untouched "GL9 unauthenticated -> nothing provisioned, .env byte-identical"
case_end

case_begin "glab-login-shape-rejected" "hooks/lib/plan-sync/init-interactive.js"
IG_CANARY="$PSF_ROOT/ig-canary"
IG_LOGINS=("evil\$(echo x>$IG_CANARY)&echo x>$IG_CANARY;echo x>$IG_CANARY" "team/sub" "two words")
for ig_i in 0 1 2; do
  ig_run "login-$ig_i" both $'y\ny\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n' GLAB_DISPATCH_LOGIN="${IG_LOGINS[$ig_i]}"
  ig_call "GL10.$ig_i precondition: glab was asked for the user" "user gitlab.com -"
  ig_rc_nonzero "GL10.$ig_i login outside the user-name shape -> non-zero exit"
  ig_no_call "GL10.$ig_i login outside the user-name shape -> never used in a lookup" lookup
  ig_no_call "GL10.$ig_i login outside the user-name shape -> no create call" create
  ig_untouched "GL10.$ig_i login outside the user-name shape -> nothing provisioned, .env byte-identical"
done
if [ ! -e "$IG_CANARY" ]; then pass "GL10 metachar login never shell-interpreted (no canary)"
else fail "GL10 metachar login never shell-interpreted (no canary)" "canary created"; fi
case_end

case_begin "glab-path-not-two-segments" "hooks/lib/plan-sync/init-interactive.js"
ig_run nested both $'y\ny\n' "PLAN_SYNC_REMOTE_URL=git@gitlab.com:team/YOUR_USERNAME/agent-plans.git"$'\n'
ig_rc_nonzero "GL11 group/<login>/project template -> non-zero exit (aborted)"
ig_gh_silent "GL11 group/<login>/project template -> gh never called"
ig_no_call "GL11 group/<login>/project template -> no create call" create
ig_untouched "GL11 group/<login>/project template -> nothing provisioned, .env byte-identical"
case_end

case_begin "glab-self-hosted-hostname" "hooks/lib/plan-sync/init-interactive.js"
ig_run self both $'y\ny\n' "GITLAB_HOSTNAME=gitlab.example.com"$'\n'"PLAN_SYNC_REMOTE_URL=git@gitlab.example.com:YOUR_USERNAME/agent-plans.git"$'\n' \
  GITLAB_HOSTNAME=gitlab.example.com
ig_call "GL12 self-hosted: user asked with --hostname gitlab.example.com" "user gitlab.example.com -"
ig_call "GL12 self-hosted: project created with --hostname gitlab.example.com" "create gitlab.example.com visibility=private name=agent-plans"
ig_hosts "GL12 self-hosted: every glab api call carries --hostname gitlab.example.com" gitlab.example.com
ig_gh_silent "GL12 self-hosted: gh never called"
ig_rc "GL12 self-hosted: exit 0" 0
ig_provisioned "GL12 self-hosted: plans dir provisioned"
ig_env_url "GL12 self-hosted: written URL keeps the self-hosted host" "git@gitlab.example.com:test-owner/agent-plans.git"
case_end

case_begin "glab-ssh-alias-web-host" "hooks/lib/plan-sync/init-interactive.js"
ig_run alias both $'y\ny\n' \
  "GITLAB_HOSTNAME=gitlab.example.com"$'\n'"GITLAB_SSH_HOSTNAME=plans.example.com"$'\n'"PLAN_SYNC_REMOTE_URL=git@plans.example.com:YOUR_USERNAME/agent-plans.git"$'\n' \
  GITLAB_HOSTNAME=gitlab.example.com GITLAB_SSH_HOSTNAME=plans.example.com
ig_call "GL13 ssh alias: user asked on the web host" "user gitlab.example.com -"
ig_call "GL13 ssh alias: project created on the web host" "create gitlab.example.com visibility=private name=agent-plans"
ig_hosts "GL13 ssh alias: every glab api call carries the web host, never the alias" gitlab.example.com
ig_gh_silent "GL13 ssh alias: gh never called"
ig_rc "GL13 ssh alias: exit 0" 0
ig_provisioned "GL13 ssh alias: plans dir provisioned"
ig_env_url "GL13 ssh alias: written URL keeps the alias host the user chose" "git@plans.example.com:test-owner/agent-plans.git"
case_end

case_begin "glab-non-tty-no-prompt" "bin/plan-sync-init"
ig_run ntty both $'y\ny\n' "PLAN_SYNC_REMOTE_URL=$IG_TPL"$'\n' PLAN_SYNC_INIT_ASSUME_TTY=
ig_glab_silent "GL14 non-TTY -> glab never called"
ig_gh_silent "GL14 non-TTY -> gh never called"
ig_rc "GL14 non-TTY -> template URL refused as before (exit 1)" 1
ig_untouched "GL14 non-TTY -> nothing provisioned, .env byte-identical"
case_end

case_begin "glab-configured-url-skips-prompt" "bin/plan-sync-init"
ig_run conf both $'y\ny\n' "A=1"$'\n'"PLAN_SYNC_REMOTE_URL=$IG_URL"$'\n'"B=2"$'\n' GLAB_DISPATCH_PROJECT=private
ig_rc "GL15 configured GitLab URL -> exit 0" 0
ig_no_call "GL15 configured GitLab URL -> glab never asked for the user" user
ig_no_call "GL15 configured GitLab URL -> no create call" create
ig_gh_silent "GL15 configured GitLab URL -> gh never called"
if ig_env_same; then pass "GL15 configured GitLab URL -> .env byte-identical"
else fail "GL15 configured GitLab URL -> .env byte-identical" "env=$(printf '%q' "$(cat "$IG_CFG/.env")")"; fi
ig_provisioned "GL15 configured GitLab URL -> provisioning still runs"
case_end

case_begin "github-or-unset-url-routes-only-gh" "bin/plan-sync-init"
ig_run unset both $'y\ny\n' "A=1"$'\n'
ig_has "GL16 URL unset -> gh asked for the login" "$(cat "$IG_GHLOG")" '"api","user"'
ig_glab_silent "GL16 URL unset -> glab never called"
ig_provisioned "GL16 URL unset -> provisioned through the gh flow"
ig_run ghtpl both $'y\ny\n' "PLAN_SYNC_REMOTE_URL=git@github.com:YOUR_USERNAME/agent-plans.git"$'\n'
ig_has "GL17 GitHub template -> gh asked for the login" "$(cat "$IG_GHLOG")" '"api","user"'
ig_glab_silent "GL17 GitHub template -> glab never called"
ig_provisioned "GL17 GitHub template -> provisioned through the gh flow"
case_end

# Export precedence (detail G5): an exported template outranks the .env value; .env is written
# only on y, and the run ends non-zero because the export still shadows what was written.
case_begin "glab-exported-template-precedence" "hooks/lib/plan-sync/init-interactive.js"
ig_run expw both $'y\ny\n' "A=1"$'\n'"PLAN_SYNC_REMOTE_URL="$'\n' PLAN_SYNC_REMOTE_URL="$IG_TPL"
if printf '%s' "$IG_OUT" | grep -F 'PLAN_SYNC_REMOTE_URL' | grep -qiE 'environment|export'; then
  pass "GL18 exported GitLab template -> notice that the environment variable outranks .env"
else fail "GL18 exported GitLab template -> notice that the environment variable outranks .env" "out=$IG_OUT"; fi
ig_call "GL18 exported GitLab template -> the glab flow still runs" "create gitlab.com visibility=private name=agent-plans"
ig_provisioned "GL18 exported GitLab template -> provisioning still runs"
ig_env_url "GL18 exported GitLab template + y -> .env written" "$IG_URL"
ig_rc_nonzero "GL18 exported GitLab template -> non-zero exit (not in effect until the export is removed)"
ig_run expn both $'y\nn\n' "A=1"$'\n' PLAN_SYNC_REMOTE_URL="$IG_TPL" GLAB_DISPATCH_PROJECT=private
if [ "$IG_RC" != NI ] && ig_env_same; then pass "GL19 exported GitLab template + n on the write -> .env byte-identical"
else fail "GL19 exported GitLab template + n on the write -> .env byte-identical" "rc=$IG_RC env=$(printf '%q' "$(cat "$IG_CFG/.env" 2>/dev/null)")"; fi
ig_provisioned "GL19 exported GitLab template + n on the write -> provisioned with the existing project"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
