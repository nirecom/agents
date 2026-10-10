#!/bin/bash
# tests/bin/fix-1899-origin-repo-resolver/parity.sh
# Tests: bin/github-issues/lib/origin-repo.sh, hooks/lib/parse-remote-url.js, bin/is-github-dotcom-remote
# Tags: origin-resolution, parse-remote-url, parity, cpr-orth, table-driven, parser, regex, security, TL2, scope:issue-specific
# Group P — CPR-ORTH parity between the TWO resolvers #1899 created: bash
# (bin/github-issues/lib/origin-repo.sh) and JS (hooks/lib/parse-remote-url.js) both
# feed `gh api repos/<owner>/<repo>`, so a URL form one accepts and the other
# rejects resolves one checkout to different repositories per entry point. Each
# row runs through BOTH resolvers against one expected verdict (vocabulary below).
# TL2 (real git fixtures, bash, node). TL3 gap: no real `gh api` round-trip, no
# real multi-remote clone; checked at preflight via bin/check-verification-gate.sh.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

nodepath_p() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
PRU_JS="$(nodepath_p "$__LIB_SCRIPT_CHECKOUT_ROOT/hooks/lib/parse-remote-url.js")"

# Shared verdict vocabulary (bash rc + stdout | JS {ok}/{code}):
#   ok:<owner>/<repo>  bash rc 0 + stdout  | JS { ok: true, ownerRepo }
#   not-github         bash rc 2           | JS non-github-host / unparsable-host
#   unparsable-path    bash rc 3           | JS unparsable-owner-repo / empty-url
#   no-origin          bash rc 1           | (no JS counterpart — URL-only rows)
# not-github merges "wrong host" and "no host": is-github-dotcom-remote answers 2 for both.

# js_verdict <url> -> the normalized verdict of parseOriginOwnerRepo.
#   ERR:* on any load/shape problem, so a missing module reads as a FAIL with a
#   reason rather than silently matching some expected token.
js_verdict() {
    run_with_timeout 20 node -e '
const p = process.argv[1];
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require-failed"); process.exit(0); }
if (!m || typeof m.parseOriginOwnerRepo !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
let r;
try { r = m.parseOriginOwnerRepo(process.argv[2]); } catch (e) { process.stdout.write("ERR:threw"); process.exit(0); }
if (!r || typeof r !== "object") { process.stdout.write("ERR:bad-shape"); process.exit(0); }
if (r.ok === true) { process.stdout.write("ok:" + r.ownerRepo); process.exit(0); }
if (r.code === "non-github-host" || r.code === "unparsable-host") { process.stdout.write("not-github"); process.exit(0); }
if (r.code === "unparsable-owner-repo" || r.code === "empty-url") { process.stdout.write("unparsable-path"); process.exit(0); }
process.stdout.write("ERR:unknown-code:" + String(r.code));
' "$PRU_JS" "$1" 2>/dev/null
}

# sh_verdict <fixture-dir> -> the normalized verdict of resolve_origin_owner_repo.
sh_verdict() {
    local raw rc out
    raw="$(call_resolver "$1")"
    rc="${raw%%|*}"
    out="${raw#*|}"
    case "$rc" in
        0) printf 'ok:%s' "$out" ;;
        1) printf 'no-origin' ;;
        2) printf 'not-github' ;;
        3) printf 'unparsable-path' ;;
        *) printf 'ERR:rc-%s' "$rc" ;;
    esac
}

