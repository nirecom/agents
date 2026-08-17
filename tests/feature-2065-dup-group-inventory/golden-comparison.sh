# S12 category 1: golden comparison of the pre-extraction implementation (#2065)
# Tests: bin/lib/test-frontmatter-fix.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, audit-tests, golden, frontmatter, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh

# S1-2 claims the parser extraction is behavior-preserving. The primary proof is
# a byte-identical diff of the OLD implementation's output against the new one
# over one deterministic fixture covering buckets (a)-(j) of S1-0.

# The expected side is a fact about what the old code printed. It must never be
# rewritten to match a new implementation: a mismatch is an S1 design defect,
# not a test defect. Until S1-0 runs (it is a write-code-time step) there is no
# captured artifact, so those rows SKIP with a reason instead of false-greening.

GC_GOLDEN_DIR="${DUP_GROUPS_GOLDEN_DIR:-}"
GC_CAPTURE_DIR="$TMPDIR_BASE/golden-capture"
mkdir -p "$GC_CAPTURE_DIR"

GC_REPO="$(make_repo)"
add_src "$GC_REPO" "bin/alive1.sh"
add_src "$GC_REPO" "bin/alive2.sh"
add_src "$GC_REPO" "bin/old.sh"

# (f) needs real rename history, so commit the pre-rename state first.
commit_repo "$GC_REPO" "golden fixture base"
git -C "$GC_REPO" mv bin/old.sh bin/new.sh >/dev/null 2>&1
commit_repo "$GC_REPO" "golden fixture rename"

# (a) single alive target / (b) several alive targets
add_test_file "$GC_REPO" "feature-9001-single.sh" "bin/alive1.sh" "TL2, scope:issue-specific"
add_test_file "$GC_REPO" "feature-9002-multi.sh" "bin/alive1.sh, bin/alive2.sh" "TL2, scope:issue-specific"
# (c) malformed token spellings: annotation, glob, embedded space
add_test_file "$GC_REPO" "feature-9003-badfmt.sh" "bin/alive1.sh (note), bin/*.sh, bin/a b.sh" "TL2, scope:issue-specific"
# (d) root-like tokens — regex-valid but rejected by _is_root_like_token
add_test_file "$GC_REPO" "feature-9004-rootlike.sh" "., .., /, ./, ../" "TL2, scope:issue-specific"
# (e) missing target / (f) renamed target
add_test_file "$GC_REPO" "feature-9005-missing.sh" "bin/gone.sh" "TL2, scope:issue-specific"
add_test_file "$GC_REPO" "feature-9006-renamed.sh" "bin/old.sh" "TL2, scope:issue-specific"
# (h) whitespace-padded tokens
add_test_file "$GC_REPO" "feature-9008-pad.sh" "  bin/alive1.sh ,  bin/alive2.sh " "TL2, scope:issue-specific"
# common-scope members so audit-tests-common.sh has a non-empty report too
add_test_file "$GC_REPO" "common-alive.sh" "bin/alive2.sh"
add_test_file "$GC_REPO" "common-missing.sh" "bin/gone2.sh"

# (g) no `# Tests:` line at all
add_test_file_raw "$GC_REPO" "feature-9007-noheader.sh" <<'GC_NOHDR'
#!/usr/bin/env bash
# Tags: TL2, scope:issue-specific
echo fixture
GC_NOHDR

# (i) two `# Tests:` lines — the old code silently keeps only the first
add_test_file_raw "$GC_REPO" "common-dup-header.sh" <<'GC_DUP'
#!/usr/bin/env bash
# Tests: bin/alive1.sh
# Tags: TL2, scope:common
# Tests: bin/alive2.sh
echo fixture
GC_DUP

# (j) first `# Tests:` line at line 11 — a position-contract violation the old
# code accepts because `grep -m1` never looks at the line number. The filler is
# executable no-ops rather than comments so the block stays greppable as code.
add_test_file_raw "$GC_REPO" "common-late-header.sh" <<'GC_LATE'
#!/usr/bin/env bash
# Tags: TL2, scope:common
: filler 03
: filler 04
: filler 05
: filler 06
: filler 07
: filler 08
: filler 09
: filler 10
# Tests: bin/alive2.sh
echo fixture
GC_LATE

commit_repo "$GC_REPO" "golden fixture files"

# normalize_golden <root> — reads stdin, writes a comparison-stable form:
# absolute fixture paths to <TMP>, any ISO date to <DATE>. Both the S1-0 capture
# and this replay must apply the identical transform (detail.md codex C4 (b)).
normalize_golden() {
    sed -e "s|$(re_escape "$1")|<TMP>|g" -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/<DATE>/g'
}

