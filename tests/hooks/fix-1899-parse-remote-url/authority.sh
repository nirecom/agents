#!/bin/bash
# tests/fix-1899-parse-remote-url/authority.sh
# Tests: hooks/lib/parse-remote-url.js
# Tags: parse-remote-url, security, authority-anchoring, table-driven, parser, regex, TL1, scope:issue-specific
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
# This JS side implements that anchoring: parseOriginOwnerRepo strips userinfo
# with `rest.replace(/^[^@/]+@/, "")`, whose character class excludes `/` so the
# match can only land inside the pre-slash authority. That mirrors the bash
# counterpart bin/github-issues/lib/origin-repo.sh, which takes the pre-slash
# authority (`auth="${rest%%/*}"`) and strips userinfo only when the `@` sits
# inside it (CPR-ORTH). Both sides are anchored and both are GREEN — every
# REJECT row below PASSES today, and none of them pins an open defect. These
# are the JS half of a CPR-ORTH mirror pair: the case NAMES and input URLs are
# identical to tests/fix-1899-origin-repo-resolver/authority.sh so the pair is
# greppable.
#
# What the REJECT rows are WORTH is not uniform, and the difference decides what
# a future failure here means. Regress the strip to an unanchored one over the
# whole rest-of-string (`rest.replace(/^[^@]+@/, "")`, or its last-`@` sibling)
# and only these three rows flip:
#   at-in-path-rebases-owner        -> unanchored resolves ok "attacker/repo"
#   at-in-path-deep                 -> unanchored resolves ok "attacker/pwn"
#   at-in-path-charset-valid-rebase -> unanchored resolves ok "attacker/pwned"
#
# The remaining three reject identically under either strip, because a guard
# other than the anchoring fires first — they are rejected by the repo-charset
# backstop (REPO_RE) or by the single-`/` owner/repo split, not because the
# anchoring caught anything:
#   at-in-path-scp-form  — no scheme, so the `:` branch runs and the strip is
#                          never reached at all; its leftover `@` fails REPO_RE
#   at-inside-repo-name  — anchored leaves repo "re@po" (charset reject);
#                          unanchored leaves "po", which has no `/` at all
#   trailing-at          — anchored leaves repo "repo@" (charset reject);
#                          unanchored leaves "", again with no `/`
# They stay in the table as regression pins against a future rewrite, but on
# their own they would NOT catch an anchoring regression and must not be read
# as doing so. That split was verified by re-running these six URLs against two
# in-memory mutants of parse-remote-url.js (`/^[^@]+@/` and `/^.*@/` over the
# whole rest); the per-row trace for the third discriminating row is inline in
# the table.
#
# The ACCEPT rows are load-bearing positive controls against an OVER-strip:
# they pin that real token-bearing and plain-userinfo remotes keep resolving.
# They do NOT block an UNDER-strip — parseOriginOwnerRepo locates owner/repo
# via the first `/` after the authority, and none of these userinfo values
# contain a `/`, so a "strip nothing at all" implementation would still
# derive the correct owner/repo for every ACCEPT row here (a documented
# limitation of this file, not a gap the REJECT rows above cover either).
# Credentials are FAKE placeholders only (`TOKEN`) — never a live shape.
#
# TL3 gap: no real `gh api repos/<owner>/<repo>` round-trip proves the redirect.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group authority — userinfo stripping is anchored to the authority component
# ===========================================================================
group_authority() {
    local name input want got
    while IFS='|' read -r name input want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; want="$(echo "$want" | xargs)"
        input="$(echo "$input" | xargs)"
        got="$(call_fn "$PRU_JS" parseOriginOwnerRepo "$input")"
        assert_eq "authority/$name" "$want" "$got"
    done <<'TABLE'
# name                       | origin url                                       | expected
# --- REJECT: an `@` in the PATH must never re-base the owner/repo parse ----
at-in-path-rebases-owner     | https://github.com/x/y@github.com/attacker/repo  | fail:unparsable-owner-repo
at-in-path-deep              | https://github.com/o/r@x/attacker/pwn            | fail:unparsable-owner-repo
# at-in-path-charset-valid-rebase is the positive proof that the ANCHORING —
# not the charset backstop — is what rejects. Both implementations traced by
# hand against this one URL:
#   anchored (current parse-remote-url.js):
#     rest = "github.com/safe/repo@attacker_host.example.com/attacker/pwned"
#     /^[^@/]+@/ cannot match (the first "/" precedes the only "@") -> no strip
#     repoPath = rest.slice(indexOf("/") + 1)
#              = "safe/repo@attacker_host.example.com/attacker/pwned"
#     owner = "safe" (valid), repo = "repo@attacker_host.example.com/attacker/pwned"
#     -> REPO_RE rejects -> fail:unparsable-owner-repo, which is want
#   unanchored (`rest.replace(/^[^@]+@/, "")`; the last-`@` variant is identical
#   here because the URL holds exactly one "@"):
#     rest = "attacker_host.example.com/attacker/pwned"
#     repoPath = "attacker/pwned" -> owner = "attacker" (valid login charset),
#     repo = "pwned" (valid charset, valid length, not "." / "..")
#     -> ok:attacker/pwned:attacker:pwned:github.com != want -> RED
# The unanchored result clears every owner/repo guard on its own, so no
# downstream check can save this row: only the anchoring keeps it rejecting.
at-in-path-charset-valid-rebase | https://github.com/safe/repo@attacker_host.example.com/attacker/pwned | fail:unparsable-owner-repo
at-in-path-scp-form          | git@github.com:o/r@x/attacker/pwn                | fail:unparsable-owner-repo
at-inside-repo-name          | https://github.com/owner/re@po                   | fail:unparsable-owner-repo
trailing-at                  | https://github.com/owner/repo@                   | fail:unparsable-owner-repo
# --- ACCEPT: real userinfo in the authority still resolves (positive control)
userinfo-token-still-resolves | https://x-access-token:TOKEN@github.com/owner/repo | ok:owner/repo:owner:repo:github.com
userinfo-plain-still-resolves | https://user@github.com/owner/repo                 | ok:owner/repo:owner:repo:github.com
no-userinfo-still-resolves    | https://github.com/owner/repo                      | ok:owner/repo:owner:repo:github.com
scp-userinfo-still-resolves   | git@github.com:owner/repo.git                      | ok:owner/repo:owner:repo:github.com
TABLE
}

group_authority

finish
