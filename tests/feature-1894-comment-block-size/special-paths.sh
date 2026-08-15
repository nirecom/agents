#!/usr/bin/env bash
# lang-check: ignore — intentional non-ASCII filename fixture in the hostile-path table below.
# tests/feature-1894-comment-block-size/special-paths.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, paths, quoting, injection, unicode, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 5 — staged paths that are hostile to a shell.
#
# The scanner reads its file list with `git -c core.quotePath=false diff -z ...`
# and re-reads blobs with `git show ":./<path>"` precisely so that a space, a
# leading hyphen, a shell metacharacter or a non-ASCII byte in a filename stays
# data instead of becoming syntax. Every one of those choices is invisible in
# normal fixtures, so they get their own cases here: a path must be scanned
# correctly, and must never be interpreted.
#
# `git show ":./<path>"` is also what makes a leading hyphen safe — the `:./`
# prefix keeps the path from being read as an option.

spad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "s_$i=$i"; done; }
scm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

# make_special <repo> <filename> — creates and stages a 12-comment-line file.
# Returns 1 when the filesystem refuses the name (Windows rejects " | * etc.).
#
# Some names aren't rejected outright: MSYS/NTFS transparently remaps a byte
# the OS forbids (e.g. `*` -> the private-use codepoint U+F02A), so the write
# and the -f check above both succeed while the index ends up holding the
# *remapped* bytes instead of $fn. Catch that by reading the index back
# NUL-delimited (no pathspec/glob matching, so a literal `*` in $fn can't
# glob-match its way past the check) and requiring a byte-identical entry.
make_special() {
    local repo="$1" fn="$2"
    ( { spad 2; scm 12 note; } > "$repo/$fn" ) 2>/dev/null || return 1
    [ -f "$repo/$fn" ] || return 1
    git -C "$repo" add -f -- "$fn" >/dev/null 2>&1 || return 1
    local entry found=0
    while IFS= read -r -d '' entry; do
        [ "$entry" = "$fn" ] && { found=1; break; }
    done < <(git -C "$repo" ls-files -z --)
    if [ "$found" != 1 ]; then
        # The name git actually recorded differs from $fn: unstage it so the
        # leftover mismatched entry doesn't inflate the staged-file count.
        git -C "$repo" reset -q -- "$fn" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

echo ""
echo "=== SP1: hostile staged paths are scanned, never interpreted ==="
SPEC="$(new_repo specialpaths)"
SP_STAGED=""
SP_SKIPPED=""

# name | filename
while IFS='|' read -r name fn; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    fn="${fn# }"
    fn="${fn%"${fn##*[![:space:]]}"}"
    if make_special "$SPEC" "$fn"; then
        SP_STAGED="$SP_STAGED$name|$fn"$'\n'
    else
        skip "SP1/$name: filesystem rejects the name $(printf '%q' "$fn")"
        SP_SKIPPED="$SP_SKIPPED$name "
    fi
done <<'TABLE'
space           | with space.sh
leading-hyphen  | -x.sh
dollar          | dollar$var.sh
semicolon       | semi;colon.sh
ampersand       | amp&and.sh
backtick        | back`tick.sh
single-quote    | quote'single.sh
double-quote    | quote"double.sh
paren           | paren(1).sh
backslash       | back\slash.sh
non-ascii       | 日本語ノート.sh
glob-star       | star*glob.sh
TABLE

# One run over the whole hostile index: the scanner must not die, must not let
# any name reach the shell as syntax, and must report every staged file.
run_cb "$SPEC" -- --staged
cb_expect_rc "SP1/rc-matches-mode"
assert_absent "SP1/no-shell-diagnostics-on-stderr" "command not found" "$CB_ERR"
assert_absent "SP1/no-unexpected-token" "syntax error" "$CB_ERR"

while IFS='|' read -r name fn; do
    [ -z "$name" ] && continue
    assert_contains "SP1/$name-reported" "$CB_FIND: $fn" "$CB_OUT"
done <<< "$SP_STAGED"

SP_COUNT="$(printf '%s' "$SP_STAGED" | grep -c . || true)"
assert_eq "SP1/warn-count-matches-staged-count" "$SP_COUNT" "$(cb_warn_count)"

# Filenames containing a newline cannot be created on Windows; the -z/-d ''
# reader exists for exactly this case, so record the gap rather than hide it.
NLNAME="$(printf 'two\nlines.sh')"
if make_special "$SPEC" "$NLNAME"; then
    run_cb "$SPEC" -- --staged
    cb_expect_rc "SP1/newline-in-name-rc"
    assert_contains "SP1/newline-in-name-reported" "two" "$CB_OUT"
    git -C "$SPEC" rm -q -f --cached -- "$NLNAME" >/dev/null 2>&1 || true
else
    skip "SP1/newline-in-name: this filesystem cannot hold a newline in a filename (Windows) — -z reader unverified here"
fi

# ---------------------------------------------------------------------------
# S2 — a path that looks like a CLI flag must not become one
# ---------------------------------------------------------------------------
echo ""
echo "=== SP2: option-lookalike path ==="
OPTR="$(new_repo optlookalike)"

if make_special "$OPTR" "--all.sh"; then
    run_cb "$OPTR" -- --staged
    cb_expect_rc "SP2/rc-matches-mode"
    assert_eq "SP2/header-is-staged-mode" \
        "## Comment-block Size Review: PERFORMED (staged mode)" "$(cb_header)"
    assert_contains "SP2/option-lookalike-reported" "$CB_FIND: --all.sh" "$CB_OUT"
else
    skip "SP2: filesystem rejects the name --all.sh"
fi
