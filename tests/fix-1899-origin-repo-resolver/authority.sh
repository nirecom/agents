#!/bin/bash
# tests/fix-1899-origin-repo-resolver/authority.sh
# Tests: bin/github-issues/lib/origin-repo.sh
# Tags: origin-resolution, github-issues, security, authority-anchoring, table-driven, TL2, scope:issue-specific
#
# F-B [HIGH] — userinfo stripping must be anchored to the AUTHORITY component.
#
# Why: a git remote URL may carry userinfo (`user@` or `user:pass@`) between the
# scheme and the host, so both resolvers strip it before reading owner/repo. The
# `@` that ends userinfo is only meaningful where the authority is — but `@` is a
# legal byte further along the URL too, inside the PATH. A strip that is not
# anchored to the authority re-bases the parse on an `@` sitting in the PATH, so
# an attacker who controls any path text can name a repository the caller never
# asked for, and that value flows into an authenticated `gh api repos/<o>/<r>`.
#
# This bash side implements that anchoring: origin-repo.sh takes the pre-slash
# authority (`auth="${rest%%/*}"`) and strips userinfo only when the `@` sits
# inside it. That mirrors the JS counterpart's `rest.replace(/^[^@/]+@/, "")`
# (CPR-ORTH), whose character class excludes `/` for exactly this reason. Every
# REJECT row below therefore PASSES today — none of them pins an open defect.
# These are the bash half of a CPR-ORTH mirror: the case NAMES and input URLs of
# the five shared rows are identical to tests/fix-1899-parse-remote-url/
# authority.sh so the pair is greppable. The sixth row,
# at-in-path-charset-valid-rebase, is bash-only — it has no JS sibling yet.
#
# What the REJECT rows are WORTH is not uniform, and the difference decides what
# a future failure here means. Regress the strip to an unanchored one over the
# whole rest-of-string (`rest="${rest#*@}"`, or its last-`@` sibling
# `${rest##*@}`) and only these three rows flip:
#   at-in-path-rebases-owner        -> unanchored resolves rc 0 "attacker/repo"
#   at-in-path-deep                 -> unanchored resolves rc 0 "attacker/pwn"
#   at-in-path-charset-valid-rebase -> unanchored resolves rc 0 "attacker/pwned"
#
# The remaining three reject identically under either strip, because a guard
# other than the anchoring fires first — they are rejected by the repo-charset
# backstop (`[[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]]`) or by the `*/*` owner/repo
# guard, not because the anchoring caught anything:
#   at-in-path-scp-form  — the scp branch parses via `${url#*:}` and never runs
#                          the strip at all; its leftover `@` fails the charset
#   at-inside-repo-name  — anchored leaves repo "re@po" (charset reject);
#                          unanchored leaves "po", which has no `/` at all
#   trailing-at          — anchored leaves repo "repo@" (charset reject);
#                          unanchored leaves "", again with no `/`
# They stay in the table as regression pins against a future rewrite, but on
# their own they would NOT catch an anchoring regression and must not be read
# as doing so. That split was verified by re-running this table against two
# hand-built mutants of origin-repo.sh (`#*@` and `##*@` over the full rest);
# the per-row trace for the third discriminating row is inline in the table.
#
# Each REJECT fixture carries a real github.com origin, so
# bin/is-github-dotcom-remote returns 0 and execution reaches the final
# owner/repo validation. The assertion is on rc 3 specifically: rc 2 would mean
# the host classifier rejected it first and the charset gate was never reached,
# which would make the case vacuous.
#
# The ACCEPT rows are load-bearing positive controls against an OVER-strip:
# they pin that real token-bearing and plain-userinfo remotes keep resolving.
# They do NOT block an UNDER-strip — owner/repo is located via the first `/`
# after the authority, and none of these userinfo values contain a `/`, so a
# "strip nothing at all" implementation would still derive the correct
# owner/repo for every ACCEPT row here (a documented limitation of this
# file, not a gap the REJECT rows above cover either). Credentials are FAKE
# placeholders only (`TOKEN`) — never a live shape.
#
# TL2 (real git fixtures, real bash). TL3 gap: no real `gh api repos/<o>/<r>`
# round-trip proves the redirect. Closest-to-action mitigation:
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category:
# skill-orchestration.

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
# not the charset backstop — is what rejects. Both implementations traced by
# hand against this one URL:
#   anchored (current origin-repo.sh):
#     rest = "github.com/safe/repo@attacker_host.example.com/attacker/pwned"
#     auth = "${rest%%/*}" = "github.com", holds no "@" -> no strip
#     path = "${rest#*/}"  = "safe/repo@attacker_host.example.com/attacker/pwned"
#     owner = "safe" (valid), repo = "repo@attacker_host.example.com/attacker/pwned"
#     -> repo charset rejects -> rc 3, which is want
#   unanchored (`rest="${rest#*@}"` over the whole rest; `${rest##*@}` is
#   identical here because the URL holds exactly one "@"):
#     rest = "attacker_host.example.com/attacker/pwned" -> path = "attacker/pwned"
#     owner = "attacker" (valid login charset), repo = "pwned" (valid charset,
#     valid length, not "." / "..") -> rc 0 "attacker/pwned" != want -> RED
# The unanchored result clears every owner/repo guard on its own, so no
# downstream check can save this row: only the anchoring keeps it rejecting.
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
