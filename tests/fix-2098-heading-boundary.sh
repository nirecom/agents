#!/bin/bash
# tests/fix-2098-heading-boundary.sh
# Tests: bin/github-issues/lib/extract-field.sh, bin/github-issues/issue-to-history.sh
# Tags: github, issues, extract-field, heading-boundary, parser, scope:issue-specific, layer:TL2
#
# extract_field()'s section-boundary rule. Capture starts at the target field's
# heading/inline label and ends at (a) a heading for one of the other three
# canonical fields, or (b) ANY line matching `^[ \t]*##+[ \t]+`. H1 deliberately
# does NOT terminate. The F* rows pin CommonMark 4.5 fence semantics: a `## ...`
# line inside a fenced block is code, not a heading. Rows the implementation
# cannot yet satisfy are deliberate fail-before-fix reds, called out row by row.

set -u

PASS=0
FAIL=0

# TL3 gap (what this test does NOT catch):
# - GitHub's own Issue Forms renderer deciding what heading levels and blank
#   lines the submitted body actually carries; every BODY here is modelled.
# - The deployed ~/.claude/ copy of extract-field.sh (the in-repo path is sourced).
# - Real `gh` JSON and real bin/doc-append.py formatting (the E* rows use the
#   script's DRY_RUN branch, which prints the args instead of appending).
# Closest-to-action mitigation: bin/check-verification-gate.sh has no category
# covering bin/github-issues/** or .github/ISSUE_TEMPLATE/**, so no preflight ask
# fires; the residue closes at the plan's manual render check before merge.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"
SCRIPT="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMP="$(mktemp -d)"
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

if [ ! -f "$LIB" ]; then
    fail "precondition missing — $LIB"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
# shellcheck disable=SC1090
. "$LIB"

# Trim leading/trailing blanks only: `want` values carry internal single spaces
# (extract_field joins continuation lines with one space).
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# ---------------------------------------------------------------------------
# H (Normal + Edge, TL1) — one table, one logical path: "does this line end the
# capture?". Positive rows (heading text absent from the value) and negative
# rows (heading text present) share it, so a regression in either direction —
# over-terminating or under-terminating — turns a row red.
# Columns: name | field | BODY (printf %b) | expected extracted value
# ---------------------------------------------------------------------------
while IFS='|' read -r name field body want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; field="$(trim "$field")"; want="$(trim "$want")"
    body="$(printf '%b' "$(trim "$body")")"
    assert_eq "H-$name" "$want" "$(BODY="$body" extract_field "$field")"
done <<'TABLE'
# --- terminating: every ATX level 2..6, canonical or free-text ---
h2-other          | Background | ### Background\n\nalpha\n\n## Other\n\nbeta\n            | alpha
h3-other          | Background | ### Background\n\nalpha\n\n### Other\n\nbeta\n           | alpha
h4-other          | Background | ### Background\n\nalpha\n\n#### Other\n\nbeta\n          | alpha
h5-other          | Background | ### Background\n\nalpha\n\n##### Other\n\nbeta\n         | alpha
h6-other          | Background | ### Background\n\nalpha\n\n###### Other\n\nbeta\n        | alpha
freetext-parens   | Background | ### Background\n\nalpha\n\n### Sub-tasks (optional)\n\nbeta\n | alpha
freetext-amp      | Background | ### Background\n\nalpha\n\n## Notes & caveats\n\nbeta\n  | alpha
freetext-punct    | Changes    | ### Changes\n\nalpha\n\n#### Why? / How!\n\nbeta\n       | alpha
indented-h3       | Background | ### Background\n\nalpha\n\n  ### Other\n\nbeta\n         | alpha
# A TAB-indented `##` reaches column 4 and is NOT a heading. Every heading-INDENT
# row lives in the HI group below instead: its values carry verbatim tabs, which
# only the whitespace-squeezed comparison there can express.
# --- terminating: a heading for one of the other three canonical fields
# (pre-existing behaviour; pinned so the generic rule did not disturb it) ---
canonical-changes | Background | ### Background\n\nalpha\n\n### Changes\n\nbeta\n         | alpha
canonical-fix     | Cause      | ### Cause\n\nalpha\n\n### Fix\n\nbeta\n                  | alpha
canonical-h2-form | Background | ## Background\n\nalpha\n\n## Changes\n\nbeta\n           | alpha
# --- positive: the target's own heading starts capture; prose before it is not captured ---
starts-h3         | Background | intro prose\n\n### Background\n\nalpha\n                  | alpha
starts-h2         | Changes    | intro prose\n\n## Changes\n\nalpha\n                      | alpha
starts-inline     | Cause      | intro prose\n\nCause: alpha\n                            | alpha
# --- NOT terminating: H1 is the documented exception. A `# comment` line inside
# a fenced block is commoner in a field body than a real H1, and Issue Forms
# render every textarea label as `###`, so H1 is intended to stay in the value. ---
h1-after          | Background | ### Background\n\nalpha\n\n# Some Title\n\nbeta\n         | alpha # Some Title beta
h1-hash-comment   | Changes    | ### Changes\n\nalpha\n\n# rebuild the cache\n\nbeta\n     | alpha # rebuild the cache beta
# --- NOT terminating: hashes without a following space are not ATX headings ---
nospace-h2        | Background | ### Background\n\nalpha\n\n##nospace\n\nbeta\n            | alpha ##nospace beta
hashes-only-h3    | Background | ### Background\n\nalpha\n\n###\n\nbeta\n                  | alpha ### beta
hashes-only-h2    | Background | ### Background\n\nalpha\n\n##\n\nbeta\n                   | alpha ## beta
TABLE