# ===========================================================================
# Group P — one table, two resolvers, one expected verdict
# ===========================================================================
group_parity_table() {
    local name url want dir i=0 got_sh got_js
    while IFS='|' read -r name url want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; url="$(echo "$url" | xargs)"; want="$(echo "$want" | xargs)"
        i=$((i + 1))
        dir="$(mk_repo "par$i" "$url")"
        got_sh="$(sh_verdict "$dir")"
        got_js="$(js_verdict "$url")"
        assert_eq "parity/$name/bash" "$want" "$got_sh"
        assert_eq "parity/$name/js"   "$want" "$got_js"
    done <<'TABLE'
# name                     | origin url                                            | normalized verdict
# --- ACCEPT: URL forms both resolvers must read identically -----------------
https-plain                | https://github.com/owner/repo                         | ok:owner/repo
https-dotgit               | https://github.com/owner/repo.git                     | ok:owner/repo
https-dotgit-trailing-slash| https://github.com/owner/repo.git/                    | ok:owner/repo
https-explicit-port        | https://github.com:443/owner/repo.git                 | ok:owner/repo
https-nondefault-port      | https://github.com:8443/owner/repo.git                | ok:owner/repo
https-userinfo-plain       | https://user@github.com/owner/repo.git                | ok:owner/repo
https-userinfo-token       | https://x-access-token:TOKEN@github.com/owner/repo.git| ok:owner/repo
http-scheme                | http://github.com/owner/repo.git                      | ok:owner/repo
git-scheme                 | git://github.com/owner/repo.git                       | ok:owner/repo
scp-plain                  | git@github.com:owner/repo                             | ok:owner/repo
scp-dotgit                 | git@github.com:owner/repo.git                         | ok:owner/repo
ssh-scheme                 | ssh://git@github.com/owner/repo.git                   | ok:owner/repo
ssh-scheme-port            | ssh://git@github.com:2222/owner/repo.git              | ok:owner/repo
# Host is matched case-INSENSITIVELY; owner/repo are echoed back case-SENSITIVELY
# (GitHub preserves the login's case, and both resolvers must hand back the bytes
# they were given rather than a lowercased approximation).
host-uppercase             | https://GITHUB.COM/owner/repo.git                     | ok:owner/repo
host-mixed-case            | https://GitHub.Com/owner/repo.git                     | ok:owner/repo
owner-repo-case-preserved  | https://github.com/OwNer/RePo.git                     | ok:OwNer/RePo
repo-leading-dot           | https://github.com/owner/.config                      | ok:owner/.config
repo-inner-dots            | https://github.com/owner/repo.js.git                  | ok:owner/repo.js
# --- REJECT: host is not exactly github.com --------------------------------
lookalike-suffix-host      | https://github.com.evil.com/owner/repo.git            | not-github
lookalike-prefix-host      | https://not-github.com/owner/repo.git                 | not-github
lookalike-nodash-host      | https://notgithub.com/owner/repo.git                  | not-github
subdomain-host             | https://sub.github.com/owner/repo.git                 | not-github
enterprise-scp-host        | git@github.company.com:owner/repo.git                 | not-github
lookalike-suffix-scp       | git@github.com.evil.com:owner/repo.git                | not-github
gitlab-https               | https://gitlab.com/owner/repo.git                     | not-github
no-host-at-all             | totally-not-a-url                                     | not-github
local-path-remote          | /srv/git/mirror.git                                   | not-github
# --- REJECT: github.com, but the path does not name one owner/repo ---------
missing-path               | https://github.com                                    | unparsable-path
root-only                  | https://github.com/                                   | unparsable-path
owner-only                 | https://github.com/owner                              | unparsable-path
path-too-deep              | https://github.com/owner/team/repo                    | unparsable-path
dot-segment-owner          | https://github.com/../repo                            | unparsable-path
dot-segment-repo           | https://github.com/owner/..                           | unparsable-path
single-dot-repo            | https://github.com/owner/.                            | unparsable-path
owner-out-of-charset-plus  | https://github.com/own+er/repo                         | unparsable-path
owner-out-of-charset-under | https://github.com/own_er/repo                         | unparsable-path
repo-out-of-charset-pct    | https://github.com/owner/re%po                        | unparsable-path
at-embedded-in-path        | https://github.com/x/y@github.com/attacker/repo       | unparsable-path
TABLE
}

# ===========================================================================
# Group P2 — owner-length boundary, built programmatically on BOTH sides.
#   39 is the maximum legal GitHub login length. A literal in the table above
#   could be miscounted and silently invert the assertion; these cannot.
# ===========================================================================
group_parity_length_boundary() {
    local owner39 owner40 dir
    owner39="$(printf 'a%.0s' $(seq 1 39))"
    owner40="$(printf 'a%.0s' $(seq 1 40))"

    dir="$(mk_repo "par-len39" "https://github.com/$owner39/repo")"
    assert_eq "parity/owner-len-39/bash" "ok:$owner39/repo" "$(sh_verdict "$dir")"
    assert_eq "parity/owner-len-39/js"   "ok:$owner39/repo" "$(js_verdict "https://github.com/$owner39/repo")"

    dir="$(mk_repo "par-len40" "https://github.com/$owner40/repo")"
    assert_eq "parity/owner-len-40/bash" "unparsable-path" "$(sh_verdict "$dir")"
    assert_eq "parity/owner-len-40/js"   "unparsable-path" "$(js_verdict "https://github.com/$owner40/repo")"
}

group_parity_table
group_parity_length_boundary

finish
