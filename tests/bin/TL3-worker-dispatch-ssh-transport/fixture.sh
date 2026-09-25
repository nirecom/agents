# Part of tests/TL3-worker-dispatch-ssh-transport.sh — sourced, not run.
# Tests: bin/worker-dispatch/workers/commit-push/push.js, bin/worker-dispatch/spawn.js
# Tags: worker-dispatch, commit-push, ssh-agent, canary, adversarial, real-environment, TL3, scope:common
# The hostile-repository fixture: an ssh:// remote whose transport is a
# repo-local core.sshCommand wrapper, plus canary hooks on core.hooksPath —
# both plantable by a compromised repo with no privilege, both executed by the
# dispatcher's own children. Each canary records REACHABILITY of the live agent
# (ssh-add rc: 0 keys, 1 empty, 2 unreachable), not a string compare.
build_canaries() {
    CANARY_LOG="$TMPD/canary.log"
    : > "$CANARY_LOG"
    HOOKS_DIR="$TMPD/hostile-hooks"
    mkdir -p "$HOOKS_DIR"

    # One definition of "what a canary observed", shared by every hook and by
    # the transport, so no row can pass on a weaker measurement than its peers.
    cat > "$TMPD/canary-record.sh" <<'RECJS'
canary_record() {
    local who="$1" rc
    ssh-add -l >/dev/null 2>&1; rc=$?
    printf '%s sock=%s agentpid=%s agentrc=%s\n' \
        "$who" "${SSH_AUTH_SOCK-<unset>}" "${SSH_AGENT_PID-<unset>}" "$rc" >> "$CANARY_LOG"
}
RECJS

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

    # The wrapper doubles as the authenticating transport: it refuses with 255
    # (OpenSSH's auth-failure code) unless the agent is reachable AND holds a
    # key, then runs git's requested command locally. A push that completes is
    # therefore a push whose transport really authenticated off the agent.
    cat > "$TMPD/canary-ssh.sh" <<SSHEOF
#!/usr/bin/env bash
CANARY_LOG="$CANARY_LOG"
# \`ssh -G <host>\` is git's capability probe, not a session: it carries no
# remote command, so recording it would inflate every transport count.
[ "\$1" = "-G" ] && exit 0
. "$TMPD/canary-record.sh"
# Each git network call gets its OWN canary name, so a row about the push can
# never be satisfied (or broken) by some other call's record.
case "\${@: -1}" in
    *git-receive-pack*) KIND=receive ;;
    *git-upload-pack*)  KIND=upload ;;
    *)                  KIND=other ;;
esac
canary_record "transport-\$KIND"
ssh-add -l >/dev/null 2>&1 || exit 255
# git's last argument is the remote command; the host argument is ignored
# because the "remote" lives on this same filesystem.
eval "\${@: -1}"
SSHEOF
    chmod +x "$TMPD/canary-ssh.sh"
}

# canary_field <who> <key> [nth] — the shell-side reader over the record file.
canary_field() {
    local who="$1" key="$2" nth="${3:-1}"
    grep "^$who " "$CANARY_LOG" 2>/dev/null | sed -n "${nth}p" \
        | sed -n "s|.*[ ]$key=\([^ ]*\).*|\1|p" | head -1
}
canary_count() { grep -c "^$1 " "$CANARY_LOG" 2>/dev/null || echo 0; }

# The real-agent tier of the absence claim the offline suite proves. Deliberately
# non-counting: it must not move this file's PROVEN/REQUIRED arithmetic.
assert_no_agent_pid() {
    local tag="$1"
    if [ -z "${AGENT_PID:-}" ]; then
        skip "$tag/no-child-received-the-agent-pid — the fixture agent reported no PID"
    elif grep -q "agentpid=${AGENT_PID}" "$CANARY_LOG" 2>/dev/null; then
        fail "$tag/no-child-received-the-agent-pid — $(grep -n "agentpid=${AGENT_PID}" "$CANARY_LOG" | tr '\n' ';')"
    else
        pass "$tag/no-child-received-the-agent-pid"
    fi
}
transport_count() { grep -c "^transport-" "$CANARY_LOG" 2>/dev/null || echo 0; }

posixpath() { cygpath -u "$1" 2>/dev/null || printf '%s' "$1"; }

