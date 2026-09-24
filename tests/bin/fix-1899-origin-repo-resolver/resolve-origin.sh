#!/bin/bash
# tests/fix-1899-origin-repo-resolver/resolve-origin.sh
# Tests: bin/github-issues/lib/origin-repo.sh
# Tags: origin-resolution, github-issues, table-driven, TL2, scope:issue-specific
#
# Groups A and B of the fix-1899-origin-repo-resolver split suite — the rc +
# stdout contract of resolve_origin_owner_repo, and the core #1899 regression pin.
#
# Why: `gh repo view` asks the GitHub API "what repo is this checkout?", and on a
# fork carrying BOTH `origin` and `upstream` it can answer with the upstream
# repository — every downstream write then targets the WRONG repo. Group A pins
# the replacement resolver's four return codes; group B pins the behaviour that
# the API gets wrong: resolution follows `origin` and never falls back.
#
#   rc 0 -> prints "owner/repo" resolved from the ORIGIN remote
#   rc 1 -> no origin remote (or not a git repo)
#   rc 2 -> origin exists but is not confirmed github.com (fail-closed)
#   rc 3 -> origin is github.com but owner/repo is not extractable
#
# TL2 (real git fixtures, real bash). TL3 gap: no real GitHub API and no real
# multi-remote clone. Mitigated at WORKFLOW_USER_VERIFIED preflight
# (bin/check-verification-gate.sh) since the change is skill-orchestration class.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group A — resolve_origin_owner_repo: rc + stdout contract, table-driven
# ===========================================================================
group_resolver_table() {
    local name url want got dir i=0
    while IFS='|' read -r name url want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; url="$(echo "$url" | xargs)"; want="$(echo "$want" | xargs)"
        i=$((i + 1))
        dir="$(mk_repo "r$i" "$url")"
        got="$(call_resolver "$dir")"
        assert_eq "resolve/$name" "$want" "$got"
    done <<'TABLE'
# name                | origin url                                  | rc|stdout
# --- Normal (rc 0) --------------------------------------------------------
https-dotgit          | https://github.com/owner/repo.git           | 0|owner/repo
https-no-dotgit       | https://github.com/owner/repo               | 0|owner/repo
ssh-scp               | git@github.com:owner/repo.git               | 0|owner/repo
ssh-scheme            | ssh://git@github.com/owner/repo.git         | 0|owner/repo
# --- Edge (rc 0) ----------------------------------------------------------
ssh-scheme-port       | ssh://git@github.com:22/owner/repo.git      | 0|owner/repo
trailing-slash        | https://github.com/owner/repo/              | 0|owner/repo
punctuated-names      | https://github.com/my-org-x/my.repo-n.git   | 0|my-org-x/my.repo-n
uppercase-host        | https://GitHub.com/owner/repo.git           | 0|owner/repo
git-scheme            | git://github.com/owner/repo.git             | 0|owner/repo
# --- rc 1: no origin remote ----------------------------------------------
no-origin             | __NONE__                                    | 1| 
# --- rc 2: origin is not github.com --------------------------------------
gitlab-https          | https://gitlab.com/owner/repo.git           | 2| 
gitlab-scp            | git@example.com:owner/repo.git              | 2| 
ghe-subdomain         | https://sub.github.com/owner/repo.git       | 2| 
evil-suffix-host      | https://github.com.evil.com/owner/repo.git  | 2| 
evil-prefix-host      | https://notgithub.com/owner/repo.git        | 2| 
unclassifiable-url    | totally-not-a-url                           | 2| 
# --- rc 3: github.com but no extractable owner/repo ----------------------
github-root-only      | https://github.com/                         | 3| 
github-owner-only     | https://github.com/owner                    | 3| 
TABLE
}

# ===========================================================================
# Group B — CORE REGRESSION PIN for #1899:
#   a fixture carrying BOTH origin and upstream, pointing at DIFFERENT repos.
#   Resolution MUST follow origin. This is the case `gh repo view` gets wrong.
# ===========================================================================
group_origin_vs_upstream() {
    local dir got
    dir="$(mk_repo "fork" "https://github.com/origin-owner/origin-repo.git")"
    git -C "$dir" remote add upstream "https://github.com/upstream-owner/upstream-repo.git"

    got="$(call_resolver "$dir")"
    assert_eq "regression-pin/origin-wins-over-upstream" "0|origin-owner/origin-repo" "$got"

    # Reverse the pair: if the resolver ever read "the first remote" or "any
    # remote", one of the two orderings would slip through. Both must answer
    # with whatever origin says.
    dir="$(mk_repo "fork2" "__NONE__")"
    git -C "$dir" remote add upstream "https://github.com/aaa-upstream/aaa-repo.git"
    git -C "$dir" remote add origin "https://github.com/zzz-origin/zzz-repo.git"
    got="$(call_resolver "$dir")"
    assert_eq "regression-pin/origin-wins-when-added-last" "0|zzz-origin/zzz-repo" "$got"

    # upstream present but origin absent -> rc 1. Never silently fall back to
    # upstream; that fallback IS the bug.
    dir="$(mk_repo "fork3" "__NONE__")"
    git -C "$dir" remote add upstream "https://github.com/only-upstream/only-repo.git"
    got="$(call_resolver "$dir")"
    assert_eq "regression-pin/no-origin-never-falls-back-to-upstream" "1|" "$got"
}

group_resolver_table
group_origin_vs_upstream

finish
