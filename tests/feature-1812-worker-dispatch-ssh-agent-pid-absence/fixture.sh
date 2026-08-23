# Part of tests/feature-1812-worker-dispatch-ssh-agent-pid-absence.sh — sourced.
# Tests: bin/worker-dispatch/workers/commit-push/push.js, bin/worker-dispatch/spawn.js
# Tags: worker-dispatch, commit-push, ssh-agent-pid, ssh-auth-sock, git-push, canary, security, TL2, scope:issue-specific
# The offline stand-in for an ssh:// remote: a repo-local core.sshCommand that
# records the transport child's env and then runs git's requested command on this
# same filesystem, plus core.hooksPath canaries on the local steps. No ssh-agent,
# no sshd and no network — SSH_AUTH_SOCK/SSH_AGENT_PID are planted values, and
# what is measured is which child RECEIVES them.

posixpath() { cygpath -u "$1" 2>/dev/null || printf '%s' "$1"; }

build_canaries() {
    CANARY_LOG="$TMPD/canary.log"
    : > "$CANARY_LOG"
    HOOKS_DIR="$TMPD/hooks"
    mkdir -p "$HOOKS_DIR"

    # One record shape for every observer, so no row can pass on a weaker
    # measurement than its peers. `<unset>` is distinct from an empty value.
    cat > "$TMPD/canary-record.sh" <<'RECEOF'
canary_record() {
    printf '%s sock=%s agentpid=%s\n' \
        "$1" "${SSH_AUTH_SOCK-<unset>}" "${SSH_AGENT_PID-<unset>}" >> "$CANARY_LOG"
}
RECEOF

    local h
    for h in pre-commit pre-push pre-rebase post-rewrite post-commit; do
        cat > "$HOOKS_DIR/$h" <<HOOKEOF
#!/usr/bin/env bash
CANARY_LOG="$CANARY_LOG"
. "$TMPD/canary-record.sh"
canary_record "$h"
exit 0
HOOKEOF
        chmod +x "$HOOKS_DIR/$h"
    done

    cat > "$TMPD/probe-ssh.sh" <<SSHEOF
#!/usr/bin/env bash
CANARY_LOG="$CANARY_LOG"
# \`ssh -G <host>\` is git's capability probe and carries no remote command;
# recording it would inflate every transport count.
[ "\$1" = "-G" ] && exit 0
. "$TMPD/canary-record.sh"
case "\${@: -1}" in
    *git-receive-pack*) KIND=receive ;;
    *git-upload-pack*)  KIND=upload ;;
    *)                  KIND=other ;;
esac
canary_record "transport-\$KIND"
# Shims, because the standalone git-*-pack binaries live in libexec and are not
# on PATH on every host; the subcommand form always is.
git-upload-pack() { git upload-pack "\$@"; }
git-receive-pack() { git receive-pack "\$@"; }
# git's last argument is the remote command; the host is ignored because the
# "remote" is a bare repo on this same filesystem.
eval "\${@: -1}"
SSHEOF
    chmod +x "$TMPD/probe-ssh.sh"
}

canary_field() {
    local who="$1" key="$2" nth="${3:-1}"
    grep "^$who " "$CANARY_LOG" 2>/dev/null | sed -n "${nth}p" \
        | sed -n "s|.*[ ]$key=\([^ ]*\).*|\1|p" | head -1
}
canary_count() { grep -c "^$1 " "$CANARY_LOG" 2>/dev/null || echo 0; }

build_repos() {
    REMOTE_RAW="$TMPD/remote.git"
    git init -q --bare -b main "$REMOTE_RAW" >/dev/null 2>&1
    REMOTE_URL="ssh://probe-host$(posixpath "$REMOTE_RAW")"

    MAIN_RAW="$TMPD/mainrepo"
    mkdir -p "$MAIN_RAW"
    git -C "$MAIN_RAW" init -q -b main >/dev/null 2>&1
    git -C "$MAIN_RAW" config user.email "test@example.com"
    git -C "$MAIN_RAW" config user.name "Test"
    git -C "$MAIN_RAW" config commit.gpgsign false
    git -C "$MAIN_RAW" config core.hooksPath "$(posixpath "$HOOKS_DIR")"
    git -C "$MAIN_RAW" config core.sshCommand "bash $(posixpath "$TMPD/probe-ssh.sh")"
    git -C "$MAIN_RAW" remote add origin "$REMOTE_URL"

    echo init > "$MAIN_RAW/README.md"
    git -C "$MAIN_RAW" -c core.hooksPath=/dev/null add README.md >/dev/null 2>&1
    git -C "$MAIN_RAW" -c core.hooksPath=/dev/null commit -q --no-verify -m initial >/dev/null 2>&1
    git -C "$MAIN_RAW" -c core.hooksPath=/dev/null push -q origin main >/dev/null 2>&1 || return 1

    WT_RAW="$TMPD/linked-wt"
    git -C "$MAIN_RAW" -c core.hooksPath=/dev/null worktree add -q -b "$BRANCH" "$WT_RAW" >/dev/null 2>&1
    git -C "$MAIN_RAW" -c core.hooksPath=/dev/null push -q -u origin "$BRANCH" >/dev/null 2>&1 || return 1
    return 0
}

