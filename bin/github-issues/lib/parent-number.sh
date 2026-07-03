#!/bin/bash
# lib/parent-number.sh — sourceable helper.
#
# github_parent_number <owner/repo> <N>
#   Echoes the parent issue number of sub-issue <N> on stdout; empty when the
#   issue has no parent (or on API error / invalid args).
#
# Why GraphQL: GitHub's REST Issues API (GET /repos/{owner}/{repo}/issues/{N})
# does not populate a `.parent` field for sub-issues — the parent link is only
# reachable via GraphQL. Every parent-detection caller must go through this
# helper; using the REST `.parent.number` form silently always returns empty.
#
# Contract: exit 0 always. Empty stdout == "no parent" — matching the fail-soft
# behavior every caller already relied on (they treat empty as skip/no-op).

github_parent_number() {
    local repo="$1" n="$2" owner name
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    owner="${repo%%/*}"
    name="${repo##*/}"
    gh api graphql \
        -f query="{ repository(owner: \"${owner}\", name: \"${name}\") { issue(number: ${n}) { parent { number } } } }" \
        --jq '.data.repository.issue.parent.number // empty' 2>/dev/null | tr -d '\r'
}
