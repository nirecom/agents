# origin-repo.sh — resolve repository identity from the ORIGIN remote only.
#
# Sourced (not executed). The GitHub API is asked which repository a checkout
# belongs to and can answer with `upstream` on a fork carrying both remotes
# (#1899), so every bash caller resolves identity here instead.
#
# resolve_origin_owner_repo [<dir>]   (<dir> defaults to the current directory)
#   rc 0 — prints "owner/repo" resolved from the origin remote
#   rc 1 — no origin remote (or not a git repo)
#   rc 2 — origin exists but is not confirmed to be github.com
#   rc 3 — origin is github.com but owner/repo is not extractable

resolve_origin_owner_repo() {
    local dir="${1:-.}"
    local url lib_dir rest auth path owner repo

    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
    if [[ -z "$url" ]]; then
        return 1
    fi

    # Classify the URL just read — not the directory. Handing over "$dir" would
    # make the helper run its OWN `git remote get-url origin`, so the bytes it
    # approves need not be the bytes parsed below; a remote rewritten between
    # the two reads would yield an owner/repo no host check ever validated, and
    # that pair reaches `gh api repos/<owner>/<repo>` under the caller's token
    # (#1899). Passing the value makes parsed and classified identical.
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$lib_dir/../../is-github-dotcom-remote" --url "$url" || return 2

    while [[ "$url" == */ ]]; do url="${url%/}"; done
    url="${url%.git}"

    if [[ "$url" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
        rest="${url#*://}"
        # Userinfo lives in the AUTHORITY only, so the strip must be anchored
        # there: an unanchored "${rest#*@}" would also honour an "@" the URL
        # author put in the PATH (e.g. ".../<owner>/<repo>@<host>/attacker/repo")
        # and re-base the parse onto a repository nobody named — which then
        # reaches `gh api repos/<owner>/<repo>` under the caller's token. Mirrors the JS
        # counterpart hooks/lib/parse-remote-url.js (CPR-ORTH), whose
        # /^[^@/]+@/ excludes "/" for exactly this reason.
        auth="${rest%%/*}"
        if [[ "$auth" == *@* ]]; then
            rest="${rest#*@}"
        fi
        [[ "$rest" == */* ]] || return 3
        path="${rest#*/}"
    elif [[ "$url" == *:* ]]; then
        path="${url#*:}"
    else
        return 3
    fi

    [[ "$path" == */* ]] || return 3
    # Split on the SINGLE separator: a deeper path (a/b/c) leaves "b/c" as the
    # repo candidate, which the repo charset below then rejects.
    owner="${path%%/*}"
    repo="${path#*/}"

    # owner/repo end up interpolated into `gh api repos/<owner>/<repo>`, so a
    # "." or ".." segment traverses into a repository nobody named. Mirrors the
    # JS counterpart hooks/lib/parse-remote-url.js verbatim (CPR-ORTH):
    #   owner — GitHub login charset: leading alnum, then alnum/hyphen, 1..39
    #   repo  — [A-Za-z0-9._-] 1..100, never exactly "." or ".."
    [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || return 3
    [[ "$repo" != "." && "$repo" != ".." ]] || return 3
    [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] || return 3
    (( ${#repo} >= 1 && ${#repo} <= 100 )) || return 3

    printf '%s' "$owner/$repo"
    return 0
}