# ---------------------------------------------------------------------------
# F (Edge — fenced code block, TL1). A `##`/`###` line INSIDE a fence is not a
# heading, so it must not end the capture: the whole snippet and the prose after
# the closing fence belong to the field. The tilde, long-backtick and last-field
# siblings exist so the rule has to be general rather than backtick-shaped.
# ---------------------------------------------------------------------------
while IFS='|' read -r name field body want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; field="$(trim "$field")"; want="$(trim "$want")"
    body="$(printf '%b' "$(trim "$body")")"
    assert_eq "F-$name" "$want" "$(BODY="$body" extract_field "$field")"
done <<'TABLE'
backtick-3   | Background | ### Background\n\nsnippet:\n\n```bash\n## section marker\necho hi\n```\n\nand the prose continues\n\n### Changes\n\nc\n | snippet: ```bash ## section marker echo hi ``` and the prose continues
tilde-3      | Background | ### Background\n\nsnippet:\n\n~~~\n## section marker\necho hi\n~~~\n\nand the prose continues\n\n### Changes\n\nc\n | snippet: ~~~ ## section marker echo hi ~~~ and the prose continues
backtick-5   | Background | ### Background\n\nsnippet:\n\n`````\n### nested fence talk\n`````\n\nand the prose continues\n\n### Changes\n\nc\n | snippet: ````` ### nested fence talk ````` and the prose continues
last-field   | Changes    | ### Background\n\nbg\n\n### Changes\n\nsee:\n\n```\n## note\n```\n | see: ``` ## note ```
inline-label | Cause      | Cause: see below\n\n```sh\n## marker\n```\n\ntail prose\n | see below ```sh ## marker ``` tail prose
# --- a fence that opens BEFORE any capture: the field heading inside it is code,
# so it must NOT start capture; only the real heading further down may. Fence
# state therefore has to be tracked from line 1, not from the first heading.
# Backtick and tilde spellings both, and both field families (CPR-ORTH). ---
pre-fence-backtick   | Background | ```\n### Background\n\ndecoy inside the fence\n```\n\n### Background\n\nreal\n | real
pre-fence-tilde      | Background | ~~~\n### Background\n\ndecoy inside the fence\n~~~\n\n### Background\n\nreal\n | real
pre-fence-inline     | Cause      | ```\nCause: decoy inside the fence\n```\n\n### Cause\n\nreal\n | real
pre-fence-h2         | Changes    | ~~~text\n## Changes\ndecoy inside the fence\n~~~\n\n## Changes\n\nreal\n | real
# The counter-probe: with NO fence around it, the same decoy heading DOES start
# capture — so the four rows above prove the fence, not a quirk of the fixture.
pre-fence-control    | Background | ### Background\n\ndecoy line\n\n### Other\n\nx\n | decoy line
# --- C5: a run of TWO never opens a fence, so the `## Other` below it is a real
# heading and still terminates. (CommonMark 4.5: an opener needs 3+.) ---
two-backtick-noopen  | Background | ### Background\n\nsnippet:\n\n``\n## Other\n\nbeta\n | snippet: ``
two-tilde-noopen     | Background | ### Background\n\nsnippet:\n\n~~\n## Other\n\nbeta\n | snippet: ~~
TABLE

