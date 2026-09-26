# S12 category 2: token-parsing equivalence across the two consumers (#2065)
# Tests: bin/lib/test-frontmatter-fix.sh, bin/lib/test-dup-group.sh, bin/lib/test-retire-predicate.sh, bin/audit-tests.sh
# Tags: TL2, audit-tests, dup-groups, parser, trimming, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh
# S1-2 collapses two divergent tokenizers (`csv# ` strips one leading space;
# `trp_survival_verdict` sed-trims fully) into one. The observable consequence is
# that both consumers must agree on trimming, and that format validity stays the
# COMPOSITE predicate (regex AND NOT root-like) rather than the regex alone.

TP_REPO="$(make_repo)"
add_src "$TP_REPO" "bin/tp-a.sh"
add_src "$TP_REPO" "bin/tp-b.sh"

# Same logical value, two spellings: padded around the tokens vs. canonical.
add_test_file "$TP_REPO" "feature-9101-pad.sh" "  bin/tp-a.sh ,  bin/tp-b.sh " "TL2, scope:issue-specific"
add_test_file "$TP_REPO" "feature-9102-plain.sh" "bin/tp-a.sh, bin/tp-b.sh" "TL2, scope:issue-specific"

# Root-like tokens: each is regex-valid and `[[ -e ]]`-true, so a regex-only
# classifier would call them `ok` and build a bogus group out of them.
add_test_file "$TP_REPO" "tp-root-dot.sh" "."
add_test_file "$TP_REPO" "tp-root-dotdot.sh" ".."
add_test_file "$TP_REPO" "tp-root-slash.sh" "/"
add_test_file "$TP_REPO" "tp-root-dotslash.sh" "./"
add_test_file "$TP_REPO" "tp-root-dotdotslash.sh" "../"

# Empty CSV elements in all three positions. Both tokens exist, so the ONLY
# thing separating these from feature-9102-plain.sh is the hole in the CSV.
add_test_file "$TP_REPO" "feature-9103-empty-mid.sh" "bin/tp-a.sh,,bin/tp-b.sh" "TL2, scope:issue-specific"
add_test_file "$TP_REPO" "feature-9104-empty-lead.sh" ",bin/tp-a.sh" "TL2, scope:issue-specific"
add_test_file "$TP_REPO" "feature-9105-empty-trail.sh" "bin/tp-a.sh," "TL2, scope:issue-specific"
# The splitter appends a sentinel element and drops it by POSITION. These three
# are the shapes that would break a sentinel matched by VALUE instead, or a
# splitter that only special-cased one trailing comma.
add_test_file "$TP_REPO" "feature-9106-empty-space.sh" "bin/tp-a.sh, ,bin/tp-b.sh" "TL2, scope:issue-specific"
add_test_file "$TP_REPO" "feature-9107-empty-double-trail.sh" "bin/tp-a.sh,," "TL2, scope:issue-specific"
add_test_file "$TP_REPO" "feature-9108-sentinel-literal.sh" "bin/tp-a.sh,#" "TL2, scope:issue-specific"
commit_repo "$TP_REPO" "token-parsing fixture"

run_dup "$TP_REPO" "$AUDIT"
TP_OUT="$OUT"; TP_RC="$RC"; TP_ERR="$ERR"
TP_FULLKEY="bin/tp-a.sh,bin/tp-b.sh"

assert_eq "TP1a padded and canonical spellings land in one full group" \
    "2" "$(row_count "$TP_OUT" full "$TP_FULLKEY")"
assert_eq "TP1b the padded file is a member of both axes (same line, same first token)" \
    "full,token" "$(file_group_axes "$TP_OUT" "tests/feature-9101-pad.sh")"
assert_eq "TP1c trimming produced no leading/trailing space inside the key" \
    "0" "$(axis_keys "$TP_OUT" full | grep -cE '(^ | $|, | ,)' || true)"

# The other consumer of the same parser: the padded file's tokens both resolve,
# so --fix-headers must have nothing to say about it. A half-trimmed token would
# fail the regex there and surface as FIX_A / MANUAL_REVIEW_REQUIRED.
run_in_repo "$TP_REPO" "$AUDIT" --fix-headers --dry-run
TP_FIXHDR="$OUT"
assert_eq "TP2 --fix-headers reports nothing for the padded file (same trimming)" \
    "0" "$(printf '%s\n' "$TP_FIXHDR" | grep -c 'feature-9101-pad\.sh' || true)"

