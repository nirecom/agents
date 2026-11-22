#!/bin/bash
# tests/bin/fix-2168-extract-field-capture.sh
# Tests: bin/github-issues/lib/extract-field.sh, bin/github-issues/issue-to-history.sh, bin/github-issues/issue-create.sh
# Tags: github, issues, extract-field, heading-capture, parser, scope:issue-specific, layer:TL2
#
# #2168: an unknown `###`..`######` heading inside a field is BODY text and is captured;
# only `##`, another canonical heading, or a KNOWN label (canonical four + the Issue
# Forms labels of .github/ISSUE_TEMPLATE/*.yml) ends it. Rows the current implementation
# cannot satisfy are DELIBERATE fail-before-fix reds (marked per row). Implementation-time
# decision: a captured heading line stays in the value. Old rows: fix-2098-heading-boundary.sh.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# TL3 gap (what this test does NOT catch):
# - GitHub's own Issue Forms renderer (heading levels / blank lines of a real body).
# - Real `gh`: the IC rows stub gh to exit 1, so only the schema-validation verdict
#   (exit 3 or not) is observed, never an actual issue creation.
# - The deployed ~/.claude/ copy of the scripts (the in-repo paths are used).

LIB="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/extract-field.sh"
HIST="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-to-history.sh"
IC="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create.sh"
TEMPLATE_DIR="$SCRIPT_CHECKOUT_ROOT/.github/ISSUE_TEMPLATE"

TMP="$(make_tmp)"
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "cannot create a temp dir" >&2; exit 1; }
readonly TMP
trap 'rm -rf "$TMP"' EXIT
harness_isolate "$TMP/iso"
unset CLAUDE_CODE_SESSION_ID

if [ ! -f "$LIB" ] || [ ! -f "$HIST" ] || [ ! -f "$IC" ]; then
    fail "precondition missing — $LIB / $HIST / $IC"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
# shellcheck disable=SC1090
. "$LIB"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
check() {  # check <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"
    else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi
}

# Table runner: name | field | BODY (printf %b) | expected value.
run_table() {  # run_table <prefix>  (rows on stdin)
    local name field body want
    while IFS='|' read -r name field body want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(trim "$name")"; field="$(trim "$field")"; want="$(trim "$want")"
        body="$(printf '%b' "$(trim "$body")")"
        check "$1-$name" "$want" "$(BODY="$body" extract_field "$field")"
    done
}

case_begin "unknown-heading-captured" "bin/github-issues/lib/extract-field.sh"
# DELIBERATE RED until fixed: every row here is an unknown `###`+ heading that the
# current `^[ \t]*##+[ \t]+` arm terminates on. Same verdict for all four fields
# (CPR-ORTH), every level 3..6.
run_table C <<'TABLE'
bg-subheadings    | Background | ### Background\n\nalpha\n\n### Rationale\n\nbeta\n\n### Details\n\ngamma\n\n### Changes\n\nc\n | alpha ### Rationale beta ### Details gamma
chg-subheadings   | Changes    | ### Background\n\nb\n\n### Changes\n\nalpha\n\n### Details\n\nbeta\n\n## Other\n\nx\n | alpha ### Details beta
cause-subheadings | Cause      | ### Cause\n\nalpha\n\n### Details\n\nbeta\n\n### Fix\n\nf\n | alpha ### Details beta
fix-subheadings   | Fix        | ### Cause\n\nc\n\n### Fix\n\nalpha\n\n### Details\n\nbeta\n | alpha ### Details beta
bg-h4-h5-h6       | Background | ### Background\n\nalpha\n\n#### A\n\nb\n\n##### B\n\nc\n\n###### C\n\nd\n | alpha #### A b ##### B c ###### C d
chg-h4-unknown    | Changes    | ### Changes\n\nalpha\n\n#### Step 1\n\nbeta\n\n##### Step 2\n\ngamma\n | alpha #### Step 1 beta ##### Step 2 gamma
cause-h4-unknown  | Cause      | ### Cause\n\nalpha\n\n#### Step 1\n\nbeta\n\n###### Step 2\n\ngamma\n | alpha #### Step 1 beta ###### Step 2 gamma
fix-h5-unknown    | Fix        | ### Fix\n\nalpha\n\n##### Step 1\n\nbeta\n | alpha ##### Step 1 beta
# Heading is the very first line of the field (nothing before it).
bg-heading-first  | Background | ### Background\n\n### Motivation\n\nsome reason\n\n### Changes\n\nc\n | ### Motivation some reason
# `Sub-tasks` without "(optional)" is not the template label, so it is unknown.
unknown-subtasks-bare   | Background | ### Background\n\nalpha\n\n### Sub-tasks\n\nbeta\n | alpha ### Sub-tasks beta
unknown-subtasks-suffix | Background | ### Background\n\nalpha\n\n### Sub-tasks (optional) extra\n\nbeta\n | alpha ### Sub-tasks (optional) extra beta
# An H2 stays a hard boundary even after captured sub-headings (RED today only because
# of the `### Details` before it; the H2 half of the verdict holds before and after).
h2-after-subheads | Background | ### Background\n\nalpha\n\n### Details\n\nbeta\n\n## Other\n\ngamma\n | alpha ### Details beta
# #3077 observed shape: `## Changes` with several `###` sub-headings was cut at the first one.
# C1: `## Notes` between two `## Background` occurrences never leaks into the value. Pinned
# existing behavior: re-entry appends the second Background text (single-space joined).
h2-between-reentry | Background | ## Background\n\nalpha\n\n## Notes\n\nnotes-N\n\n## Background\n\nbeta\n | alpha beta
h2-changes-multi  | Changes   | ## Changes\n\n### Step 1\n\none\n\n### Step 2\n\ntwo\n\n### Step 3\n\nthree\n\n## Next\n\nx\n | ### Step 1 one ### Step 2 two ### Step 3 three
h2-changes-then-known | Changes | ## Changes\n\n### Step 1\n\none\n\n### Sub-tasks (optional)\n\n- s\n | ### Step 1 one
TABLE
case_end