# ---------------------------------------------------------------------------
# F (CommonMark fence edge cases, TL1) — the rows above pin "a fence exists";
# these pin WHICH line opens and closes one, per CommonMark 4.5. Separate loop
# only because they compare on line MEMBERSHIP: `want`/`got` are space-squeezed
# so an indented delimiter's verbatim leading spaces need no hand-counting.
# `want` is CommonMark-correct, so rows the impl cannot satisfy are deliberate REDs.
# ---------------------------------------------------------------------------
# Tabs fold to a space too: the tab-indented delimiter rows below carry a
# verbatim tab inside the captured value, and only LINE MEMBERSHIP matters here.
squeeze() { printf '%s' "$1" | tr -s ' 	' ' ' | sed 's/^ //; s/ $//'; }

while IFS='|' read -r name field body want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; field="$(trim "$field")"; want="$(trim "$want")"
    body="$(printf '%b' "$(trim "$body")")"
    assert_eq "F-$name" "$(squeeze "$want")" "$(squeeze "$(BODY="$body" extract_field "$field")")"
done <<'TABLE'
# --- closing delimiter rules ---
# A closing line may not carry an info string: the fence stays OPEN and the
# `## ...` after it is code. (RED: the impl closes on any long-enough same run.)
info-close      | Background | ### Background\n\nsnippet:\n\n```\ninside\n```not-a-close\n## still inside\n\ntail\n | snippet: ``` inside ```not-a-close ## still inside tail
# A run shorter than the opening run is content; the next full-length run closes.
short-close     | Background | ### Background\n\nsnippet:\n\n```\na\n``\nb\n```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` a `` b ``` after
# A different fence character is content, not a close.
mismatch-close  | Background | ### Background\n\nsnippet:\n\n```\na\n~~~\nb\n```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` a ~~~ b ``` after
# Closing delimiter indented 4+ does not close. (RED: the impl strips leading ws.)
close-indent-4 | Background | ### Background\n\nsnippet:\n\n```\ninside\n    ```\n## still inside\n\ntail\n | snippet: ``` inside ``` ## still inside tail
# --- opening delimiter indentation: 0-3 opens, 4+ is an indented code block ---
indent-0        | Background | ### Background\n\nsnippet:\n\n```\n## marker\n```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` ## marker ``` after
indent-1        | Background | ### Background\n\nsnippet:\n\n ```\n## marker\n```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` ## marker ``` after
indent-2        | Background | ### Background\n\nsnippet:\n\n  ```\n## marker\n```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` ## marker ``` after
indent-3        | Background | ### Background\n\nsnippet:\n\n   ```\n## marker\n```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` ## marker ``` after
# 4 spaces: no fence opens, so `## marker` is a real heading. (RED: impl opens one.)
indent-4      | Background | ### Background\n\nsnippet:\n\n    ```\n## marker\n\nafter\n | snippet: ```
# A TAB-indented OPENING delimiter is 4 columns of indent, so no fence opens and
# `## marker` under it is a real heading — the tab counterpart of indent-4.
open-indent-tab | Background | ### Background\n\nsnippet:\n\n\t```\n## marker\n\nafter\n | snippet: ```
# --- closing delimiter indentation: 0-3 columns still close (indent-0 is above) ---
close-indent-1 | Background | ### Background\n\nsnippet:\n\n```\ninside\n ```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` inside ``` after
close-indent-2 | Background | ### Background\n\nsnippet:\n\n```\ninside\n  ```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` inside ``` after
close-indent-3 | Background | ### Background\n\nsnippet:\n\n```\ninside\n   ```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` inside ``` after
# A TAB advances to column 4, so a tab-indented run does NOT close: the fence
# stays open and everything below it — `## Other` included — is code.
close-indent-tab | Background | ### Background\n\nsnippet:\n\n```\ninside\n\t```\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` inside ``` after ## Other beta
# CommonMark: a closing run at least as long as the opening run closes it, so a
# 5-run closes a 3-run fence.
close-longer-run | Background | ### Background\n\nsnippet:\n\n```\ninside\n`````\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` inside ````` after
# --- info-string content (CommonMark 4.5) ---
# A BACKTICK opener's info string may NOT contain a backtick, so this line opens
# nothing and the `## Other` heading below still ends the capture.
# (RED: can_open has no info-string validation, so the impl opens a fence here.)
open-backtick-info-tick | Background | ### Background\n\nsnippet:\n\n```js `x`\ninside\n\n## Other\n\nbeta\n | snippet: ```js `x` inside
# CPR-ORTH counterpart: a TILDE opener's info string MAY contain backticks, so
# this one DOES open a fence. The fix must not become "no backtick in any info
# string" — that blanket rule would turn this row red.
open-tilde-info-tick | Background | ### Background\n\nsnippet:\n\n~~~ `x`\n## marker\n~~~\n\nafter\n\n## Other\n\nbeta\n | snippet: ~~~ `x` ## marker ~~~ after
# --- C5: `can_close` allows WHITESPACE ONLY after the closing run, and trailing
# whitespace is whitespace: these DO close, so the `## Other` below is a real
# heading again. Spaces and tabs both (CPR-ORTH with the info-string rows above,
# which pin the other side: non-whitespace after the run does NOT close). ---
close-trailing-spaces | Background | ### Background\n\nsnippet:\n\n```\ninside\n```   \n\nafter\n\n## Other\n\nbeta\n | snippet: ``` inside ``` after
close-trailing-tabs   | Background | ### Background\n\nsnippet:\n\n```\ninside\n```\t\t\n\nafter\n\n## Other\n\nbeta\n | snippet: ``` inside ``` after
close-trailing-mixed  | Background | ### Background\n\nsnippet:\n\n~~~\ninside\n~~~ \t \n\nafter\n\n## Other\n\nbeta\n | snippet: ~~~ inside ~~~ after
TABLE

