# tests/bin-concern-ledger-reducer/pattern-discovery.sh
# Tests: bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh
# Tags: concern-ledger, reducer, pattern-discovery, glob-escape, backslash, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.

# #2088: `compgen -G` read a Windows-separator plans dir's backslashes as glob
# escapes and matched nothing. The fix passes the directory to `find` literally
# and pattern-matches only the basename; these cases pin that split and the
# NUL-safe sort ordering it.

echo ""
echo "--- reducer pd-1: _cl_list_pattern_files splits directory from pattern ---"

# pd_names <pattern> — the basenames _cl_list_pattern_files yields, in order,
# comma-joined. Reads the NUL stream (not `ls`) since the contract is
# NUL-delimited, so a name holding a space or backslash must survive it.
# `set -u` is enabled only after the source, exercising the caller's contract
# rather than the library's own unset-variable habits.
pd_names() {
    bash -c 'set +u; source "$0" >/dev/null 2>&1 || exit 127; set -u
             _cl_list_pattern_files "$1" | tr "\0" "\n" \
                 | while IFS= read -r f; do [ -n "$f" ] && printf "%s," "${f##*/}"; done' \
        "$LIB" "$1" 2>/dev/null
}

# pd_rc <pattern> — exit status alone, which is how a caller tells "the round is
# not staged yet" (0) from "the mechanism could not look" (3). Collapsing the two
# is the #2025 C6 defect; returning non-zero for the first would abort every
# round that is merely waiting.
pd_rc() {
    bash -c 'set +u; source "$0" >/dev/null 2>&1 || exit 127; set -uo pipefail
             _cl_list_pattern_files "$1" >/dev/null' "$LIB" "$1" 2>/dev/null
    printf '%s' "$?"
}

# pd_stderr <pattern> — what the helper says while refusing. `find`'s own
# complaint is suppressed; the helper's one-line note is what a caller reads,
# so silence on a merely-empty round and a named reason on a refusal are both
# assertable here.
pd_stderr() {
    bash -c 'set +u; source "$0" >/dev/null 2>&1 || exit 127; set -uo pipefail
             _cl_list_pattern_files "$1" >/dev/null' "$LIB" "$1" 2>&1 >/dev/null
}

