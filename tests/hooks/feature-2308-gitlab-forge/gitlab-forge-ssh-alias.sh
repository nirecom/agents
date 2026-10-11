#!/bin/bash
# tests/hooks/feature-2308-gitlab-forge/gitlab-forge-ssh-alias.sh
# Tests: hooks/lib/forge/gitlab.js, hooks/lib/forge-router.js
# Tags: scope:issue-specific, gitlab, forge, visibility, ssh-alias, hostname, glab-stub, TL2, plan-sync
# #2513: a plan remote written with the GitLab SSH alias host (GITLAB_SSH_HOSTNAME) is looked up
# on the web host (GITLAB_HOSTNAME); the host settings may be passed as an argument; hosts that
# only resemble a GitLab host are never asked. glab is replaced in-process (child_process.spawnSync)
# by a stub that rejects --jq like glab 1.121, so no real glab and no network.
#
# TL3 gap: a real glab against a real alias host (auth per host, <host>:<port> acceptance) is not run.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SA_DRIVER="$TMPROOT/gl-alias-driver.js"
cat > "$SA_DRIVER" <<'NODE'
"use strict";
// argv: <gitlab.js> <remote url> [opts JSON]. Each glab spawn is logged as one JSON argv line.
const cp = require("child_process"); const fs = require("fs");
const realSpawn = cp.spawnSync.bind(cp);
const env = process.env;
cp.spawnSync = function (cmd, args, opts) {
  if (!/glab/.test(String(cmd))) return realSpawn(cmd, args, opts);
  fs.appendFileSync(env.SA_LOG, JSON.stringify(args || []) + "\n");
  if ((args || []).some((a) => a === "--jq" || String(a).startsWith("--jq="))) {
    return { status: 1, stdout: "", stderr: "Unknown flag: --jq\n", error: null };
  }
  if (env.SA_MODE === "spawn-error") return { status: null, stdout: "", stderr: "", error: new Error("ENOENT") };
  if (env.SA_MODE === "timeout") {
    const e = new Error("spawnSync glab ETIMEDOUT"); e.code = "ETIMEDOUT";
    return { status: null, signal: "SIGTERM", stdout: env.SA_OUT || "", stderr: "", error: e };
  }
  if (env.SA_MODE === "throw") throw new Error("spawn blew up");
  return { status: Number(env.SA_RC || 0), stdout: env.SA_OUT || "", stderr: "", error: null };
};
let r;
try {
  const gl = require(process.argv[2]).codehostGitlab;
  r = process.argv[4] ? gl.repoVisibility(process.argv[3], JSON.parse(process.argv[4])) : gl.repoVisibility(process.argv[3]);
} catch (e) { r = "THREW:" + e.message; }
process.stdout.write(JSON.stringify(r));
NODE
SA_LOG="$(nodepath "$TMPROOT/gl-alias.log")"
SA_CWD="$TMPROOT/sa-neutral"; mkdir -p "$SA_CWD"
# AGENTS_MAIN_ROOT/.env wins over process.env, so each fixture cfg pins both hosts exactly.
sa_cfg() {
    local d="$TMPROOT/sa-cfg-$1"; mkdir -p "$d"
    printf 'GITLAB_HOSTNAME=%s\nGITLAB_SSH_HOSTNAME=%s\n' "$2" "$3" > "$d/.env"
    printf '%s' "$d"
}
SA_CFG_ALIAS="$(sa_cfg alias gitlab.example.com plans.example.com)"
SA_CFG_WEB_ONLY="$(sa_cfg web-only gitlab.example.com '')"
SA_CFG_NONE="$(sa_cfg none '' '')"
SA_CFG_OTHER="$(sa_cfg other other.example.com other-ssh.example.com)"
# sa_run <cfgdir> <stdout> <rc> <mode> <remote url> [opts JSON]
sa_run() {
    : > "$SA_LOG"
    (cd "$SA_CWD" && unset GITLAB_HOSTNAME GITLAB_SSH_HOSTNAME \
        && AGENTS_MAIN_ROOT="$(nodepath "$1")" SA_LOG="$SA_LOG" SA_OUT="$2" SA_RC="$3" SA_MODE="$4" \
        run_with_timeout 20 node "$SA_DRIVER" "$GITLAB_JS" "$5" "${6:-}" 2>/dev/null)
}
sa_log() { cat "$SA_LOG" 2>/dev/null; }
sa_argv() { printf '["api","--hostname","%s","projects/%s"]' "$1" "$2"; }
SA_PRIV='{"path_with_namespace":"team/plans","visibility":"private"}'
SA_ARG_ALIAS='{"gitlabHost":"gitlab.example.com","gitlabSshHost":"plans.example.com"}'