# ---------------------------------------------------------------------------
# HI (Heading indentation, CommonMark 4.2 — TL1). CPR-ORTH with the fence rows
# above: an ATX heading is recognized only at 0-3 COLUMNS of indent, by the very
# same indent_cols() rule the fence predicates already use. At 4 columns the line
# is indented-code / lazy-continuation text, i.e. field CONTENT, and terminating
# there truncates the field. Same squeezed comparison as the group above, because
# the 4-column values carry the delimiter's verbatim leading whitespace.
# ---------------------------------------------------------------------------
while IFS='|' read -r name field body want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; field="$(trim "$field")"; want="$(trim "$want")"
    body="$(printf '%b' "$(trim "$body")")"
    assert_eq "HI-$name" "$(squeeze "$want")" "$(squeeze "$(BODY="$body" extract_field "$field")")"
done <<'TABLE'
# --- 0-3 columns: still a heading, still terminates (pins the positive side, so
# --- the indent limit cannot be "fixed" by dropping heading recognition) ---
indent-0        | Background | ### Background\n\nalpha\n\n## Other\n\nbeta\n     | alpha
indent-1        | Background | ### Background\n\nalpha\n\n ## Other\n\nbeta\n    | alpha
indent-2        | Background | ### Background\n\nalpha\n\n  ## Other\n\nbeta\n   | alpha
indent-3        | Background | ### Background\n\nalpha\n\n   ## Other\n\nbeta\n  | alpha
# --- 4 columns: NOT a heading, so capture continues through it. RED until
# --- extract-field.sh's generic-boundary arm gains the `indent_cols($0) <= 3`
# --- guard the fence predicates already carry. ---
indent-4-spaces | Background | ### Background\n\nalpha\n\n    ## Other\n\nbeta\n | alpha ## Other beta
indent-tab      | Background | ### Background\n\nalpha\n\n\t## Other\n\nbeta\n   | alpha ## Other beta
indent-8-spaces | Background | ### Background\n\nalpha\n\n        ### Other\n\nbeta\n | alpha ### Other beta
# --- CPR-ORTH: the CANONICAL-field arm (the `(background|changes|cause|fix)`
# --- regex) has no indent limit either, so an over-indented `### Changes` also
# --- terminates today. RED until that arm gets the same `indent_cols` guard. ---
canonical-indent-4 | Background | ### Background\n\nalpha\n\n    ### Changes\n\nbeta\n | alpha ### Changes beta
# --- and the same arm must not START capture from an over-indented heading:
# --- here Changes is only ever mentioned inside indented code. RED, same fix. ---
canonical-start-indent-4 | Changes | ### Background\n\nalpha\n\n    ### Changes\n\nbeta\n |
TABLE

# ---------------------------------------------------------------------------
# M (Mutation probe, TL1) — bash counterpart of bin/mutation-probe.sh (which
# only handles single-line JS regex constants). Neutering the generic-heading
# boundary regex in a COPY of the lib must turn the terminating rows red; a
# harmless control edit must leave them green. Without this, an H row could be
# passing for reasons unrelated to the regex it claims to cover.
# ---------------------------------------------------------------------------
MUT_DIR="$TMP/mut"
mkdir -p "$MUT_DIR"
BOUNDARY_LINE='if ($0 ~ /^[ \t]*##+[ \t]+/) { cap = 0; next }'

