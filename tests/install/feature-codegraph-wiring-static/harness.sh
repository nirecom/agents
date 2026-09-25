# shellcheck shell=bash
# Tests: .env.example, install.ps1, install.sh, hooks/post-checkout, hooks/post-merge, settings.json
# Tags: codegraph, wiring, static, harness, TL2, pwsh-not-required, scope:issue-specific
# Shared assertion vocabulary for tests/feature-codegraph-wiring-static.sh.
# Every helper treats "the file this assertion is about does not exist" as a LOUD
# FAILURE: this suite is a ratchet over wiring that does not exist yet, and a
# guard that passes by vacancy is the false green it was written to prevent.

# trim <string> — strips surrounding whitespace only. Inner spaces are significant:
# the table fields carry code fragments such as: [ -d "$_repo_top/.codegraph" ]
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# first_line_of <file> <fixed-string> — 1-based line number, empty when absent.
first_line_of() { grep -nF -m1 -e "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

# assert_contains <name> <rel> <needle> — the file must exist AND carry the text.
assert_contains() {
    local name="$1" rel="$2" needle="$3" abs="$AGENTS_DIR/$2"
    if [ ! -f "$abs" ]; then
        fail "$name: $rel is absent" "the wiring it must carry ('$needle') cannot exist yet"
        return
    fi
    if grep -qF -e "$needle" "$abs"; then
        pass "$name: $rel contains '$needle'"
    else
        fail "$name: $rel lacks '$needle'"
    fi
}

# assert_absent <name> <rel> <needle> <why> — an absence claim is only meaningful
# once the file that would carry the forbidden text exists, so a missing anchor
# fails rather than passing silently.
assert_absent() {
    local name="$1" rel="$2" needle="$3" why="$4" abs="$AGENTS_DIR/$2"
    if [ ! -f "$abs" ]; then
        fail "$name: $rel is absent, so its absence-guard cannot be evaluated" "$why"
        return
    fi
    local hit
    hit="$(grep -nF -m1 -e "$needle" "$abs" 2>/dev/null || true)"
    if [ -z "$hit" ]; then
        pass "$name: $rel does not contain '$needle'"
    else
        fail "$name: $rel contains the forbidden '$needle' at $hit" "$why"
    fi
}

# assert_count <name> <rel> <needle> <want> <why> — EXACT line count, not presence.
# Presence alone cannot see a mechanical re-run that appended the same block twice;
# two sync blocks, two tools: entries or two flag assignments each behave wrongly
# while every presence assertion in this suite stays green.
assert_count() {
    local name="$1" rel="$2" needle="$3" want="$4" why="$5" abs="$AGENTS_DIR/$2"
    if [ ! -f "$abs" ]; then
        fail "$name: $rel is absent" "cannot count '$needle' — $why"
        return
    fi
    local got
    got="$(grep -cF -e "$needle" "$abs" 2>/dev/null || true)"
    got="${got:-0}"
    if [ "$want" = "$got" ]; then
        pass "$name: $rel holds exactly $want line(s) matching '$needle'"
    else
        fail "$name: $rel holds $got line(s) matching '$needle', want $want" "$why"
    fi
}

# assert_count_re <name> <rel> <ERE> <want> <why> — assert_count for anchored forms
# (an assignment line, not a mention of the name in prose).
assert_count_re() {
    local name="$1" rel="$2" re="$3" want="$4" why="$5" abs="$AGENTS_DIR/$2"
    if [ ! -f "$abs" ]; then
        fail "$name: $rel is absent" "cannot count /$re/ — $why"
        return
    fi
    local got
    got="$(grep -cE -e "$re" "$abs" 2>/dev/null || true)"
    got="${got:-0}"
    if [ "$want" = "$got" ]; then
        pass "$name: $rel holds exactly $want line(s) matching /$re/"
    else
        fail "$name: $rel holds $got line(s) matching /$re/, want $want" "$why"
    fi
}

# assert_before <name> <rel> <early> <late> <why> — line-order assertion. Both
# anchors must be found: a missing anchor means the step numbering moved and the
# order claim can no longer be evaluated, which is a failure, not a pass.
assert_before() {
    local name="$1" rel="$2" early="$3" late="$4" why="$5" abs="$AGENTS_DIR/$2"
    if [ ! -f "$abs" ]; then
        fail "$name: $rel is absent" "$why"
        return
    fi
    local e_line l_line
    e_line="$(first_line_of "$abs" "$early")"
    l_line="$(first_line_of "$abs" "$late")"
    if [ -z "$e_line" ]; then
        fail "$name: $rel has no '$early'" "$why"
    elif [ -z "$l_line" ]; then
        fail "$name: $rel has no '$late' to order '$early' against" "the anchor step vanished; re-check the step numbering"
    elif [ "$e_line" -lt "$l_line" ]; then
        pass "$name: '$early' (L$e_line) precedes '$late' (L$l_line) in $rel"
    else
        fail "$name: '$early' is at L$e_line, not before '$late' at L$l_line in $rel" "$why"
    fi
}