echo "=== SA-GL: a destination on the SSH alias host is looked up on the web host ==="
case_begin "gitlab-visibility-ssh-alias-web-host" "hooks/lib/forge/gitlab.js"
# id|remote url|expected encoded project
while IFS='|' read -r sa_id sa_url sa_proj; do
    [[ -z "$sa_id" || "$sa_id" =~ ^[[:space:]]*# ]] && continue
    assert_eq "$sa_id: project JSON private -> private" '"private"' \
        "$(sa_run "$SA_CFG_ALIAS" "$SA_PRIV" 0 "" "$sa_url" < /dev/null)"
    assert_eq "$sa_id: one spawn, --hostname gitlab.example.com projects/$sa_proj" \
        "$(sa_argv gitlab.example.com "$sa_proj")" "$(sa_log)"
done <<'TABLE'
SA-GL1 scp form on the alias host|git@plans.example.com:team/plans.git|team%2Fplans
SA-GL2 ssh:// form on the alias host|ssh://git@plans.example.com/team/plans.git|team%2Fplans
SA-GL3 ssh:// form with an ssh port on the alias host|ssh://git@plans.example.com:2222/team/plans.git|team%2Fplans
SA-GL4 uppercase alias host|git@Plans.Example.COM:team/plans.git|team%2Fplans
SA-GL5 nested groups on the alias host|git@plans.example.com:team/sub/deeper/plans.git|team%2Fsub%2Fdeeper%2Fplans
SA-GL6 web host itself still resolves with an alias configured|https://gitlab.example.com/team/sub/plans.git|team%2Fsub%2Fplans
TABLE
sa_run "$SA_CFG_ALIAS" "$SA_PRIV" 0 "" "git@plans.example.com:team/plans.git" >/dev/null
assert_not_contains "SA-GL1 the alias host never reaches glab" "plans.example.com" "$(sa_log)"
case_end

case_begin "gitlab-visibility-ssh-alias-not-configured" "hooks/lib/forge-router.js"
assert_eq "SA-GL7 alias host without GITLAB_SSH_HOSTNAME -> null" 'null' \
    "$(sa_run "$SA_CFG_WEB_ONLY" "$SA_PRIV" 0 "" "git@plans.example.com:team/plans.git")"
assert_eq "SA-GL7 alias host without GITLAB_SSH_HOSTNAME spawns no glab" "" "$(sa_log)"
assert_eq "SA-GL8 web host without an alias -> private (existing behaviour)" '"private"' \
    "$(sa_run "$SA_CFG_WEB_ONLY" "$SA_PRIV" 0 "" "git@gitlab.example.com:team/plans.git")"
assert_eq "SA-GL8 web host without an alias: argv" "$(sa_argv gitlab.example.com team%2Fplans)" "$(sa_log)"
case_end

echo "=== SA-GL: the host settings passed as an argument ==="
case_begin "gitlab-visibility-host-settings-argument" "hooks/lib/forge/gitlab.js"
assert_eq "SA-GL27 alias URL, settings only in the argument -> private" '"private"' \
    "$(sa_run "$SA_CFG_NONE" "$SA_PRIV" 0 "" "git@plans.example.com:team/plans.git" "$SA_ARG_ALIAS")"
assert_eq "SA-GL27 asked on the argument's web host" "$(sa_argv gitlab.example.com team%2Fplans)" "$(sa_log)"
assert_eq "SA-GL28 the argument wins over the agents .env (alias URL)" '"private"' \
    "$(sa_run "$SA_CFG_OTHER" "$SA_PRIV" 0 "" "git@plans.example.com:team/plans.git" "$SA_ARG_ALIAS")"
assert_eq "SA-GL28 asked on the argument's web host, not the .env one" \
    "$(sa_argv gitlab.example.com team%2Fplans)" "$(sa_log)"
assert_eq "SA-GL29 a host only the .env names is not GitLab under the argument -> null" 'null' \
    "$(sa_run "$SA_CFG_OTHER" "$SA_PRIV" 0 "" "git@other.example.com:team/plans.git" "$SA_ARG_ALIAS")"
assert_eq "SA-GL29 spawns no glab" "" "$(sa_log)"
assert_eq "SA-GL30 argument with only the web host: alias URL -> null" 'null' \
    "$(sa_run "$SA_CFG_NONE" "$SA_PRIV" 0 "" "git@plans.example.com:team/plans.git" '{"gitlabHost":"gitlab.example.com"}')"
assert_eq "SA-GL30 spawns no glab" "" "$(sa_log)"
assert_eq "SA-GL31 argument omitted: the agents .env still decides (alias)" '"private"' \
    "$(sa_run "$SA_CFG_ALIAS" "$SA_PRIV" 0 "" "git@plans.example.com:team/plans.git")"
case_end

echo "=== SA-GL: hosts that only resemble a GitLab host are not GitLab ==="
case_begin "gitlab-visibility-lookalike-hosts" "hooks/lib/forge-router.js"
# id|cfg|remote url
while IFS='|' read -r sa_id sa_cfg_name sa_url; do
    [[ -z "$sa_id" || "$sa_id" =~ ^[[:space:]]*# ]] && continue
    assert_eq "$sa_id -> null" 'null' "$(sa_run "$TMPROOT/sa-cfg-$sa_cfg_name" "$SA_PRIV" 0 "" "$sa_url" < /dev/null)"
    assert_eq "$sa_id spawns no glab" "" "$(sa_log)"
done <<'TABLE'
SA-GL9 sub.gitlab.com (scp)|none|git@sub.gitlab.com:team/plans.git
SA-GL10 sub.gitlab.com (https)|none|https://sub.gitlab.com/team/plans.git
SA-GL11 gitlab.com.example.com (scp)|none|git@gitlab.com.example.com:team/plans.git
SA-GL12 gitlab.com.example.com (https)|none|https://gitlab.com.example.com/team/plans.git
SA-GL13 sub.gitlab.com with an alias configured|alias|git@sub.gitlab.com:team/plans.git
SA-GL14 subdomain of the web host|alias|git@sub.gitlab.example.com:team/plans.git
SA-GL15 web host as a prefix of another host|alias|git@gitlab.example.com.plans.example.com:team/plans.git
SA-GL16 subdomain of the alias host|alias|git@sub.plans.example.com:team/plans.git
SA-GL17 alias host as a prefix of another host|alias|git@plans.example.com.gitlab.example.com:team/plans.git
TABLE
sa_lookalike_guard="$(sa_run "$SA_CFG_NONE" "$SA_PRIV" 0 "" "git@gitlab.com:team/plans.git")"
assert_eq "SA-GL18 guard: gitlab.com itself is looked up by the same driver" \
    "\"private\" $(sa_argv gitlab.com team%2Fplans)" "$sa_lookalike_guard $(sa_log)"
case_end

echo "=== SA-GL: a lookup that cannot be trusted is unverifiable (null) ==="
case_begin "gitlab-visibility-ssh-alias-unverifiable" "hooks/lib/forge/gitlab.js"
SA_URL="git@plans.example.com:team/plans.git"
# id|stdout|rc|mode
while IFS='|' read -r sa_id sa_out sa_rc sa_mode; do
    [[ -z "$sa_id" || "$sa_id" =~ ^[[:space:]]*# ]] && continue
    assert_eq "$sa_id -> null" 'null' \
        "$(sa_run "$SA_CFG_ALIAS" "$(printf '%b' "$sa_out")" "$sa_rc" "$sa_mode" "$SA_URL" < /dev/null)"
    assert_eq "$sa_id: glab was asked on the web host" "$(sa_argv gitlab.example.com team%2Fplans)" "$(sa_log)"
done <<'TABLE'
SA-GL19 glab exits non-zero|{"visibility":"private"}\n|1|
SA-GL20 glab cannot be spawned|{"visibility":"private"}\n|0|spawn-error
SA-GL21 glab times out (late answer ignored)|{"visibility":"private"}\n|0|timeout
SA-GL22 spawn throws|{"visibility":"private"}\n|0|throw
SA-GL23 empty output||0|
SA-GL24 a visibility that is not one of the three|{"visibility":"secret"}\n|0|
SA-GL25 an error body instead of a project|{"message":"404 Project Not Found"}\n|0|
SA-GL26 a bare word (not JSON)|private\n|0|
SA-GL32 truncated JSON|{"visibility":"priv|0|
TABLE
case_end

finish