case_begin "known-label-terminates" "bin/github-issues/lib/extract-field.sh"
# Green today and after: a KNOWN label ends the capture at every level and in every
# field. Matching details are an implementation-time decision (case-insensitive,
# indent <= 3, trailing blanks tolerated); pinned so a later tightening is deliberate.
run_table K <<'TABLE'
subtasks-h3       | Background | ### Background\n\nalpha\n\n### Sub-tasks (optional)\n\nbeta\n | alpha
subtasks-h4       | Background | ### Background\n\nalpha\n\n#### Sub-tasks (optional)\n\nbeta\n | alpha
subtasks-h6       | Background | ### Background\n\nalpha\n\n###### Sub-tasks (optional)\n\nbeta\n | alpha
canonical-h5      | Background | ### Background\n\nalpha\n\n##### Changes\n\nbeta\n | alpha
canonical-h6      | Cause      | ### Cause\n\nalpha\n\n###### Fix\n\nbeta\n | alpha
canonical-h3      | Background | ### Background\n\nalpha\n\n### Changes\n\nbeta\n | alpha
case-insens       | Background | ### Background\n\nalpha\n\n### SUB-TASKS (Optional)\n\nbeta\n | alpha
trailing-ws       | Background | ### Background\n\nalpha\n\n### Sub-tasks (optional)   \n\nbeta\n | alpha
indent-3          | Background | ### Background\n\nalpha\n\n   ### Sub-tasks (optional)\n\nbeta\n | alpha
# C2: 7 hashes is not an ATX heading, so it is body text even when the text is a known
# label; 6 hashes (`###### Fix`) still terminates.
h7-subtasks-body  | Background | ### Background\n\nalpha\n\n####### Sub-tasks (optional)\n\nbeta\n | alpha ####### Sub-tasks (optional) beta
h7-fix-body       | Background | ### Background\n\nalpha\n\n####### Fix\n\nbeta\n | alpha ####### Fix beta
h6-fix-terminates | Background | ### Background\n\nalpha\n\n###### Fix\n\nbeta\n | alpha
chg-ends          | Changes   | ### Changes\n\nalpha\n\n### Sub-tasks (optional)\n\n- s\n | alpha
cause-ends        | Cause      | ### Cause\n\nalpha\n\n### Sub-tasks (optional)\n\n- s\n | alpha
fix-ends          | Fix        | ### Fix\n\nalpha\n\n### Sub-tasks (optional)\n\n- s\n | alpha
# ATX closing sequence (` ###` at end of line) is stripped before the label match, so a
# known label with closing hashes still terminates; an unknown one stays body text.
closing-subtasks  | Background | ### Background\n\nalpha\n\n### Sub-tasks (optional) ###\n\nbeta\n | alpha
closing-changes   | Background | ### Background\n\nalpha\n\n### Changes ##\n\nbeta\n | alpha
closing-fix-h4    | Background | ### Background\n\nalpha\n\n#### Fix ####\n\nbeta\n | alpha
closing-unknown-body | Background | ### Background\n\nalpha\n\n### Fixes ###\n\nbeta\n | alpha ### Fixes ### beta
TABLE
case_end

