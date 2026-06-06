#!/usr/bin/env bash
# Autonomous bootstrap for a brand-new GitHub repository whose remote has no
# default branch yet. Pushes the current feature branch as `main` and (best-
# effort) sets the default branch on GitHub.
#
# Invocation forms:
#   1) Positional (SKILL.md callers):
#        bash bootstrap-complete.sh <WORKTREE_PATH> <BRANCH> <OWNER_REPO>
#   2) Flag style (tests, future flexibility):
#        bash bootstrap-complete.sh --repo <PATH> --remote <NAME> \
#            [--default-branch <NAME>] [--branch <BRANCH>] [--owner-repo <O/R>]
#
# Env hooks:
#   BOOTSTRAP_REPROBE_RESULT — when set, skip the live bootstrap-state.js probe
#       and treat the result as if classification=<value> (used by E2E tests).
#       Accepts: empty-repo, ok, network, auth, not-found, timeout, spawn-error.
#
# Exit codes:
#   0 — bootstrap completed; JSON on stdout
#   1 — argument / environment error
#   2 — pre-bootstrap re-probe disagrees (remote no longer empty or wrong class)
#   3 — git push failed
#
# stdout (success): single-line JSON with bootstrap_commit_sha,
# default_branch_set, pushed_ref.
set -uo pipefail

WORKTREE_PATH=""
BRANCH=""
OWNER_REPO=""
REMOTE="origin"
DEFAULT_BRANCH="main"

# Detect invocation style: if first arg starts with "--", flag style; otherwise positional.
if [[ $# -ge 1 && "${1:-}" == --* ]]; then
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo) WORKTREE_PATH="${2:?--repo value required}"; shift 2;;
            --branch) BRANCH="${2:?--branch value required}"; shift 2;;
            --owner-repo) OWNER_REPO="${2:?--owner-repo value required}"; shift 2;;
            --remote) REMOTE="${2:?--remote value required}"; shift 2;;
            --default-branch) DEFAULT_BRANCH="${2:?--default-branch value required}"; shift 2;;
            *) printf 'bootstrap-complete: unknown flag %s\n' "$1" >&2; exit 1;;
        esac
    done
else
    WORKTREE_PATH="${1:?WORKTREE_PATH required}"
    BRANCH="${2:?BRANCH required}"
    OWNER_REPO="${3:?OWNER_REPO required}"
fi

if [ -z "$WORKTREE_PATH" ]; then
    printf 'bootstrap-complete: missing --repo / WORKTREE_PATH\n' >&2
    exit 1
fi

# Derive BRANCH from HEAD if not supplied (flag style typically omits it).
if [ -z "$BRANCH" ]; then
    BRANCH="$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
        printf 'bootstrap-complete: could not resolve current branch in %s\n' "$WORKTREE_PATH" >&2
        exit 1
    fi
fi

# Step 1: Re-probe the remote (or honor BOOTSTRAP_REPROBE_RESULT for tests).
if [ -n "${BOOTSTRAP_REPROBE_RESULT:-}" ]; then
    CLASSIFICATION="$BOOTSTRAP_REPROBE_RESULT"
    if [ "$CLASSIFICATION" = "empty-repo" ]; then
        PRE_BOOTSTRAP="true"
    else
        PRE_BOOTSTRAP="false"
    fi
else
    # Resolve bootstrap-state.js: prefer the worktree-local copy (so dev/test
    # against an in-progress branch hits the current code), then fall back to
    # AGENTS_CONFIG_DIR (the original SKILL.md contract).
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOCAL_LIB="$SCRIPT_DIR/../../../hooks/lib/bootstrap-state.js"
    if [ -f "$LOCAL_LIB" ]; then
        PROBE_LIB="$LOCAL_LIB"
    elif [ -n "${AGENTS_CONFIG_DIR:-}" ] && [ -f "$AGENTS_CONFIG_DIR/hooks/lib/bootstrap-state.js" ]; then
        PROBE_LIB="$AGENTS_CONFIG_DIR/hooks/lib/bootstrap-state.js"
    else
        printf 'bootstrap-complete: cannot find hooks/lib/bootstrap-state.js (set AGENTS_CONFIG_DIR)\n' >&2
        exit 1
    fi

    PROBE_JSON="$(node -e '
const { isRemoteInPreBootstrap } = require(process.argv[1]);
const out = isRemoteInPreBootstrap(process.argv[2], { remote: process.argv[3] });
process.stdout.write(JSON.stringify(out));
' "$PROBE_LIB" "$WORKTREE_PATH" "$REMOTE")"

    PRE_BOOTSTRAP="$(printf '%s' "$PROBE_JSON" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(s).preBootstrap))}catch{process.stdout.write("false")}})')"
    CLASSIFICATION="$(printf '%s' "$PROBE_JSON" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(s).classification||""))}catch{process.stdout.write("")}})')"
fi

if [[ "$PRE_BOOTSTRAP" != "true" || "$CLASSIFICATION" != "empty-repo" ]]; then
    printf 'bootstrap-complete: re-probe disagrees (preBootstrap=%s classification=%s); refusing to push.\n' \
        "$PRE_BOOTSTRAP" "$CLASSIFICATION" >&2
    exit 2
fi

# Step 2: Push the local branch as the chosen default branch on the remote.
if ! git -C "$WORKTREE_PATH" push -u "$REMOTE" "$BRANCH:$DEFAULT_BRANCH" >&2; then
    printf 'bootstrap-complete: git push %s %s:%s failed\n' "$REMOTE" "$BRANCH" "$DEFAULT_BRANCH" >&2
    exit 3
fi

# Step 3: Set the default branch on GitHub (warn-only; gh may lack admin scope).
DEFAULT_BRANCH_SET=true
if [ -n "$OWNER_REPO" ]; then
    if ! gh -R "$OWNER_REPO" repo edit --default-branch "$DEFAULT_BRANCH" >&2; then
        printf 'bootstrap-complete: WARN gh repo edit --default-branch %s failed (continuing)\n' "$DEFAULT_BRANCH" >&2
        DEFAULT_BRANCH_SET=false
    fi
else
    if ! (cd "$WORKTREE_PATH" && gh repo edit --default-branch "$DEFAULT_BRANCH") >&2; then
        printf 'bootstrap-complete: WARN gh repo edit --default-branch %s failed (continuing)\n' "$DEFAULT_BRANCH" >&2
        DEFAULT_BRANCH_SET=false
    fi
fi

# Step 4: Record the bootstrap commit SHA.
BOOTSTRAP_COMMIT_SHA="$(git -C "$WORKTREE_PATH" rev-parse HEAD)"

# Step 5: Emit JSON for the caller (worktree-end SKILL.md Step 2b).
printf '{"bootstrap_commit_sha":"%s","default_branch_set":%s,"pushed_ref":"refs/heads/%s"}\n' \
    "$BOOTSTRAP_COMMIT_SHA" "$DEFAULT_BRANCH_SET" "$DEFAULT_BRANCH"