# A main-root repo, a linked worktree on a feature branch, and a bare "remote"
# reachable ONLY over the ssh:// URL, so every network git call in the worker
# goes through the canary transport with no local-path fallback.
build_repos() {
    REMOTE_RAW="$TMPD/remote.git"
    git init -q --bare -b main "$REMOTE_RAW"
    REMOTE_URL="ssh://canary-host$(posixpath "$REMOTE_RAW")"

    MAIN_RAW="$TMPD/mainrepo"
    mkdir -p "$MAIN_RAW"
    git -C "$MAIN_RAW" init -q -b main
    git -C "$MAIN_RAW" config user.email "test@example.com"
    git -C "$MAIN_RAW" config user.name "Test"
    git -C "$MAIN_RAW" config commit.gpgsign false
    # The hostile half, set in the repo's own config the way a cloned repo
    # could ship it: BOTH repository-controlled execution surfaces at once.
    git -C "$MAIN_RAW" config core.hooksPath "$(posixpath "$HOOKS_DIR")"
    git -C "$MAIN_RAW" config core.sshCommand "bash $(posixpath "$TMPD/canary-ssh.sh")"
    git -C "$MAIN_RAW" remote add origin "$REMOTE_URL"

    echo init > "$MAIN_RAW/README.md"
    git -C "$MAIN_RAW" add README.md
    git -C "$MAIN_RAW" -c core.hooksPath=/dev/null commit -q --no-verify -m initial
    # The seeding pushes take the same agent-gated transport the worker will, so
    # they must carry the socket too — the fixture is not the thing under test.
    SSH_AUTH_SOCK="$AGENT_SOCK" SSH_AGENT_PID="$AGENT_PID" \
        git -C "$MAIN_RAW" -c core.hooksPath=/dev/null push -q origin main 2>/dev/null || return 1

    WT_RAW="$TMPD/linked-wt"
    git -C "$MAIN_RAW" -c core.hooksPath=/dev/null worktree add -q -b "$BRANCH" "$WT_RAW"
    SSH_AUTH_SOCK="$AGENT_SOCK" SSH_AGENT_PID="$AGENT_PID" \
        git -C "$MAIN_RAW" -c core.hooksPath=/dev/null push -q -u origin "$BRANCH" 2>/dev/null || return 1
    SEED_TRANSPORTS="$(transport_count)"
    : > "$CANARY_LOG"
    return 0
}

# stage_change <text> — a real staged edit, so a row never measures the
# worker's step-1 "nothing is staged" refusal instead of the push.
stage_change() {
    printf '%s\n' "$1" >> "$WT_RAW/README.md"
    git -C "$WT_RAW" -c core.hooksPath=/dev/null add README.md
}

# run_worker <tag> — the real dispatcher, real registry entry, real
# workflow-gate child. The agent pair is in the PARENT env only; which child
# ever sees which half is exactly what the canaries answer. SSH_AGENT_PID is
# planted alongside the socket and is expected NOWHERE: it is deliberately
# absent from commit-push's envPassthrough (registry.js), so the offline
# tests/feature-1812-worker-dispatch-ssh-agent-pid-absence.sh and these rows
# assert the same least-privilege split at two tiers.
run_worker() {
    local tag="$1"
    local p="$PLANS_RAW/$tag.json"
    cat > "$p" <<PAYEOF
{"commit_message":"chore($tag): ssh transport probe","branch":"$BRANCH",
 "worktree_path":"$(nodepath "$WT_RAW")","session_id":"tl3-ssh-transport-session",
 "enforce_worktree":"off","artifact_dir":"$PLANS"}
PAYEOF
    WORKER_OUT="$(run_with_timeout 240 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u GH_TOKEN -u GITHUB_TOKEN \
        "SSH_AUTH_SOCK=$AGENT_SOCK" "SSH_AGENT_PID=$AGENT_PID" "ENFORCE_WORKTREE=off" \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        node "$(nodepath "$AGENTS_DIR/bin/worker-dispatch.js")" \
        commit-push "$(nodepath "$MAIN_RAW")" "$(nodepath "$p")" 2>&1)" || return 1
    return 0
}

worker_field() {
    printf '%s\n' "$WORKER_OUT" | sed -n "s/^$1: //p" | head -1 | tr -d '"'
}