# Divergence forced from a second clone, so push.js's FIRST push is really
# rejected non-fast-forward and the real fetch/rebase/re-push ladder runs.
force_divergence() {
    local scratch="$TMPD/scratch"
    git -c core.hooksPath=/dev/null clone -q --branch "$BRANCH" "$REMOTE_RAW" "$scratch" >/dev/null 2>&1 || return 1
    git -C "$scratch" config user.email "test@example.com"
    git -C "$scratch" config user.name "Test"
    printf 'divergent\n' > "$scratch/DIVERGENT.md"
    git -C "$scratch" -c core.hooksPath=/dev/null add DIVERGENT.md >/dev/null 2>&1
    git -C "$scratch" -c core.hooksPath=/dev/null commit -q --no-verify -m "divergent commit" >/dev/null 2>&1
    git -C "$scratch" -c core.hooksPath=/dev/null push -q origin "$BRANCH" >/dev/null 2>&1 || return 1
    # A local commit of our own, so the replay has something to move.
    printf 'local\n' >> "$WT_RAW/README.md"
    git -C "$WT_RAW" -c core.hooksPath=/dev/null add README.md >/dev/null 2>&1
    git -C "$WT_RAW" -c core.hooksPath=/dev/null commit -q --no-verify -m "local commit" >/dev/null 2>&1
    return 0
}

# The probe: the REAL push.js, driven with the REAL registry entry and the REAL
# spawn.js. Nothing between the assertion and the shipped call path is stubbed.
build_probe() {
    PROBE_JS="$TMPD/push-probe.js"
    cat > "$PROBE_JS" <<'PROBEEOF'
"use strict";
// argv: agentsDir mainRoot worktreePath branch
const path = require("path");
const [agentsDir, mainRoot, wt, branch] = process.argv.slice(2);
const pushMod = require(path.join(agentsDir, "bin/worker-dispatch/workers/commit-push/push.js"));
const anchorMod = require(path.join(agentsDir, "bin/worker-dispatch/anchor.js"));
const registry = require(path.join(agentsDir, "hooks/lib/worker-dispatch-registry.js"));

const out = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
const anchors = anchorMod.resolveAnchors(mainRoot);
if (anchors.error) {
  out("probe_error", "anchors: " + anchors.error);
  process.exit(0);
}
const ctx = { entry: registry.workers["commit-push"], anchors };
const payload = { worktree_path: wt, session_id: "wd1812-agentpid-session" };

const log = [];
let result = null;
try {
  result = pushMod.pushToRemote(ctx, payload, branch, ["push", "-u", "origin", branch], log);
} catch (e) {
  out("probe_error", "pushToRemote threw: " + (e && e.message ? e.message : "unknown"));
  process.exit(0);
}
out("push_status", result && result.status);
out("push_summary", (result && result.summary) || "");
// How many git children the ladder really drove — a run that never reached the
// fetch leg would satisfy every absence row below while proving nothing.
out("git_calls", log.filter((l) => typeof l === "string" && l.indexOf("$ git ") === 0).length);
out("git_argv", log.filter((l) => typeof l === "string" && l.indexOf("$ git ") === 0).join(" | "));
// The registry declaration is the ceiling envScope narrows within: asking for a
// name the entry never declared must still select nothing.
out("declares_agent_pid", ctx.entry.envPassthrough.indexOf("SSH_AGENT_PID") !== -1);
out("declares_auth_sock", ctx.entry.envPassthrough.indexOf("SSH_AUTH_SOCK") !== -1);
out("allowlists_agent_pid", registry.CHILD_ENV_ALLOWLIST.indexOf("SSH_AGENT_PID") !== -1);
PROBEEOF
}