case_begin "template-label-parity" "bin/github-issues/lib/extract-field.sh"
# Every textarea/input `label:` in .github/ISSUE_TEMPLATE/*.yml must end a field.
# Adding a label to a template without registering it in extract-field.sh turns the
# positive row red. The negative twin (`<label> (unregistered)`) is unknown and must
# be captured: DELIBERATE RED until fixed, pairing the two directions. Labels come
# from a grep/sed over `label:` lines (no YAML parser); `- label:` options are skipped.
LABELS="$(cat "$TEMPLATE_DIR"/*.yml | tr -d '\r' | sed -n 's/^[[:space:]][[:space:]]*label:[[:space:]]*//p' | sed -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//")"
LABEL_N=0
while IFS= read -r label; do
    [ -n "$label" ] || continue
    LABEL_N=$((LABEL_N + 1))
    target=Fix; [ "$label" = "Fix" ] && target=Cause
    pos_body="### $target"$'\n\nalpha\n\n### '"$label"$'\n\nbeta\n'
    check "P-terminates-$label" "alpha" "$(BODY="$pos_body" extract_field "$target")"
    neg_body="### $target"$'\n\nalpha\n\n### '"$label (unregistered)"$'\n\nbeta\n'
    check "P-unregistered-captured-$label" "alpha ### $label (unregistered) beta" "$(BODY="$neg_body" extract_field "$target")"
done <<<"$LABELS"
if [ "$LABEL_N" -ge 5 ]; then pass "P-labels-found ($LABEL_N labels parsed from the templates)"
else fail "P-labels-found" "only $LABEL_N labels parsed from $TEMPLATE_DIR; the grep/sed extraction is broken"; fi
case_end

dry_run_out() {  # dry_run_out <body> <category>
    DRY_RUN=1 ISSUE_BODY="$1" ISSUE_TITLE="capture probe" ISSUE_CATEGORY="${2:-FEATURE}" \
        run_with_timeout 30 bash "$HIST" 42 2>&1
}
arg_value() {  # arg_value <output> <flag> <next-flag>
    printf '%s\n' "$1" | sed -n "s/.*$2 \(.*\) $3 .*/\1/p"
}

case_begin "history-args-keep-subheadings" "bin/github-issues/issue-to-history.sh"
# DELIBERATE RED until fixed: the sub-heading used to cut --background / --changes
# short (and an emptied Changes degraded to the "(no Changes recorded)" marker).
E5_BODY=$'### Background\n\n### Motivation\n\nwhy text\n\n### Details\n\nmore text\n\n### Changes\n\n### Step 1\n\nfirst\n\n### Step 2\n\nsecond\n\n### Sub-tasks (optional)\n\n- sub-issue #1\n'
E5_OUT="$(dry_run_out "$E5_BODY" FEATURE)"
check "E5-background" "### Motivation why text ### Details more text" "$(arg_value "$E5_OUT" --background --changes)"
check "E5-changes" "### Step 1 first ### Step 2 second" "$(arg_value "$E5_OUT" --changes --commits)"
case "$E5_OUT" in
    *"no Changes recorded"*|*"no Background recorded"*) fail "E5-no-marker" "a field fell back to the unrecorded marker: $E5_OUT" ;;
    *"sub-issue #1"*) fail "E5-no-bleed" "the Sub-tasks section reached the args" ;;
    *) pass "E5-no-marker-no-bleed" ;;
esac
E6_BODY=$'### Cause\n\nroot cause\n\n### Details\n\nmore cause\n\n### Fix\n\nfix one\n\n### Verification\n\nverified by hand\n\n## Follow-up\n\nnot a field\n'
E6_OUT="$(dry_run_out "$E6_BODY" INCIDENT)"
check "E6-incident-cause" "root cause ### Details more cause" "$(arg_value "$E6_OUT" --cause --fix)"
check "E6-incident-fix" "fix one ### Verification verified by hand" "$(arg_value "$E6_OUT" --fix --commits)"
case_end