{
    PD="$TMPDIR_BASE/pd"
    mkdir -p "$PD/plain/sub"
    : > "$PD/plain/b-delta.txt"
    : > "$PD/plain/a-delta.txt"
    : > "$PD/plain/c-delta.txt"
    : > "$PD/plain/notes.md"
    : > "$PD/plain/.hidden-delta.txt"
    : > "$PD/plain/sub/deep-delta.txt"
    PD_LIST="$(pd_names "$PD/plain/*-delta.txt")"

    assert_eq_nz "pd-1: matching files come back sorted, whatever order the fs lists them" \
        "a-delta.txt,b-delta.txt,c-delta.txt," "$PD_LIST"
    assert_eq "pd-1: a file the pattern does not name is not swept in" \
        "no" "$(case "$PD_LIST" in *notes.md*) printf yes ;; *) printf no ;; esac)"
    assert_eq "pd-1: the search does not descend into subdirectories" \
        "no" "$(case "$PD_LIST" in *deep-delta*) printf yes ;; *) printf no ;; esac)"
    assert_eq "pd-1: a dotfile is not matched by a pattern that does not start with a dot" \
        "no" "$(case "$PD_LIST" in *hidden-delta*) printf yes ;; *) printf no ;; esac)"
    assert_eq_nz "pd-1: but a pattern that does start with a dot still finds it" \
        ".hidden-delta.txt," "$(pd_names "$PD/plain/.*-delta.txt")"
}

{
    # A directory whose own name holds glob metacharacters. Under the compgen
    # path those were expanded as part of the pattern; as a literal `find` start
    # point they name exactly one directory.
    PDM="$TMPDIR_BASE/pd/meta[1]"
    mkdir -p "$PDM"
    : > "$PDM/x-delta.txt"
    assert_eq_nz "pd-1: a directory name containing glob metacharacters is taken literally" \
        "x-delta.txt," "$(pd_names "$PDM/*-delta.txt")"

    PDS="$TMPDIR_BASE/pd/with space"
    mkdir -p "$PDS"
    : > "$PDS/y-delta.txt"
    assert_eq_nz "pd-1: and so is a directory name containing a space" \
        "y-delta.txt," "$(pd_names "$PDS/*-delta.txt")"
}

echo ""
echo "--- reducer pd-2: the #2088 backslash directory, and the empty edges ---"

# pd_bs_dir <base> — a directory addressable through a path holding at least one
# backslash. On Windows that is the defect's real shape (cygpath -w of a genuine
# directory); elsewhere a backslash is an ordinary filename character, so one is
# put into the name. Constructible either way, so this is never a skip.
pd_bs_dir() {
    local base="$1" d
    if command -v cygpath >/dev/null 2>&1; then
        d="$base/plansdir"
        mkdir -p "$d"
        cygpath -w "$d"
    else
        d="$base/plans\\evil"
        mkdir -p "$d"
        printf '%s' "$d"
    fi
}

{
    PDB="$(pd_bs_dir "$TMPDIR_BASE/pd-bs")"
    assert_eq "pd-2: the fixture really is a backslash-bearing path (precondition)" \
        "has-backslash" \
        "$(case "$PDB" in *\\*) printf has-backslash ;; *) printf 'no-backslash:%s' "$PDB" ;; esac)"
    : > "$PDB/b-delta.txt"
    : > "$PDB/a-delta.txt"

    # The regression itself: `compgen -G "$PDB/*-delta.txt"` consumes the
    # backslashes as escapes and finds nothing.
    assert_eq_nz "pd-2: files are found through a backslash-spelled directory" \
        "a-delta.txt,b-delta.txt," "$(pd_names "$PDB/*-delta.txt")"
}

{
    # The two empties are not one case: a missing plans dir means the helper
    # could not look, an existing empty one means it looked and the round is
    # genuinely unstaged. Answering rc 0 to both is the #2025 C6 defect, so
    # the missing directory is now a refusal, stated out loud.
    ABSENT="$TMPDIR_BASE/pd/absent-dir/*.txt"
    assert_eq "pd-2: a directory that does not exist is a refusal, not an empty round" \
        "rc=3 names=" "rc=$(pd_rc "$ABSENT") names=$(pd_names "$ABSENT")"
    PD_ABSENT_ERR="$(pd_stderr "$ABSENT")"
    assert_eq "pd-2: and the refusal names the directory it could not read, and why" \
        "named=yes reason=yes" \
        "named=$(case "$PD_ABSENT_ERR" in *absent-dir*) printf yes ;; *) printf no ;; esac) reason=$(case "$PD_ABSENT_ERR" in *'not a readable directory'*) printf yes ;; *) printf no ;; esac)"

    mkdir -p "$TMPDIR_BASE/pd/empty-dir"
    EMPTY_PAT="$TMPDIR_BASE/pd/empty-dir/*.txt"
    assert_eq "pd-2: an existing directory with no match is the same non-event under set -u" \
        "rc=0 names=" "rc=$(pd_rc "$EMPTY_PAT") names=$(pd_names "$EMPTY_PAT")"
    assert_eq "pd-2: and that one stays silent, so a normal unstaged round pollutes no diagnostics" \
        "" "$(pd_stderr "$EMPTY_PAT")"
}

echo ""
echo "--- reducer pd-2b: a plans dir reached through a symlink ---"

# pd-2b. find's default -P never follows a symlink, and -mindepth 1 hides the
#        link itself, so a symlinked plans dir lists nothing at rc 0 — the
#        #2088 failure mode again. The forced trailing slash makes the OS
#        resolve the link before find walks, so both spellings of one
#        directory owe the same answer (CPR-ORTH).

PD_SYMLINKS=no
mkdir -p "$TMPDIR_BASE/pd-sym"
ln -s "$TMPDIR_BASE/pd-sym" "$TMPDIR_BASE/.pd-symlink-probe" 2>/dev/null || true
[ -h "$TMPDIR_BASE/.pd-symlink-probe" ] && PD_SYMLINKS=yes

{
    if [ "$PD_SYMLINKS" = "yes" ]; then
        PDR="$TMPDIR_BASE/pd-sym/real-plans"
        mkdir -p "$PDR"
        : > "$PDR/b-delta.txt"
        : > "$PDR/a-delta.txt"
        ln -s "$PDR" "$TMPDIR_BASE/pd-sym/linked-plans" 2>/dev/null || true
        PD_DIRECT="$(pd_names "$PDR/*-delta.txt")"
        assert_eq_nz "pd-2b: the real directory lists its files (precondition)" \
            "a-delta.txt,b-delta.txt," "$PD_DIRECT"
        assert_eq_nz "pd-2b: the same directory reached through a symlink lists the same files" \
            "$PD_DIRECT" "$(pd_names "$TMPDIR_BASE/pd-sym/linked-plans/*-delta.txt")"
        assert_eq "pd-2b: and reaching it that way is a success, not a silent empty" \
            "rc=0 empty=no" \
            "rc=$(pd_rc "$TMPDIR_BASE/pd-sym/linked-plans/*-delta.txt") empty=$([ -n "$(pd_names "$TMPDIR_BASE/pd-sym/linked-plans/*-delta.txt")" ] && printf no || printf yes)"
    else
        echo "SKIP: pd-2b: a plans dir reached through a symlink lists the same files (no symlinks here)"
        echo "SKIP: pd-2b: and reaching it that way is a success, not a silent empty (no symlinks here)"
    fi

    # The other half of the same step, and it needs no symlink: a caller who
    # already spelled the trailing slash must not get a second one bolted on,
    # since '//' is a legal but distinct path on some hosts.
    PDD="$TMPDIR_BASE/pd-slash"
    mkdir -p "$PDD"
    : > "$PDD/b-delta.txt"
    : > "$PDD/a-delta.txt"
    assert_eq_nz "pd-2b: a directory that already ends in a slash lists the same files" \
        "$(pd_names "$PDD/*-delta.txt")" "$(pd_names "$PDD//*-delta.txt")"
    assert_eq_nz "pd-2b: and that list is the files, not two empties agreeing" \
        "a-delta.txt,b-delta.txt," "$(pd_names "$PDD//*-delta.txt")"

    # Behavioural coverage above stops at hosts that have symlinks, and this one
    # may not. The step itself is pinned structurally so that removing it is
    # never a green run anywhere (Skipped-Because: no symlink support here).
    assert_eq_nz "pd-2b: the trailing-slash step that makes that work is in the source" \
        "1" "$(grep -c -F 'case "$dir" in */) ;; *) dir="$dir/" ;; esac' \
            "$AGENTS_ROOT/bin/lib/concern-ledger/core.sh" | tr -d ' ')"
}