if grep -qF "$BOUNDARY_LINE" "$LIB"; then
    pass "M-anchor the generic-heading boundary line is present in $LIB"
else
    fail "M-anchor — the boundary line this probe mutates is gone from $LIB; the probe below is meaningless"
fi

# kill mutant: the generic boundary can never match.
sed "s|\\^\\[ \\\\t\\]\\*##+\\[ \\\\t\\]\\+|^\\\\x01NEVERMATCH|" "$LIB" >"$MUT_DIR/kill.sh"
# control mutant: a comment line only — behaviour must be unchanged.
{ printf '# control mutant: no behavioural change\n'; cat "$LIB"; } >"$MUT_DIR/control.sh"

probe_extract() {  # probe_extract <lib> <field> <body>
    BODY="$3" run_with_timeout 30 bash -c '. "$1"; extract_field "$2"' _ "$1" "$2"
}

PROBE_BODY=$'### Background\n\nalpha\n\n### Sub-tasks (optional)\n\nbeta\n'
assert_eq "M-control the control mutant still terminates at the free-text heading" \
    "alpha" "$(probe_extract "$MUT_DIR/control.sh" Background "$PROBE_BODY")"

MUT_GOT="$(probe_extract "$MUT_DIR/kill.sh" Background "$PROBE_BODY")"
if [ "$MUT_GOT" = "alpha" ]; then
    fail "M-kill — neutering the boundary regex did NOT change the result ('$MUT_GOT'); the H rows do not actually exercise it"
else
    pass "M-kill neutering the boundary regex bleeds the next section in (got '$MUT_GOT')"
fi

# The canonical-field boundary is a SEPARATE arm and must survive the kill
# mutant — proof the two boundaries are independent, not one accidental rule.
assert_eq "M-kill-canonical the canonical-field boundary survives the kill mutant" \
    "alpha" "$(probe_extract "$MUT_DIR/kill.sh" Background \
        $'### Background\n\nalpha\n\n### Changes\n\nbeta\n')"

# ---------------------------------------------------------------------------
# E (Integration, TL2) — the same boundary through the real issue-to-history.sh
# subprocess (DRY_RUN pinned to 1 on every call, never inherited), so the rule is
# pinned end-to-end and not only at the sourced-helper level. One terminating
# case and the fence case; the fence row is the same deliberate RED as F above.
# ---------------------------------------------------------------------------
dry_run_out() {  # dry_run_out <body> <category>
    DRY_RUN=1 ISSUE_BODY="$1" ISSUE_TITLE="boundary probe" ISSUE_CATEGORY="${2:-FEATURE}" \
        run_with_timeout 30 bash "$SCRIPT" 42 2>&1
}

arg_value() {  # arg_value <output> <flag> <next-flag>
    printf '%s\n' "$1" | sed -n "s/.*$2 \(.*\) $3 .*/\1/p"
}

if [ ! -f "$SCRIPT" ]; then
    fail "precondition missing — $SCRIPT"
