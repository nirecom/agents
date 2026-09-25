#!/bin/bash
# tests/fix-1899-origin-repo-resolver/owner-repo-charset.sh
# Tests: bin/github-issues/lib/origin-repo.sh
# Tags: origin-resolution, github-issues, security, path-traversal, table-driven, TL2, scope:issue-specific
#
# Groups F, G and H of the fix-1899-origin-repo-resolver split suite — the
# owner/repo charset contract, the bash half of the CPR-ORTH mirror whose JS half
# is tests/fix-1899-parse-remote-url/owner-repo-charset.sh.
#
# Why: F1 [HIGH] from the security review — the inline regex closing
# resolve_origin_owner_repo admitted `.` and `..` as a WHOLE segment, so an origin
# of https://github.com/../x.git resolved rc 0 with owner='..'. That value is
# interpolated into an authenticated `gh api repos/../x`, where URL normalization
# collapses the path into a repository nobody named. F holds the rejects, G the
# sanctioned inputs that must survive the narrowing, H the property-shaped
# boundary invariant over both.
#
# Contract (hooks/lib/parse-remote-url.js must agree — CPR-ORTH):
#   owner — GitHub login charset: leading [A-Za-z0-9], then [A-Za-z0-9-], 1..39
#   repo  — [A-Za-z0-9._-]{1,100}, never exactly "." or ".."
#
# TL2 (real git fixtures, real bash). TL3 gap: no real `gh api repos/<o>/<r>`
# round-trip proves the collapse. Mitigated at WORKFLOW_USER_VERIFIED preflight
# (bin/check-verification-gate.sh).

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group F — F1 [HIGH] mirror: dot-segment / out-of-charset owner|repo -> rc 3
#
#   Every fixture below carries a REAL github.com origin url, so
#   bin/is-github-dotcom-remote returns 0 and execution reaches the final
#   owner/repo validation. The assertion is on rc 3 specifically: rc 2 would mean
#   the host classifier rejected it first and the charset gate was never reached,
#   which would make the case vacuous.
# ===========================================================================
group_traversal_rejects() {
    local name url want got dir i=0
    while IFS='|' read -r name url want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; url="$(echo "$url" | xargs)"; want="$(echo "$want" | xargs)"
        i=$((i + 1))
        dir="$(mk_repo "rej$i" "$url")"
        got="$(call_resolver "$dir")"
        assert_eq "reject/$name" "$want" "$got"
    done <<'TABLE'
# name                | origin url                                  | rc|stdout
# --- dot-segment as a WHOLE owner or repo segment ------------------------
https-owner-dotdot    | https://github.com/../x.git                 | 3| 
https-owner-dot       | https://github.com/./x                      | 3| 
https-repo-dotdot     | https://github.com/a/..                     | 3| 
https-repo-dot        | https://github.com/a/.                      | 3| 
scp-owner-dotdot      | git@github.com:../x.git                     | 3| 
scp-owner-dot         | git@github.com:./x                          | 3| 
scp-repo-dotdot       | git@github.com:a/..                         | 3| 
ssh-scheme-owner-dotdot | ssh://git@github.com/../x                 | 3| 
both-dotdot           | https://github.com/../..                    | 3| 
# --- owner charset is the GitHub login charset, not the repo charset -----
owner-underscore      | https://github.com/a_b/x                    | 3| 
owner-dot             | https://github.com/a.b/x                    | 3| 
owner-leading-dash    | https://github.com/-abc/x                   | 3| 
TABLE

    # Length boundary, built programmatically so a miscounted literal cannot
    # silently invert the assertion.
    local owner39 owner40 d
    owner39="$(printf 'a%.0s' $(seq 1 39))"
    owner40="$(printf 'a%.0s' $(seq 1 40))"
    d="$(mk_repo "rej-len40" "https://github.com/$owner40/x")"
    assert_eq "reject/owner-len-40" "3|" "$(call_resolver "$d")"
    d="$(mk_repo "rej-len39" "https://github.com/$owner39/x")"
    assert_eq "accept/owner-len-39" "0|$owner39/x" "$(call_resolver "$d")"

    # Repo length: 100 is the contract maximum, 101 is over.
    local repo100 repo101
    repo100="$(printf 'b%.0s' $(seq 1 100))"
    repo101="$(printf 'b%.0s' $(seq 1 101))"
    d="$(mk_repo "rej-repo101" "https://github.com/a/$repo101")"
    assert_eq "reject/repo-len-101" "3|" "$(call_resolver "$d")"
    d="$(mk_repo "acc-repo100" "https://github.com/a/$repo100")"
    assert_eq "accept/repo-len-100" "0|a/$repo100" "$(call_resolver "$d")"
}

# ===========================================================================
# Group G — positive mirrors: the F1 charset fix must not over-tighten
# ===========================================================================
group_charset_accepts() {
    local name url want got dir i=0
    while IFS='|' read -r name url want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; url="$(echo "$url" | xargs)"; want="$(echo "$want" | xargs)"
        i=$((i + 1))
        dir="$(mk_repo "acc$i" "$url")"
        got="$(call_resolver "$dir")"
        assert_eq "accept/$name" "$want" "$got"
    done <<'TABLE'
real-https-dotgit  | https://github.com/nirecom/agents.git     | 0|nirecom/agents
real-scp-dotgit    | git@github.com:nirecom/agents.git         | 0|nirecom/agents
real-ssh-scheme    | ssh://git@github.com/nirecom/agents       | 0|nirecom/agents
real-trailing-slash| https://github.com/nirecom/agents/        | 0|nirecom/agents
repo-inner-dots    | https://github.com/nirecom/repo.js.git    | 0|nirecom/repo.js
repo-underscore    | https://github.com/nirecom/some_repo-2    | 0|nirecom/some_repo-2
repo-leading-dot   | https://github.com/nirecom/.config        | 0|nirecom/.config
owner-len-1        | https://github.com/a/x                    | 0|a/x
owner-digits       | https://github.com/0org/repo              | 0|0org/repo
owner-inner-dash   | https://github.com/my-org-x/repo          | 0|my-org-x/repo
TABLE
}

# ===========================================================================
# Group H — boundary invariant: whatever the resolver prints on rc 0 is
#   interpolated into `gh api repos/<owner>/<repo>`. Across the whole adversarial
#   set, an rc-0 answer may never contain a third path segment or a dot-segment.
#   Stated as a property so a URL shape nobody wrote a row for is still caught.
# ===========================================================================
group_no_traversal_boundary() {
    local url got owner repo bad="" dir i=0
    for url in \
        "https://github.com/../x.git" \
        "https://github.com/./x" \
        "https://github.com/a/.." \
        "https://github.com/a/." \
        "https://github.com/../.." \
        "git@github.com:../x.git" \
        "git@github.com:a/.." \
        "ssh://git@github.com/../x" \
        "https://github.com/a/b/../../c" \
        "https://github.com/nirecom/agents.git"; do
        i=$((i + 1))
        dir="$(mk_repo "bnd$i" "$url")"
        got="$(call_resolver "$dir")"
        case "$got" in 0\|*) ;; *) continue ;; esac
        got="${got#0|}"
        owner="${got%%/*}"
        repo="${got#*/}"
        case "$owner" in .|..|*/*) bad="$bad [$url owner=$owner]" ;; esac
        case "$repo" in .|..|*/*) bad="$bad [$url repo=$repo]" ;; esac
    done
    assert_eq "boundary/no-traversal-in-owner-or-repo" "clean" "${bad:-clean}"
}

group_traversal_rejects
group_charset_accepts
group_no_traversal_boundary

finish