echo ""
echo "--- reducer pd-3: _cl_sort0 orders a NUL stream ---"

# sort0 <item>... — feed items through _cl_sort0 as a NUL stream and read the
# result back comma-joined. NUL framing lets a path hold a space or backslash
# without the sort splitting it. Each item is comma-terminated as read (like
# pd_names) since `tr '\n' ','` over a `$( )` capture loses the final
# separator to trailing-newline stripping.
sort0() {
    local i
    for i in "$@"; do printf '%s\0' "$i"; done \
        | bash -c 'set +u; source "$0" >/dev/null 2>&1 || exit 127; set -uo pipefail
                   _cl_sort0 | tr "\0" "\n"' "$LIB" 2>/dev/null \
        | while IFS= read -r i; do [ -n "$i" ] && printf '%s,' "$i"; done
}

# One property per row: the input stream (space-free items, space-separated) and
# the comma-joined order it must come back in. The rows that need an item with a
# space in it follow the table, since the table's own separator cannot carry one.
while IFS='|' read -r name input want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    input="${input#"${input%%[![:space:]]*}"}"; input="${input%"${input##*[![:space:]]}"}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
    # shellcheck disable=SC2086 -- the field is a deliberate list of items.
    assert_eq_nz "pd-3: $name" "$want" "$(sort0 $input)"
done <<'TABLE'
an already-ordered stream comes back unchanged      | a b c   | a,b,c,
a reversed stream is ordered                        | c b a   | a,b,c,
a single item is its own order                      | only    | only,
duplicates are kept, not collapsed                  | b a a   | a,a,b,
# LC_ALL=C, so the order is byte order: uppercase before lowercase. A
# locale-dependent sort would re-file paths between hosts.
ordering is byte order (LC_ALL=C), not the locale   | a B     | B,a,
a digit sorts ahead of a letter, by byte            | b 1     | 1,b,
a dot sorts ahead of a digit, by byte               | 1 .x    | .x,1,
TABLE

{
    assert_eq_nz "pd-3: a name containing a space survives the NUL framing" \
        "a b,a c," "$(sort0 "a c" "a b")"
    assert_eq_nz "pd-3: and so does one containing a backslash" \
        'a\c,ab,' "$(sort0 'ab' 'a\c')"
}

{
    # The bash<4.4 guard: on an empty stream `"${a[@]}"` over a declared-but-
    # empty array is an unbound-variable error under `set -u`, which would take
    # down a round whose directory simply has nothing staged yet.
    EMPTY_RC="$(
        : | bash -c 'set +u; source "$0" >/dev/null 2>&1 || exit 127; set -uo pipefail
                     _cl_sort0 >/dev/null' "$LIB" 2>/dev/null
        printf '%s' "$?"
    )"
    EMPTY_ERR="$(
        : | bash -c 'set +u; source "$0" >/dev/null 2>&1 || exit 127; set -uo pipefail
                     _cl_sort0 >/dev/null' "$LIB" 2>&1 >/dev/null
    )"
    assert_eq "pd-3: an empty stream is a success with no output and no diagnostic" \
        "rc=0 out= err=" "rc=$EMPTY_RC out=$(sort0) err=$EMPTY_ERR"

    # Behavioural coverage of the guard stops at the host's bash: 5.x tolerates
    # the expansion. Pinned structurally too, so removing it cannot pass unseen.
    assert_eq_nz "pd-3: the empty-array guard is in the source, not just satisfied by bash 5" \
        "1" "$(grep -c -F '[ "${#a[@]}" -gt 0 ] || return 0' "$AGENTS_ROOT/bin/lib/concern-ledger/core.sh" | tr -d ' ')"
}

{
    # CPR-SSOT: discovery goes through the find-based helper. A surviving
    # `compgen -G` in the reducer is the #2088 defect still shipping.
    assert_eq_nz "pd-3: the reducer no longer expands a plans-dir pattern with compgen" \
        "0" "$(grep -c -F 'compgen -G' "$AGENTS_ROOT/bin/lib/concern-ledger/reduce.sh" | tr -d ' ')"
}