else
    E1_BODY=$'### Background\n\nthe docs drifted\n\n### Changes\n\nrewrote the setup guide\n\n### Sub-tasks (optional)\n\n- sub-issue #1\n'
    E1_OUT="$(dry_run_out "$E1_BODY" FEATURE)"
    case "$E1_OUT" in
        "DRY_RUN: "*) pass "E1-dry-run-path DRY_RUN=1 takes the dry-run print path" ;;
        *) fail "E1-dry-run-path — DRY_RUN=1 did not print the dry-run line: $E1_OUT" ;;
    esac
    assert_eq "E1-changes the free-text heading ends Changes at the subprocess boundary" \
        "rewrote the setup guide" "$(arg_value "$E1_OUT" --changes --commits)"
    case "$(arg_value "$E1_OUT" --changes --commits)" in
        *Sub-tasks*|*"sub-issue #1"*)
            fail "E1-no-bleed — the Sub-tasks section reached --changes" ;;
        *)  pass "E1-no-bleed" ;;
    esac

    # E2 — DELIBERATE RED (same defect as the F rows), pinned at TL2 so the fix
    # is proven at the subprocess boundary and not only in the helper.
    E2_BODY=$'### Background\n\nsnippet:\n\n```bash\n## section marker\necho hi\n```\n\nand the prose continues\n\n### Changes\n\nrewrote the setup guide\n'
    E2_OUT="$(dry_run_out "$E2_BODY" FEATURE)"
    assert_eq "E2-fence a fenced ## line does not truncate --background" \
        'snippet: ```bash ## section marker echo hi ``` and the prose continues' \
        "$(arg_value "$E2_OUT" --background --changes)"
    assert_eq "E2-fence-sibling --changes is unaffected by the fenced block above it" \
        "rewrote the setup guide" "$(arg_value "$E2_OUT" --changes --commits)"

    # E4 — DELIBERATE RED, F-info-close at the subprocess boundary. An info-string
    # line does not close the fence, so `## still inside` stays code and the real
    # `### Changes` below the genuine close opens Changes. Under the current impl
    # it closes early, --background truncates, the next ``` re-opens a fence that
    # swallows `### Changes`, and --changes degrades to the fabricated
    # "(no Changes recorded)" marker — the very fabrication #2098 removes.
    E4_BODY=$'### Background\n\nsnippet:\n\n```\ninside\n```not-a-close\n## still inside\n```\n\nand the prose continues\n\n### Changes\n\nrewrote the setup guide\n'
    E4_OUT="$(dry_run_out "$E4_BODY" FEATURE)"
    assert_eq "E4-fence-info-close an info-string line does not close the fence" \
        'snippet: ``` inside ```not-a-close ## still inside ``` and the prose continues' \
        "$(arg_value "$E4_OUT" --background --changes)"
    assert_eq "E4-fence-info-sibling --changes still reaches its own heading" \
        "rewrote the setup guide" "$(arg_value "$E4_OUT" --changes --commits)"

    # E3 — CPR-ORTH: the INCIDENT branch carries the identical rule.
    E3_BODY=$'### Cause\n\nthe login token expired\n\n### Fix\n\nrefresh the token on 401\n\n## Follow-up notes\n\nnot a field\n'
    E3_OUT="$(dry_run_out "$E3_BODY" INCIDENT)"
    assert_eq "E3-incident-cause" "the login token expired" \
        "$(arg_value "$E3_OUT" --cause --fix)"
    assert_eq "E3-incident-fix the trailing free-text heading ends Fix" \
        "refresh the token on 401" "$(arg_value "$E3_OUT" --fix --commits)"
fi

# ---------------------------------------------------------------------------
# S (Security — input injection, CWE-78) + I (Idempotency). Issue bodies are
# attacker-supplied, and a heading line is the one shape this file makes the
# parser branch on: a heading whose TEXT is shell metacharacters must still be
# an inert boundary. Both runs use $TMP as cwd so an artefact would land where
# the assertion can see it. I1 pins determinism: same BODY, same value twice.
# ---------------------------------------------------------------------------
SEC_BODY=$'### Background\n\nalpha\n\n## $(touch PWNED-CMDSUB) `touch PWNED-TICK` & rm -rf .\n\nbeta\n'
assert_eq "S1-boundary-metachars a metacharacter heading is an inert boundary" \
    "alpha" "$(cd "$TMP" && BODY="$SEC_BODY" extract_field Background)"

SEC_VALUE_BODY=$'### Background\n\n$(touch PWNED-VALUE); ## not a heading mid-value\n'
assert_eq "S2-value-metachars metacharacters in the value pass through verbatim" \
    '$(touch PWNED-VALUE); ## not a heading mid-value' \
    "$(cd "$TMP" && BODY="$SEC_VALUE_BODY" extract_field Background)"

if compgen -G "$TMP/PWNED*" >/dev/null 2>&1 || compgen -G "$AGENTS_DIR/PWNED*" >/dev/null 2>&1; then
    fail "S3-no-execution — the injected payload EXECUTED: $(ls -d "$TMP"/PWNED* "$AGENTS_DIR"/PWNED* 2>/dev/null)"
else
    pass "S3-no-execution no artefact from the injected payload exists"
fi

I1_BODY=$'### Background\n\nalpha\n\n### Sub-tasks (optional)\n\nbeta\n'
I1_FIRST="$(BODY="$I1_BODY" extract_field Background)"
I1_SECOND="$(BODY="$I1_BODY" extract_field Background)"
assert_eq "I1-first the first extraction lands on the pinned value" "alpha" "$I1_FIRST"
assert_eq "I1-repeat re-extracting the same BODY yields the same value" "$I1_FIRST" "$I1_SECOND"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