# TP3 — root-like tokens must all be classified malformed_header by the new mode.
while IFS='|' read -r tp_name tp_file tp_want; do
    [[ -z "${tp_name//[[:space:]]/}" || "$tp_name" =~ ^[[:space:]]*# ]] && continue
    tp_name="${tp_name//[[:space:]]/}"
    tp_file="${tp_file//[[:space:]]/}"
    tp_want="${tp_want//[[:space:]]/}"
    assert_eq "TP3[$tp_name] verdict" "$tp_want" "$(verdict_of "$TP_OUT" "tests/$tp_file")"
    assert_eq "TP3[$tp_name] appears in no group axis" \
        "" "$(file_group_axes "$TP_OUT" "tests/$tp_file")"
done <<'TP_TABLE'
dot            | tp-root-dot.sh          | malformed_header
dotdot         | tp-root-dotdot.sh       | malformed_header
slash          | tp-root-slash.sh        | malformed_header
dotslash       | tp-root-dotslash.sh     | malformed_header
dotdotslash    | tp-root-dotdotslash.sh  | malformed_header
TP_TABLE

# TP4 — the root-like files share no first token, so nothing may group them.
assert_eq "TP4 no group key is a root-like spelling" \
    "0" "$( { axis_keys "$TP_OUT" full; axis_keys "$TP_OUT" token; } | grep -cE '^(\.|\.\.|/|\./|\.\./)$' || true)"

# TP5 — the run itself must not have died; a crash would make TP1-TP4 vacuous.
assert_eq "TP5 the run produced no shell error on stderr" \
    "0" "$(printf '%s\n' "$TP_ERR" | grep -ciE 'unbound variable|syntax error' || true)"
assert_eq "TP6 duplicates exist in this fixture so the exit code is 0" "0" "$TP_RC"

# TP7 — tfm_parse_tests_line raises TFM_EMPTY_ELEMENT for any empty CSV element
# and tdg_classify maps it to malformed_header ahead of the per-token format
# loop. The hole is a malformed value, not a shorter one, so the file must join
# no group axis — otherwise it would seed the same full key as the canonical
# spelling and hand a reviewer a group nobody can act on.
# Only `trailing-comma` and `double-trailing` fail against the pre-fix splitter
# (`IFS=',' read -a` kept mid and leading empties); the rest are companions that
# pin the priority chain and the sentinel's positional drop.
while IFS='|' read -r tp_name tp_file tp_want; do
    [[ -z "${tp_name//[[:space:]]/}" || "$tp_name" =~ ^[[:space:]]*# ]] && continue
    tp_name="${tp_name//[[:space:]]/}"
    tp_file="${tp_file//[[:space:]]/}"
    tp_want="${tp_want//[[:space:]]/}"
    assert_eq "TP7[$tp_name] verdict" "$tp_want" "$(verdict_of "$TP_OUT" "tests/$tp_file")"
    assert_eq "TP7[$tp_name] appears in no group axis" \
        "" "$(file_group_axes "$TP_OUT" "tests/$tp_file")"
done <<'TP_EMPTY_TABLE'
mid-comma      | feature-9103-empty-mid.sh    | malformed_header
leading-comma  | feature-9104-empty-lead.sh   | malformed_header
trailing-comma | feature-9105-empty-trail.sh  | malformed_header
space-only     | feature-9106-empty-space.sh  | malformed_header
double-trail   | feature-9107-empty-double-trail.sh | malformed_header
sentinel-char  | feature-9108-sentinel-literal.sh   | malformed_header
TP_EMPTY_TABLE

# TP8 — acceptance-set invariance. The structural verdict of TP7 belongs to
# --dup-groups alone: the two pre-existing consumers drop the empty element and
# keep reading the surviving tokens exactly as before, so neither may start
# reporting these files. TP8a reuses the TP2 --fix-headers capture rather than
# re-running the same command; TP8b needs the retire pass, which TP2 does not run.
# feature-9108 is deliberately outside TP8/TP9: `bin/tp-a.sh,#` carries a real
# format-invalid token besides the hole, so the pre-existing consumers are
# entitled to report it. Its claim is TP7's alone (the sentinel drops by
# position, so a literal `#` element is not mistaken for the sentinel).
assert_eq "TP8a --fix-headers reports nothing for the three empty-element forms" \
    "0" "$(printf '%s\n' "$TP_FIXHDR" | grep -cE 'feature-910[3-7]-empty-[a-z-]+\.sh' || true)"

run_in_repo "$TP_REPO" "$AUDIT" --dry-run --offline --format text
assert_eq "TP8b the retire pass reports none of the three empty-element forms" \
    "0" "$(printf '%s\n' "$OUT" "$ERR" | grep -cE 'feature-910[3-7]-empty-[a-z-]+\.sh' || true)"

# TP9 — the survival predicate's own answer, read directly rather than through a
# report line, so an acceptance-set move cannot hide behind a quiet report. All
# three spellings must land on the SAME verdict as the canonical `a.sh, b.sh`
# file, which is the definition of "the acceptance set did not move".
tp_survival() { ( . "$RETIRE_LIB" >/dev/null 2>&1; trp_survival_verdict "$TP_REPO" "tests/$1" ); }
TP_SURV_BASELINE="$(tp_survival "feature-9102-plain.sh")"
while IFS='|' read -r tp_name tp_file; do
    [[ -z "${tp_name//[[:space:]]/}" || "$tp_name" =~ ^[[:space:]]*# ]] && continue
    tp_name="${tp_name//[[:space:]]/}"
    tp_file="${tp_file//[[:space:]]/}"
    assert_eq "TP9[$tp_name] survival verdict matches the canonical spelling" \
        "$TP_SURV_BASELINE" "$(tp_survival "$tp_file")"
done <<'TP_SURV_TABLE'
mid-comma      | feature-9103-empty-mid.sh
leading-comma  | feature-9104-empty-lead.sh
trailing-comma | feature-9105-empty-trail.sh
space-only     | feature-9106-empty-space.sh
double-trail   | feature-9107-empty-double-trail.sh
TP_SURV_TABLE

# TP9d pins the baseline itself: if the canonical spelling ever stopped being
# `alive`, TP9a-c would compare two equally-wrong values and stay green.
assert_eq "TP9d the canonical spelling's survival verdict is alive" \
    "alive" "$TP_SURV_BASELINE"

grp_done "token-parsing-equivalence.sh"
