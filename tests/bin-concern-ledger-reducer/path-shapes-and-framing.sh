# tests/bin-concern-ledger-reducer/path-shapes-and-framing.sh
# Tests: bin/lib/concern-ledger/core.sh, bin/lib/safe-plans-path.sh
# Tags: concern-ledger, pattern-discovery, windows-path, nul-framing, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh, after pattern-discovery.sh whose helpers it reuses.

echo ""
echo "--- reducer pd-4: both path shapes, on every host ---"

# pd-2's fixture takes one branch per run — cygpath decides which — so a Windows
# host never exercises the POSIX spelling and a Linux host never exercises the
# Windows one. The split those cases depend on is pure string work, so both
# shapes can be pinned everywhere by asking for the split directly.

# pd_split <pattern> → "dir=<d> base=<b>", the two halves the helper feeds find.
pd_split() {
    bash -c 'set +u; source "$0" >/dev/null 2>&1 || exit 127
             printf "dir=%s base=%s" "$(_sp_dirname "$1")" "$(_sp_basename "$1")"' \
        "$LIB" "$1" 2>/dev/null
}

while IFS='|' read -r name pattern want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"; pattern="${pattern%"${pattern##*[![:space:]]}"}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
    assert_eq_nz "pd-4: $name" "$want" "$(pd_split "$pattern")"
done <<'TABLE'
a POSIX plans dir                | /plans/root/s-f-round-2-delta-*.txt   | dir=/plans/root base=s-f-round-2-delta-*.txt
a Windows plans dir              | C:\plans\root\s-f-round-2-delta-*.txt | dir=C:\plans\root base=s-f-round-2-delta-*.txt
mixed separators on Windows      | C:\plans/root\x-*.txt                 | dir=C:\plans/root base=x-*.txt
a UNC plans dir                  | \\srv\share\x-*.txt                   | dir=\\srv\share base=x-*.txt
a backslash in a POSIX file name | /plans/a\b-*.txt                      | dir=/plans base=a\b-*.txt
a pattern with no directory      | x-*.txt                               | dir=. base=x-*.txt
TABLE

{
    # The helper has to keep using that split rather than dirname/basename(1),
    # which know only the forward slash and would hand find a whole Windows path
    # as a basename — #2088 again, one layer down.
    CORE_SRC="$AGENTS_ROOT/bin/lib/concern-ledger/core.sh"
    HELPER_BODY="$(awk '/^_cl_list_pattern_files\(\)/, /^}/' "$CORE_SRC")"
    # The marker is the find call the split feeds, spelled as it is today: the
    # '--' the probe used to look for was removed because BSD/macOS find reads
    # it as a path operand instead of an option terminator, and a precondition
    # pinned to it reports "empty" for a body that was read perfectly well.
    assert_eq_nz "pd-4: the helper body is what got read (precondition)" \
        "found" "$(case "$HELPER_BODY" in *'find "$dir"'*) printf found ;; *) printf empty ;; esac)"
    assert_eq_nz "pd-4: and it splits with the shape-aware pair, not dirname/basename(1)" \
        "sp=2 shell=0" \
        "sp=$(printf '%s\n' "$HELPER_BODY" | grep -c -E '_sp_(dir|base)name "\$pat"' | tr -d ' ') shell=$(printf '%s\n' "$HELPER_BODY" | grep -c -E '\$\((dir|base)name ' | tr -d ' ')"
}

echo ""
echo "--- reducer pd-5: a file name the NUL framing exists for ---"

# The framing is NUL-delimited so that no byte legal in a file name can split a
# record, and the only byte that tests that claim is the newline: every
# line-oriented consumer in pattern-discovery.sh would report one file as two.
# Read here with `read -d ''`, which is the contract callers are held to.

# pd_names0 <pattern> — basenames joined with ';', read as NUL records.
pd_names0() {
    bash -c 'set +u; source "$0" >/dev/null 2>&1 || exit 127; set -u
             while IFS= read -r -d "" f; do printf "%s;" "${f##*/}"; done \
                 < <(_cl_list_pattern_files "$1")' "$LIB" "$1" 2>/dev/null
}

{
    PDN="$TMPDIR_BASE/pd-newline"
    mkdir -p "$PDN"
    NL_NAME="$(printf 'two\nlines')-delta.txt"
    : > "$PDN/$NL_NAME" 2>/dev/null || true
    if [ -f "$PDN/$NL_NAME" ]; then
        : > "$PDN/a-delta.txt"
        assert_eq_nz "pd-5: a name holding a newline arrives as one record, not two" \
            "a-delta.txt;$NL_NAME;" "$(pd_names0 "$PDN/*-delta.txt")"
        assert_eq_nz "pd-5: and a line-oriented reader would have split it (the reason for the framing)" \
            "split" \
            "$([ "$(pd_names "$PDN/*-delta.txt")" = "a-delta.txt,$NL_NAME," ] \
                && printf intact || printf split)"
    else
        # SKIPPED: pd-5, this host's filesystem refuses a newline in a file
        # name, so the fixture can't be built. L3 gap: a POSIX CI host runs
        # it; the framing is still pinned by pd-3's space/backslash rows.
        echo "NOTE: pd-5: SKIPPED — this filesystem refuses a newline in a file name"
    fi
}
