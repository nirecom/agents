#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# lang-check: ignore — FX_UNI below is an intentional non-ASCII fixture value
# (C15-1 asserts the guard reads Unicode checkout paths correctly), not narrative text.
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C15 — file/string edges: awkward cwd paths, quoting, and name lengths.

# WHY: an interpolated space/shell-char in `git -C <cwd>` turns a normal
# checkout into an unresolved one (silent over-block) or worse; length
# boundaries matter oppositely — too tight rejects real repos, too loose lets
# a crafted name through.

run_block_c15() {
    echo ""
    echo "=== C15-1: repository paths that are awkward to quote ==="

    # Each fixture is a REAL git repo at an awkward path with an owned origin, so
    # a bare create there must be a silent allow. An ask here is not "safe" — it
    # means the guard cannot read ordinary checkouts on ordinary filesystems.
    local FX_SPACE FX_META FX_PAREN FX_UNI
    FX_SPACE="$(mkfixture "with space" "git@github.com:$OWNER/agents.git")"
    FX_META="$(mkfixture 'meta$&;x' "git@github.com:$OWNER/agents.git")"
    FX_PAREN="$(mkfixture 'paren(dir)[1]' "git@github.com:$OWNER/agents.git")"
    FX_UNI="$(mkfixture 'ünï-码' "git@github.com:$OWNER/agents.git")"

    local name dir
    while IFS='|' read -r name dir; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$dir" "gh issue create --title x"
        assert_decision "C15-1 [$name] owned origin at an awkward path -> silent allow" "silent"
        # The paired foreign proof: the same path must still be READ, not merely
        # waved through. An unreadable cwd would allow this one too if the guard
        # failed open, so the ask is what shows the path was actually resolved.
        reset_env
        run_case "$dir" "gh issue create --repo $FOREIGN/r --title x"
        assert_decision "C15-1 [$name] explicit foreign target from it -> ask" "ask"
    done <<TABLE
space|$FX_SPACE
metacharacters|$FX_META
brackets and parens|$FX_PAREN
non-ascii|$FX_UNI
TABLE

    echo ""
    echo "=== C15-2: a cwd that is not a usable repository ==="

    local FX_PLAIN="$BASE/plain-dir"; mkdir -p "$FX_PLAIN"
    reset_env
    run_case "$BASE/no-such-directory-at-all" "gh issue create --title x"
    assert_decision "C15-2a a nonexistent cwd -> ask" "ask"
    reset_env
    run_case "$FX_PLAIN" "gh issue create --title x"
    assert_decision "C15-2b a cwd that is not a git repo -> ask" "ask"
    reset_env
    run_case "$FX_PLAIN" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C15-2c but an explicit owned target still resolves there" "silent"
    reset_env
    run_case "" "gh issue create --title x"
    assert_decision "C15-2d an empty cwd string -> ask" "ask"

    echo ""
    echo "=== C15-3: quoted repo selectors ==="

    # Quoting is the user's, not the value's: the guard must de-quote before it
    # compares, or every quoted owned target starts prompting.
    local want cmd
    while IFS='|' read -r name want cmd; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$cmd"
        assert_decision "C15-3 [$name]" "$want"
    done <<TABLE
double-quoted owned|silent|gh issue create --repo "$OWNER/agents" --title x
single-quoted owned|silent|gh issue create --repo '$OWNER/agents' --title x
equals + double-quoted owned|silent|gh issue create --repo="$OWNER/agents" --title x
attached short + quoted owned|silent|gh issue create -R"$OWNER/agents" --title x
double-quoted foreign|ask|gh issue create --repo "$FOREIGN/r" --title x
single-quoted foreign|ask|gh issue create --repo '$FOREIGN/r' --title x
equals + quoted foreign|ask|gh issue create --repo="$FOREIGN/r" --title x
quoted empty selector|ask|gh issue create --repo "" --title x
quoted whitespace selector|ask|gh issue create --repo " " --title x
partially quoted owned|silent|gh issue create --repo "$OWNER"/agents --title x
partially quoted foreign|ask|gh issue create --repo "$FOREIGN"/r --title x
TABLE

    echo ""
    echo "=== C15-4: owner and repo name length boundaries ==="

    # GitHub's limits are 39 characters for a login and 100 for a repository.
    # Both boundaries need the pair: the exact maximum is a REAL name that must
    # resolve, and one character more is a name that cannot exist and therefore
    # cannot be proven.
    local O1 O39 O40 R1 R100 R101
    O1="a"
    O39="$(printf 'o%.0s' $(seq 1 39))"
    O40="$(printf 'o%.0s' $(seq 1 40))"
    R1="r"
    R100="$(printf 'r%.0s' $(seq 1 100))"
    R101="$(printf 'r%.0s' $(seq 1 101))"

    # Owned side: the stub reports $OWNER as the login, so anything under $OWNER
    # is provable — which makes the repo-name boundary the only variable.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/$R1 --title x"
    assert_decision "C15-4a a one-character repo name under an owned login -> silent" "silent"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/$R100 --title x"
    assert_decision "C15-4b a 100-character repo name (the maximum) -> silent" "silent"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/$R101 --title x"
    assert_decision "C15-4c a 101-character repo name cannot exist -> ask" "ask"
    assert_probes "C15-4d an invalid name is rejected before any probe" "api repos/" 0

    # Owner side: a one-character and a 39-character login are both real logins,
    # neither of which is $OWNER, so both must ask — and for the TARGET reason.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $O1/agents --title x"
    assert_decision "C15-4e a one-character foreign login -> ask" "ask" "$O1/agents"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $O39/agents --title x"
    assert_decision "C15-4f a 39-character login (the maximum) -> ask" "ask" "$O39/agents"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $O40/agents --title x"
    assert_decision "C15-4g a 40-character login cannot exist -> ask" "ask"

    # The counterweight for C15-4e/f: the same one- and 39-character logins under
    # a login the stub DOES report must resolve silently, which is what proves
    # those asks were about ownership and not about the length itself.
    reset_env; add_env "GH_STUB_LOGIN=$O1"
    run_case "$FX_OWNED" "gh issue create --repo $O1/agents --title x"
    assert_decision "C15-4h the same one-character login, authenticated -> silent" "silent"
    reset_env; add_env "GH_STUB_LOGIN=$O39"
    run_case "$FX_OWNED" "gh issue create --repo $O39/agents --title x"
    assert_decision "C15-4i the same 39-character login, authenticated -> silent" "silent"

    # Names that are the right LENGTH but the wrong shape.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/. --title x"
    assert_decision "C15-4j a repo named '.' -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/.. --title x"
    assert_decision "C15-4k a repo named '..' -> ask" "ask"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/.config --title x"
    assert_decision "C15-4l a leading-dot repo name is legal -> silent allow" "silent"
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo -$OWNER/agents --title x"
    assert_decision "C15-4m a leading-hyphen login -> ask" "ask"
}
