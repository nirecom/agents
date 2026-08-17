# tests/bin-concern-ledger-parse-allowlist/category-columns.sh
# Tests: bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/render.sh, bin/lib/concern-ledger.sh, bin/concern-ledger
# Tags: concern-ledger, parser, allowlist, severity, category, table-driven, mutation-probe, scope:common, pwsh-not-required

# ---------------------------------------------------------------------------
# 3. Category, anchor and reference columns.
# ---------------------------------------------------------------------------
echo ""
echo "--- parse 3: category, anchor and reference column probes ---"

CIN="$TMPDIR_BASE/cols.in"
: > "$CIN"
COL_KEYS=""
COL_META=""
N=0
while IFS='~' read -r label bullet want; do
    label="$(strip "$label")"
    [ -z "$label" ] && continue
    case "$label" in \#*) continue ;; esac
    N=$((N + 1))
    printf 'c%s\t%s\n' "$N" "$(strip "$bullet")" >> "$CIN"
    COL_KEYS="${COL_KEYS:+$COL_KEYS }c$N"
    COL_META="$COL_META
c$N	$label	$(strip "$want")"
done <<'TABLE'
an empty category is rejected            ~ - [HIGH] - | a/b.sh#fn |  | text here        ~ PARTIAL recs=0 unparsed=1
a missing category column is rejected    ~ - [HIGH] - | a/b.sh#fn | text here           ~ PARTIAL recs=0 unparsed=1
an empty description is rejected         ~ - [HIGH] - | a/b.sh#fn | correctness |       ~ PARTIAL recs=0 unparsed=1
an anchor with no '#' is rejected        ~ - [HIGH] - | a/b.sh | correctness | text     ~ PARTIAL recs=0 unparsed=1
an empty anchor column is rejected       ~ - [HIGH] - |  | correctness | text           ~ PARTIAL recs=0 unparsed=1
a non-C reference is rejected            ~ - [HIGH] X1 | a/b.sh#fn | correctness | text ~ PARTIAL recs=0 unparsed=1
a lowercase c reference is rejected      ~ - [HIGH] c1 | a/b.sh#fn | correctness | text ~ PARTIAL recs=0 unparsed=1
a well-formed C reference is accepted    ~ - [HIGH] C7 | a/b.sh#fn | correctness | text ~ COMPLETE recs=1 unparsed=0
a '-' reference is accepted              ~ - [HIGH] - | a/b.sh#fn | correctness | text  ~ COMPLETE recs=1 unparsed=0
a '*' bullet marker is accepted          ~ * [HIGH] - | a/b.sh#fn | correctness | text  ~ COMPLETE recs=1 unparsed=0
an unbulleted line is accepted           ~ [HIGH] - | a/b.sh#fn | correctness | text    ~ COMPLETE recs=1 unparsed=0
TABLE
batch "$CIN"

for K in $COL_KEYS; do
    ROW="$(printf '%s' "$COL_META" | grep -m1 -- "^$K	")"
    assert_eq "3: $(printf '%s' "$ROW" | cut -f2)" \
        "$(printf '%s' "$ROW" | cut -f3)" "$(res "$K")"
done

# The declared reference must survive into the record's REF column — a
# well-formed C<N> that parses but is dropped would silently mint a new concern.
assert_eq_nz "3: an accepted C reference reaches the record's REF column" \
    "C7" "$(rec c8 1)"

# The classifier is an allowlist, so it has two directions and both are the
# contract (CPR-ORTH). Downward: a category outside the vocabulary must land on
# the declared catch-all 'other', because an unvalidated string in a controlled
# column is a category nobody can query, group or triage by. Upward: a category
# inside the vocabulary must survive byte-for-byte.

# Neither direction may move the SLOT onto another category's address: the
# category is part of the review address, so a typo that inherited 'security'
# would inherit a security finding's identity along with it.

TIN="$TMPDIR_BASE/typo.in"
: > "$TIN"
UNKNOWN_KEYS=""
UN=0
for BAD_CAT in securty secuirty saftey corectness perf notacategory; do
    UN=$((UN + 1))
    printf 'u%s\t- [HIGH] - | a/b.sh#fn | %s | the unknown-category probe\n' "$UN" "$BAD_CAT" >> "$TIN"
    UNKNOWN_KEYS="${UNKNOWN_KEYS:+$UNKNOWN_KEYS }u$UN:$BAD_CAT"
done
# The nearest sanctioned neighbours, so SLOT inheritance is measurable.
printf 'real\t- [HIGH] - | a/b.sh#fn | security | the unknown-category probe\n' >> "$TIN"
printf 'realc\t- [HIGH] - | a/b.sh#fn | correctness | the unknown-category probe\n' >> "$TIN"
printf 'other\t- [HIGH] - | a/b.sh#fn | other | the unknown-category probe\n' >> "$TIN"
batch "$TIN"

# Upward direction: the sanctioned entries are untouched. (Case 1 asserts this
# across the whole vocabulary; repeated here so the pair reads as one contract.)
assert_eq_nz "3: a sanctioned category survives the classifier unchanged" \
    "security" "$(rec real 5)"
assert_eq_nz "3: and so does the declared catch-all itself" "other" "$(rec other 5)"

# Downward direction: pinned, because the classifier currently files an
# unrecognised string verbatim instead of normalising it.
OTHER_SLOT="$(rec other 3)"
for ENTRY in $UNKNOWN_KEYS; do
    K="${ENTRY%%:*}"; BAD_CAT="${ENTRY#*:}"
    xfail_eq "3: the unknown category '$BAD_CAT' normalises to the declared catch-all" \
        "other" "$(rec "$K" 5)"
    # The SLOT half holds today and must keep holding after the fix: whatever
    # the category becomes, it must not collide with a neighbour's address.
    BAD_SLOT="$(rec "$K" 3)"
    REL="uncomputable"
    if [ -n "$BAD_SLOT" ]; then
        REL="distinct"
        [ "$BAD_SLOT" = "$(rec real 3)" ] && REL="inherited-security"
        [ "$BAD_SLOT" = "$(rec realc 3)" ] && REL="inherited-correctness"
    fi
    assert_eq "3: '$BAD_CAT' does not inherit a sanctioned category's SLOT" "distinct" "$REL"
done
assert_eq_nz "3: the catch-all's own SLOT was computable (precondition)" \
    "yes" "$([ -n "$OTHER_SLOT" ] && printf yes || printf no)"