# Real history write (C1): issue-to-history.sh runs for real against an isolated
# --target under $TMP; only `gh issue view` (canned JSON) and the doc-append launcher
# (-> the in-repo bin/doc-append.py) are PATH stubs. DRY_RUN skips doc-append, so only
# this path sees a field lost between extract_field and the written entry.
norm() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
if command -v uv >/dev/null 2>&1; then PY_CMD="uv run python"; else PY_CMD="python3"; fi
HROOT="$TMP/hroot"; HSTUB="$TMP/hstub"; mkdir -p "$HROOT" "$HSTUB"
printf '#!/bin/bash\nexec %s "%s" "$@"\n' "$PY_CMD" "$(norm "$SCRIPT_CHECKOUT_ROOT/bin/doc-append.py")" >"$HSTUB/doc-append"
cat >"$HSTUB/gh" <<'STUB'
#!/bin/bash
exec node -e 'process.stdout.write(JSON.stringify({number:42,title:"capture probe",body:process.env.GH_STUB_BODY,closedAt:"2026-01-02T00:00:00Z",labels:JSON.parse(process.env.GH_STUB_LABELS)}))'
STUB
chmod +x "$HSTUB/doc-append" "$HSTUB/gh"
H_RC=0; H_TARGET=""
hist_run() {  # hist_run <body> <labels-json> <target-name>; sets H_RC, H_TARGET, output in $TMP/h.out
    H_RC=0; H_TARGET="$HROOT/$3.md"
    ( cd "$TMP" && unset DRY_RUN && export PATH="$HSTUB:$PATH" GH_STUB_BODY="$1" GH_STUB_LABELS="$2" \
        && run_with_timeout 60 bash "$HIST" 42 --target "$(norm "$H_TARGET")" --target-checkout-root "$HROOT" --no-auto-rotate ) >"$TMP/h.out" 2>&1 || H_RC=$?
}
entry_line() {  # entry_line <label> <want-full-line> <file>
    grep -qxF -- "$2" "$3" 2>/dev/null && pass "$1" || fail "$1" "missing exact line [$2] in: $(cat "$3" 2>/dev/null)"
}
entry_clean() {  # entry_clean <label> <file>: no unrecorded marker, no Sub-tasks bleed
    if grep -qE '\(no (Background|Changes|Cause|Fix) recorded\)|sub-issue #1' "$2" 2>/dev/null; then
        fail "$1" "marker or Sub-tasks bleed in: $(cat "$2")"
    else pass "$1"; fi
}

case_begin "history-entry-written-keeps-subheadings" "bin/github-issues/issue-to-history.sh"
# DELIBERATE RED until fixed: the written entry (not just the printed args) must carry
# every field in full, sub-heading and the body after it included.
hist_run "$E5_BODY" '[]' feature
check "W5-feature-write-rc" "0" "$H_RC"
entry_line "W5-background-line" "Background: ### Motivation why text ### Details more text" "$H_TARGET"
entry_line "W5-changes-line" "Changes: ### Step 1 first ### Step 2 second" "$H_TARGET"
entry_clean "W5-no-marker-no-bleed" "$H_TARGET"
hist_run "$E6_BODY" '[{"name":"type:incident"}]' incident
check "W6-incident-write-rc" "0" "$H_RC"
entry_line "W6-cause-line" "Cause: root cause ### Details more cause" "$H_TARGET"
entry_line "W6-fix-line" "Fix: fix one ### Verification verified by hand" "$H_TARGET"
entry_clean "W6-no-marker-no-bleed" "$H_TARGET"
case_end

