#!/bin/bash
# tests/fix-1899-origin-repo-resolver/authority.sh
# Tests: bin/github-issues/lib/origin-repo.sh
# Tags: origin-resolution, github-issues, security, authority-anchoring, table-driven, TL2, scope:issue-specific
#
# F-B [HIGH] — userinfo stripping must be anchored to the AUTHORITY component,
# not scanned across the whole URL. `@` is also a legal PATH byte, so an
# unanchored strip lets an attacker-controlled path segment re-base the
# owner/repo parse into an authenticated `gh api repos/<o>/<r>` call.
# origin-repo.sh strips userinfo only from the pre-slash authority
# (`auth="${rest%%/*}"`), mirroring the JS sibling's
# `rest.replace(/^[^@/]+@/, "")` (CPR-ORTH) — see
# tests/fix-1899-parse-remote-url/authority.sh for the paired table.
# Regressing to an unanchored strip flips the at-in-path-* rows to resolve
# an attacker-controlled owner/repo instead of rejecting. Credentials in the
# ACCEPT rows are FAKE placeholders (`TOKEN`), never a live shape.
#
# TL2 (real git fixtures, real bash). TL3 gap: no real `gh api repos/<o>/<r>`
# round-trip proves the redirect. Mitigated at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group authority — userinfo stripping is anchored to the authority component
# ===========================================================================
group_authority() {
    local name url want got dir i=0
    while IFS='|' read -r name url want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; url="$(echo "$url" | xargs)"; want="$(echo "$want" | xargs)"
        i=$((i + 1))
        dir="$(mk_repo "auth$i" "$url")"
        got="$(call_resolver "$dir")"
        assert_eq "authority/$name" "$want" "$got"
    done <<'TABLE'
# name                        | origin url                                        | rc|stdout
# --- REJECT: an `@` in the PATH must never re-base the owner/repo parse ----
at-in-path-rebases-owner      | https://github.com/x/y@github.com/attacker/repo    | 3| 
at-in-path-deep               | https://github.com/o/r@x/attacker/pwn              | 3| 
# at-in-path-charset-valid-rebase is the positive proof that the ANCHORING —
# not the charset backstop — is what rejects: unanchored, this URL clears
# every owner/repo guard and resolves to "attacker/pwned" instead of rc 3.
at-in-path-charset-valid-rebase | https://github.com/safe/repo@attacker_host.example.com/attacker/pwned | 3| 
at-in-path-scp-form           | git@github.com:o/r@x/attacker/pwn                  | 3| 
at-inside-repo-name           | https://github.com/owner/re@po                     | 3| 
trailing-at                   | https://github.com/owner/repo@                     | 3| 
# --- ACCEPT: real userinfo in the authority still resolves (positive control)
userinfo-token-still-resolves | https://x-access-token:TOKEN@github.com/owner/repo | 0|owner/repo
userinfo-plain-still-resolves | https://user@github.com/owner/repo                 | 0|owner/repo
no-userinfo-still-resolves    | https://github.com/owner/repo                      | 0|owner/repo
scp-userinfo-still-resolves   | git@github.com:owner/repo.git                      | 0|owner/repo
TABLE
}

group_authority

finish
