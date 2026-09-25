#!/bin/bash
# tests/fix-1899-parse-remote-url/owner-repo-charset.sh
# Tests: hooks/lib/parse-remote-url.js
# Tags: parse-remote-url, security, path-traversal, table-driven, parser, regex, TL1, scope:issue-specific
#
# Groups F, G and J of the fix-1899-parse-remote-url split suite — the owner/repo
# charset contract. F1 [HIGH]: OWNER_REPO_RE admitted `.`/`..` as a WHOLE segment,
# so https://github.com/../x.git yielded owner='..' and flowed into an
# authenticated `gh api repos/../x` whose URL normalization collapses the path.
# F holds the rejects, G the sanctioned inputs that must survive the narrowing,
# J the property-shaped boundary invariant over both.
#
# Contract (bin/github-issues/lib/origin-repo.sh must agree — CPR-ORTH):
#   owner — GitHub login charset, leading [A-Za-z0-9] then [A-Za-z0-9-], 1..39
#   repo  — [A-Za-z0-9._-]{1,100}, never exactly "." or ".."
#
# TL3 gap: no real `gh api repos/<owner>/<repo>` round-trip proves the collapse.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group F — F1 [HIGH]: dot-segment and out-of-charset owner/repo must be REJECTED
#
#   Every row resolves today, and the value is interpolated straight into
#   `gh api repos/<owner>/<repo>`. The verdict must be a hard parse failure —
#   fail:unparsable-owner-repo — not a "sanitized" rewrite.
# ===========================================================================
group_owner_repo_charset_rejects() {
    local name input want got
    while IFS='|' read -r name input want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; want="$(echo "$want" | xargs)"
        input="$(echo "$input" | xargs)"
        got="$(call_fn "$PRU_JS" parseOriginOwnerRepo "$input")"
        assert_eq "reject/$name" "$want" "$got"
    done <<'TABLE'
# --- F1: dot-segment as a WHOLE owner or repo segment ---------------------
https-owner-dotdot    | https://github.com/../x.git      | fail:unparsable-owner-repo
https-owner-dot       | https://github.com/./x           | fail:unparsable-owner-repo
https-repo-dotdot     | https://github.com/a/..          | fail:unparsable-owner-repo
https-repo-dot        | https://github.com/a/.           | fail:unparsable-owner-repo
scp-owner-dotdot      | git@github.com:../x.git          | fail:unparsable-owner-repo
scp-owner-dot         | git@github.com:./x               | fail:unparsable-owner-repo
scp-repo-dotdot       | git@github.com:a/..              | fail:unparsable-owner-repo
ssh-scheme-owner-dotdot | ssh://git@github.com/../x      | fail:unparsable-owner-repo
both-dotdot           | https://github.com/../..         | fail:unparsable-owner-repo
# --- F1: owner charset is the GitHub login charset, not the repo charset --
owner-underscore      | https://github.com/a_b/x         | fail:unparsable-owner-repo
owner-dot             | https://github.com/a.b/x         | fail:unparsable-owner-repo
owner-leading-dash    | https://github.com/-abc/x        | fail:unparsable-owner-repo
TABLE

    # Length boundary: 39 is the maximum legal GitHub login length, 40 is over.
    # Built programmatically so the assertion cannot drift from a miscounted
    # literal in the table.
    local owner39 owner40
    owner39="$(printf 'a%.0s' $(seq 1 39))"
    owner40="$(printf 'a%.0s' $(seq 1 40))"
    assert_eq "reject/owner-len-40" "fail:unparsable-owner-repo" \
        "$(call_fn "$PRU_JS" parseOriginOwnerRepo "https://github.com/$owner40/x")"
    # CPR-ORTH counterpart: the maximum LEGAL length must not be over-tightened.
    assert_eq "accept/owner-len-39" "ok:$owner39/x:$owner39:x:github.com" \
        "$(call_fn "$PRU_JS" parseOriginOwnerRepo "https://github.com/$owner39/x")"

    # Repo length: 100 is the contract maximum, 101 is over.
    local repo100 repo101
    repo100="$(printf 'b%.0s' $(seq 1 100))"
    repo101="$(printf 'b%.0s' $(seq 1 101))"
    assert_eq "reject/repo-len-101" "fail:unparsable-owner-repo" \
        "$(call_fn "$PRU_JS" parseOriginOwnerRepo "https://github.com/a/$repo101")"
    assert_eq "accept/repo-len-100" "ok:a/$repo100:a:$repo100:github.com" \
        "$(call_fn "$PRU_JS" parseOriginOwnerRepo "https://github.com/a/$repo100")"
}

