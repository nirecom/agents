#!/bin/bash
# tests/fix-1899-parse-remote-url/parse-origin.sh
# Tests: hooks/lib/parse-remote-url.js
# Tags: parse-remote-url, origin-resolution, table-driven, parser, regex, TL1, scope:issue-specific
#
# Group A of the fix-1899-parse-remote-url split suite — parseOriginOwnerRepo's
# normal / edge / error verdicts, plus the host-classifier boundary strings.
#
# TL3 gap: no real `git remote get-url origin` output shapes on a live checkout.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group A — parseOriginOwnerRepo (NEW): normal / error / edge, table-driven
# ===========================================================================
group_parse_origin_owner_repo() {
    local name input want got
    while IFS='|' read -r name input want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"
        want="$(echo "$want" | xargs)"
        input="$(echo "$input" | xargs)"
        got="$(call_fn "$PRU_JS" parseOriginOwnerRepo "$input")"
        assert_eq "parseOriginOwnerRepo/$name" "$want" "$got"
    done <<'TABLE'
# --- Normal ---------------------------------------------------------------
https-dotgit          | https://github.com/owner/repo.git            | ok:owner/repo:owner:repo:github.com
ssh-scp-dotgit        | git@github.com:owner/repo.git                | ok:owner/repo:owner:repo:github.com
https-no-dotgit       | https://github.com/owner/repo                | ok:owner/repo:owner:repo:github.com
ssh-scp-no-dotgit     | git@github.com:owner/repo                    | ok:owner/repo:owner:repo:github.com
# --- Edge -----------------------------------------------------------------
ssh-scheme-port       | ssh://git@github.com:22/owner/repo.git       | ok:owner/repo:owner:repo:github.com
ssh-scheme-no-port    | ssh://git@github.com/owner/repo.git          | ok:owner/repo:owner:repo:github.com
git-scheme            | git://github.com/owner/repo.git              | ok:owner/repo:owner:repo:github.com
trailing-slash        | https://github.com/owner/repo/               | ok:owner/repo:owner:repo:github.com
trailing-slash-dotgit | https://github.com/owner/repo.git/           | ok:owner/repo:owner:repo:github.com
punctuated-names      | https://github.com/my-org-x/my.repo-name.git | ok:my-org-x/my.repo-name:my-org-x:my.repo-name:github.com
uppercase-host        | https://GitHub.com/owner/repo.git            | ok:owner/repo:owner:repo:github.com
http-scheme           | http://github.com/owner/repo.git             | ok:owner/repo:owner:repo:github.com
# --- Error ----------------------------------------------------------------
empty-string          | __EMPTY__                                    | fail:empty-url
null-input            | __NULL__                                     | fail:empty-url
garbage               | totally-not-a-url                            | fail:unparsable-host
bare-path             | /not/a/git/remote/dir                        | fail:unparsable-host
gitlab-https          | https://gitlab.com/owner/repo.git            | fail:non-github-host
gitlab-scp            | git@example.com:owner/repo.git               | fail:non-github-host
bitbucket-scp         | git@example.org:owner/repo.git               | fail:non-github-host
github-root-only      | https://github.com/                          | fail:unparsable-owner-repo
github-owner-only     | https://github.com/owner                     | fail:unparsable-owner-repo
github-no-path        | https://github.com                           | fail:unparsable-owner-repo
# --- Classifier guard: host-check boundary strings ------------------------
evil-suffix-host      | https://github.com.evil.com/owner/repo.git   | fail:non-github-host
evil-prefix-host      | https://notgithub.com/owner/repo.git         | fail:non-github-host
subdomain-host        | https://sub.github.com/owner/repo.git        | fail:non-github-host
enterprise-host       | git@github.company.com:owner/repo.git        | fail:non-github-host
evil-suffix-scp       | git@github.com.evil.com:owner/repo.git       | fail:non-github-host
TABLE
}

group_parse_origin_owner_repo

finish
