#!/bin/bash
# tests/bin/feature-sweep-branches/_lib.sh
# Shared helpers and fixtures for feature-sweep-branches test groups.
# Sourced by each group script (core.sh / no-pr.sh / pr-state.sh / remote.sh /
# validation.sh) so the group can also run standalone.
# Provides: `set -uo pipefail`, SWEEP / GUARD_JS paths, PASS / FAIL counters,
# TMPDIR_BASE + cleanup trap, and the pass / fail / run_with_timeout / init_repo /
# make_branch_with_date / make_branch_reachable_from_origin_main /
# copy_sweep_into / make_stub_checkout / ci_field helpers.

set -uo pipefail

# The checkout holding this lib file (three levels up from its directory).
__LIB_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SWEEP="$__LIB_SCRIPT_CHECKOUT_ROOT/bin/sweep-branches.sh"
GUARD_JS="$__LIB_SCRIPT_CHECKOUT_ROOT/hooks/enforce-worktree/branch-delete-guard.js"
# shellcheck source=../../lib/script-checkout-fixture.sh
. "$__LIB_SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

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

# Copy the sweep entrypoint and the modules it sources into the checkout fixture $1.
# The sweep finds bin/is-github-dotcom-remote from its own path, so a stubbed guard
# is reached only when the sweep is launched from this copy ($1/bin/sweep-branches.sh).
copy_sweep_into() {
    script_checkout_fixture_copy "$1" \
        bin/sweep-branches.sh bin/sweep-branches bin/lib/sweep-write-mode.sh
}

# Create a stub checkout at $1: the sweep copy plus is-github-dotcom-remote (exits 0).
make_stub_checkout() {
    local stubdir="$1"
    copy_sweep_into "$stubdir"
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