# ===========================================================================
# Group G — positive regressions: the F1 fix narrows a charset, and these are the
#   sanctioned inputs that must survive it (the classifier's other verdict).
# ===========================================================================
group_owner_repo_charset_accepts() {
    local name input want got
    while IFS='|' read -r name input want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; want="$(echo "$want" | xargs)"
        input="$(echo "$input" | xargs)"
        got="$(call_fn "$PRU_JS" parseOriginOwnerRepo "$input")"
        assert_eq "accept/$name" "$want" "$got"
    done <<'TABLE'
real-https-dotgit  | https://github.com/nirecom/agents.git      | ok:nirecom/agents:nirecom:agents:github.com
real-scp-dotgit    | git@github.com:nirecom/agents.git          | ok:nirecom/agents:nirecom:agents:github.com
real-ssh-scheme    | ssh://git@github.com/nirecom/agents        | ok:nirecom/agents:nirecom:agents:github.com
real-trailing-slash| https://github.com/nirecom/agents/         | ok:nirecom/agents:nirecom:agents:github.com
repo-inner-dots    | https://github.com/nirecom/repo.js.git     | ok:nirecom/repo.js:nirecom:repo.js:github.com
repo-underscore    | https://github.com/nirecom/some_repo-2     | ok:nirecom/some_repo-2:nirecom:some_repo-2:github.com
owner-len-1        | https://github.com/a/x                     | ok:a/x:a:x:github.com
owner-digits       | https://github.com/0org/repo               | ok:0org/repo:0org:repo:github.com
owner-inner-dash   | https://github.com/my-org-x/repo           | ok:my-org-x/repo:my-org-x:repo:github.com
repo-leading-dot   | https://github.com/nirecom/.config         | ok:nirecom/.config:nirecom:.config:github.com
TABLE
}

# ===========================================================================
# Group J — boundary invariant (F1 downstream): whatever parseOriginOwnerRepo
#   hands back is interpolated into `gh api repos/<owner>/<repo>`, so a SUCCESS
#   may never carry a path separator, a percent-escape, or a dot-segment. The
#   property-shaped form of group F, catching URL shapes nobody wrote a row for.
# ===========================================================================
group_no_traversal_boundary() {
    local got
    got=$(run_with_timeout 20 node -e '
const p = process.argv[1];
let m;
try { m = require(p); } catch (e) { process.stdout.write("ERR:require-failed"); process.exit(0); }
if (!m || typeof m.parseOriginOwnerRepo !== "function") { process.stdout.write("ERR:not-a-function"); process.exit(0); }
const urls = [
  "https://github.com/../x.git",
  "https://github.com/./x",
  "https://github.com/a/..",
  "https://github.com/a/.",
  "https://github.com/../..",
  "git@github.com:../x.git",
  "git@github.com:a/..",
  "ssh://git@github.com/../x",
  "https://github.com/a/b/../../c",
  "https://github.com/a%2F../x",
  "https://github.com/nirecom/agents.git",
];
const bad = [];
for (const u of urls) {
  let r;
  try { r = m.parseOriginOwnerRepo(u); } catch (e) { bad.push(u + " -> threw"); continue; }
  if (!r || r.ok !== true) continue;
  for (const pair of [["owner", r.owner], ["repo", r.repo]]) {
    const k = pair[0], v = pair[1];
    if (typeof v !== "string" || v === "" || v === "." || v === ".." || /[\/\\]/.test(v) || v.indexOf("%") >= 0) {
      bad.push(u + " -> " + k + "=" + v);
    }
  }
}
process.stdout.write(bad.length ? bad.join(" ; ") : "clean");
' "$PRU_JS" 2>/dev/null)
    assert_eq "boundary/no-traversal-in-owner-or-repo" "clean" "$got"
}

group_owner_repo_charset_rejects
group_owner_repo_charset_accepts
group_no_traversal_boundary

finish
