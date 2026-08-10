#!/bin/bash
# tests/fix-1899-parse-remote-url/host-and-repo-id.sh
# Tests: hooks/lib/parse-remote-url.js
# Tags: parse-remote-url, origin-resolution, table-driven, parser, regex, TL1, scope:issue-specific
#
# Groups B and C of the fix-1899-parse-remote-url split suite — the two helpers
# that moved into parse-remote-url.js: extractHost (broadened scheme regex) and
# extractRepoId (moved unchanged, pinned as a regression on the moved code).
#
# TL3 gap: no real `git remote get-url origin` output shapes on a live checkout.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group B — extractHost: existing behavior preserved + broadened scheme regex
#
# The scheme regex broadens to ^[A-Za-z][A-Za-z0-9+.-]*:\/\/ , matching the
# already-shipped bash counterpart in bin/is-github-dotcom-remote. The git://
# and svn+ssh:// rows are the discriminators: they return null against today's
# `(?:ssh|https?)` alternation.
# ===========================================================================
group_extract_host() {
    local name input want got
    while IFS='|' read -r name input want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; want="$(echo "$want" | xargs)"
        input="$(echo "$input" | xargs)"
        got="$(call_fn "$PRU_JS" extractHost "$input")"
        assert_eq "extractHost/$name" "$want" "$got"
    done <<'TABLE'
scp-github          | git@github.com:owner/repo.git                  | github.com
https-github        | https://github.com/owner/repo.git              | github.com
http-github         | http://github.com/owner/repo.git               | github.com
ssh-scheme-port     | ssh://git@gitlab.example.com:2222/owner/r.git  | gitlab.example.com
scp-gitlab          | git@gitlab.example.com:owner/repo.git          | gitlab.example.com
scp-enterprise      | git@github.company.com:owner/repo.git          | github.company.com
git-scheme          | git://github.com/owner/repo.git                | github.com
svn-plus-ssh-scheme | svn+ssh://git@github.com/owner/repo.git        | github.com
empty               | __EMPTY__                                      | null
garbage             | totally-not-a-url                              | null
TABLE
}

# ===========================================================================
# Group C — extractRepoId: moved unchanged (regression pin on the moved code)
# ===========================================================================
group_extract_repo_id() {
    local name input want got
    while IFS='|' read -r name input want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; want="$(echo "$want" | xargs)"
        input="$(echo "$input" | xargs)"
        got="$(call_fn "$PRU_JS" extractRepoId "$input")"
        assert_eq "extractRepoId/$name" "$want" "$got"
    done <<'TABLE'
scp-dotgit    | git@github.com:owner/repo.git      | owner/repo
https-dotgit  | https://github.com/owner/repo.git  | owner/repo
scp-no-dotgit | git@github.com:owner/repo          | owner/repo
https-no-dot  | https://github.com/owner/repo      | owner/repo
empty         | __EMPTY__                          | null
TABLE
}

group_extract_host
group_extract_repo_id

finish
