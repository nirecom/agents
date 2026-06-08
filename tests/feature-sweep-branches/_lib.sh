#!/bin/bash
# tests/feature-sweep-branches/_lib.sh
# Shared helpers and fixtures for feature-sweep-branches test groups.
#
# Sourced by:
#   - tests/feature-sweep-branches/core.sh
#   - tests/feature-sweep-branches/no-pr.sh
#   - tests/feature-sweep-branches/pr-state.sh
#
# Each group script sources this file so it can run standalone, e.g.:
#   bash tests/feature-sweep-branches/core.sh
#
# This library:
#   - sets `set -uo pipefail`
#   - resolves AGENTS_DIR / SWEEP / GUARD_JS
#   - initializes PASS / FAIL counters
#   - creates TMPDIR_BASE and registers a cleanup trap
#   - defines pass / fail / run_with_timeout / init_repo /
#     make_branch_with_date / make_branch_reachable_from_origin_main /
#     make_stub_agents_dir / ci_field helpers

set -uo pipefail

# Resolve AGENTS_DIR relative to this library file (tests/feature-sweep-branches/_lib.sh
# → repo root is two levels up).
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWEEP="$AGENTS_DIR/bin/sweep-branches.sh"
GUARD_JS="$AGENTS_DIR/hooks/enforce-worktree/branch-delete-guard.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Create a git repo at $1 with one commit on main.
init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
}

# Create a local branch $2 in repo $1 with a commit dated at EPOCH $3.
# Uses GIT_AUTHOR_DATE/GIT_COMMITTER_DATE to control commit age.
make_branch_with_date() {
    local repo="$1" branch="$2" epoch="$3"
    (cd "$repo" && \
        git checkout -q -b "$branch" && \
        GIT_AUTHOR_DATE="$epoch" GIT_COMMITTER_DATE="$epoch" \
            git -c user.email=t@example.com -c user.name=t \
            commit --allow-empty --no-verify -q -m "commit on $branch" && \
        git checkout -q main)
}

# Create a fake origin bare repo, push main to it, then make the branch reachable
# from origin/main (merge --no-ff + push). Required for tests that exercise
# --delete-no-pr happy path: the safety gate refuses to delete branches whose
# commits are not preserved on the default remote.
make_branch_reachable_from_origin_main() {
    local repo="$1" branch="$2" epoch="$3"
    local origin="$repo.origin.git"
    git init -q --bare -b main "$origin"
    make_branch_with_date "$repo" "$branch" "$epoch"
    (cd "$repo" && \
        git remote add origin "$origin" && \
        git push -q origin main && \
        git -c user.email=t@example.com -c user.name=t merge --no-ff -q -m "merge $branch" "$branch" && \
        git push -q origin main && \
        git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main)
}

# Create a stub AGENTS_CONFIG_DIR at $1 with is-github-dotcom-remote (exits 0).
make_stub_agents_dir() {
    local stubdir="$1"
    mkdir -p "$stubdir/bin"
    cat > "$stubdir/bin/is-github-dotcom-remote" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$stubdir/bin/is-github-dotcom-remote"
}

# Extract a field from --ci-mode JSON output.
# $1: multiline string (may include non-JSON lines), $2: field key → prints value or empty string
ci_field() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const key = process.argv[1];
            const lines = b.split(/\r?\n/);
            for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed.startsWith('{')) continue;
                try {
                    const d = JSON.parse(trimmed);
                    if (key in d) { console.log(d[key]); return; }
                } catch (e) { /* not JSON, skip */ }
            }
        });
    " -- "$2" 2>/dev/null
}