# gc_capture <name> <script> [args...] — runs a command form and stores its
# normalized stdout+stderr under $GC_CAPTURE_DIR/<name>.txt.
gc_capture() {
    local name="$1"; shift
    local script="$1"; shift
    run_in_repo "$GC_REPO" "$script" "$@"
    { printf '%s\n' "$OUT"; printf '%s\n' "$ERR"; } \
        | normalize_golden "$GC_REPO" > "$GC_CAPTURE_DIR/$name.txt"
    printf '%s' "$RC" > "$GC_CAPTURE_DIR/$name.rc"
}

gc_capture g1-audit-fixheaders   "$AUDIT"        --fix-headers --dry-run
gc_capture g2-audit-json         "$AUDIT"        --dry-run --offline --format json
gc_capture g3-audit-text         "$AUDIT"        --dry-run --offline --format text
gc_capture g4-common-fixheaders  "$AUDIT_COMMON" --fix-headers --dry-run
gc_capture g5-common-json        "$AUDIT_COMMON" --dry-run --offline --format json
gc_capture g6-common-text        "$AUDIT_COMMON" --dry-run --offline --format text

for gc_name in g1-audit-fixheaders g2-audit-json g3-audit-text \
               g4-common-fixheaders g5-common-json g6-common-text; do
    if [[ -n "$GC_GOLDEN_DIR" && -f "$GC_GOLDEN_DIR/$gc_name.txt" ]]; then
        if diff -u "$GC_GOLDEN_DIR/$gc_name.txt" "$GC_CAPTURE_DIR/$gc_name.txt" > "$GC_CAPTURE_DIR/$gc_name.diff" 2>&1; then
            pass "GC[$gc_name] output is byte-identical to the S1-0 golden capture"
        else
            fail "GC[$gc_name] diverged from the S1-0 golden capture — S1 changed existing behavior: $(head -20 "$GC_CAPTURE_DIR/$gc_name.diff" | tr '\n' '|')"
        fi
    else
        skip "GC[$gc_name] no S1-0 golden capture available (set DUP_GROUPS_GOLDEN_DIR, or paste the captured literals in at write-code time); replay written to $GC_CAPTURE_DIR/$gc_name.txt"
    fi
done

# Non-golden leakage guards, runnable today and required to stay green after S1:
# the structural verdicts of S1-1 belong to --dup-groups only, so they must never
# surface on the --fix-headers report or the retire report — not even for the
# duplicate-header (i) and late-header (j) fixtures that provoke them.

GC_FIXHDR="$(cat "$GC_CAPTURE_DIR/g1-audit-fixheaders.txt" "$GC_CAPTURE_DIR/g4-common-fixheaders.txt")"
assert_eq "GC7 --fix-headers report carries no structural verdict token" \
    "0" "$(printf '%s\n' "$GC_FIXHDR" | grep -ciE 'duplicate_header|late_header' || true)"

GC_RETIRE="$(cat "$GC_CAPTURE_DIR/g3-audit-text.txt" "$GC_CAPTURE_DIR/g6-common-text.txt")"
assert_eq "GC8 retire text report carries no structural verdict token" \
    "0" "$(printf '%s\n' "$GC_RETIRE" | grep -ciE 'duplicate_header|late_header' || true)"

GC_JSON="$(cat "$GC_CAPTURE_DIR/g2-audit-json.txt" "$GC_CAPTURE_DIR/g5-common-json.txt")"
assert_eq "GC9 retire JSON diagnostics use only the two pre-existing kinds" \
    "0" "$(printf '%s\n' "$GC_JSON" | grep -o '"kind":"[a-z_]*"' | grep -cvE '"kind":"(malformed_header|no_tests_header)"' || true)"

# GC10/GC11 — the duplicate-header and late-header fixtures name a LIVE target
# under the old first-line-wins rule, so the retire pass must stay silent about
# them. A report line appearing there would mean the acceptance set moved.
assert_eq "GC10 duplicate-header fixture is not reported by the retire pass" \
    "0" "$(printf '%s\n' "$GC_RETIRE" | grep -c 'common-dup-header\.sh' || true)"
assert_eq "GC11 late-header fixture is not reported by the retire pass" \
    "0" "$(printf '%s\n' "$GC_RETIRE" | grep -c 'common-late-header\.sh' || true)"