# issue-create.sh validates Background + Changes BEFORE any gh call; exit 3 = empty field.
# gh is stubbed to record that it was reached and exit 1, so the passing path (which goes
# on to the label preflight) never touches GitHub: the verdicts observed are "exit 3 and
# gh not reached" vs "validation passed and gh reached".
STUB="$TMP/stub"; mkdir -p "$STUB"
GH_REACHED="$TMP/gh.reached"
printf '#!/bin/bash\n: >"%s"\nexit 1\n' "$(norm "$GH_REACHED")" >"$STUB/gh"; chmod +x "$STUB/gh"
IC_RC=0; IC_ERR="$TMP/ic.err"
ic_run() {  # ic_run <body>; sets IC_RC, stderr in $IC_ERR; $GH_REACHED exists iff gh ran
    IC_RC=0; rm -f "$GH_REACHED"
    ( cd "$TMP" && export PATH="$STUB:$PATH" ISSUE_CREATE_SKIP_SCHEMA=0 \
        && run_with_timeout 60 bash "$IC" --title "capture probe" --body "$1" ) >/dev/null 2>"$IC_ERR" || IC_RC=$?
}

case_begin "issue-create-schema-validation" "bin/github-issues/issue-create.sh"
# DELIBERATE RED until fixed: Background whose first content is a sub-heading was judged
# empty (exit 3 "missing canonical fields: Background"); it is a non-empty field.
ic_run $'### Background\n\n### Motivation\n\nsome reason\n\n### Changes\n\n### Step 1\n\nchange text\n'
[ "$IC_RC" -ne 3 ] && pass "IC-subheading-first-not-exit3" || fail "IC-subheading-first-not-exit3" "exit 3: $(cat "$IC_ERR")"
[ -f "$GH_REACHED" ] && pass "IC-subheading-first-reaches-gh" || fail "IC-subheading-first-reaches-gh" "rc=$IC_RC, gh stub never ran (stopped before/at validation): $(cat "$IC_ERR")"
grep -q "missing canonical fields" "$IC_ERR" && fail "IC-no-missing-msg" "$(cat "$IC_ERR")" || pass "IC-no-missing-msg"
# Controls (green today and after): a genuinely empty Background exits 3 BEFORE gh, and a
# plain well-formed body passes validation and reaches gh.
ic_run $'### Background\n\n## Other\n\nx\n\n### Changes\n\nc\n'
check "IC-truly-empty-background-exit3" "3" "$IC_RC"
[ -f "$GH_REACHED" ] && fail "IC-empty-background-no-gh" "gh stub ran despite exit 3" || pass "IC-empty-background-no-gh"
grep -q "missing canonical fields: .*Background" "$IC_ERR" && pass "IC-empty-background-missing-msg" || fail "IC-empty-background-missing-msg" "$(cat "$IC_ERR")"
ic_run $'### Background\n\nplain\n\n### Changes\n\nplain too\n'
[ "$IC_RC" -ne 3 ] && pass "IC-plain-body-not-exit3" || fail "IC-plain-body-not-exit3" "exit 3: $(cat "$IC_ERR")"
[ -f "$GH_REACHED" ] && pass "IC-plain-body-reaches-gh" || fail "IC-plain-body-reaches-gh" "rc=$IC_RC, gh stub never ran: $(cat "$IC_ERR")"
case_end

case_begin "inert-capture-and-idempotence" "bin/github-issues/lib/extract-field.sh"
# S: a captured unknown heading whose TEXT is shell metacharacters stays inert (CWE-78).
# DELIBERATE RED on the value until fixed; the no-execution row is green either way.
SEC_BODY=$'### Background\n\nalpha\n\n### $(touch PWNED-H3) `touch PWNED-H3T` & rm -rf .\n\nbeta\n'
check "S4-captured-metachar-heading-inert" 'alpha ### $(touch PWNED-H3) `touch PWNED-H3T` & rm -rf . beta' \
    "$(cd "$TMP" && BODY="$SEC_BODY" extract_field Background)"
if compgen -G "$TMP/PWNED*" >/dev/null 2>&1 || compgen -G "$SCRIPT_CHECKOUT_ROOT/PWNED*" >/dev/null 2>&1; then
    fail "S5-no-execution" "the injected payload EXECUTED"
else
    pass "S5-no-execution"
fi
# I1: same BODY twice -> same value (determinism of the capture path).
I2_BODY=$'### Background\n\nalpha\n\n### Details\n\nbeta\n\n## Other\n\ngamma\n'
I2_A="$(BODY="$I2_BODY" extract_field Background)"
I2_B="$(BODY="$I2_BODY" extract_field Background)"
check "I2-first" "alpha ### Details beta" "$I2_A"
check "I2-repeat" "$I2_A" "$I2_B"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
