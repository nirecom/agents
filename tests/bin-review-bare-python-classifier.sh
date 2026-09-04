#!/usr/bin/env bash
# Tests: bin/review-bare-python
# Tags: lint, bare-python, regex, allowlist, table-driven, mutation-probe, scope:common, pwsh-not-required, TL2
#
# Table-driven classifier coverage for bin/review-bare-python (review gap C7).
# tests/fix-992-bare-python.sh drives the script end-to-end one scenario per
# hand-written block, so the two verdict-deciding regex constants — DETECT_RE
# (widens -> false HARD findings block unrelated work) and SANCTION_RE (widens
# -> real bare-interpreter calls are silently exempted) — and the
# EXCLUDED_FILES allowlist each get only a few spellings there. Both halves of
# every pair are written out below, per skills/_shared/test-design/parser-regex-tests.md.

set -uo pipefail

# SELF-EXEMPTION NOTE
# This file is deliberately NOT in the script's EXCLUDED_FILES. Every candidate
# line is written with %PY3% / %PY% tokens that are expanded only when the
# fixture file is created, so no spelling the lint looks for ever appears in
# this file's own bytes. That keeps the suite honest: adding a file to the
# allowlist to make it pass is the failure mode the allowlist rows below exist
# to detect.
AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-bare-python"

# FALSE-GREEN GUARD
# A CLEAN verdict is never inferred from "the script exited 0". Every case file
# is committed into one fixture repo, a single `--all` run produces the finding
# set, and each row is decided by whether ITS OWN path appears in that set. A
# crashed or empty run is caught by the harness self-check (section H), which
# requires a known-flagged and a known-clean row to classify correctly before
# any table below is trusted.
PASS=0
FAIL=0
SKIP=0

# TL3 gap (what this test does NOT catch):
# - The Windows App Execution Alias popup that motivated #992: observable only
#   on a Windows host where the interpreter name resolves to the Store stub.
# - A grep binary failing mid-scan (the source now reports it as an ERROR line
#   and a non-clean result): observing it needs a PATH shim, which lives in the
#   sibling suite tests/bin-review-bare-python-exemption-scope.sh, section GF.
# Closest-to-action mitigation: the Store-stub gap is checked at
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category
# `pwsh-required`; the git-failure direction IS covered here by the
# unresolvable-base and metacharacter rows in section G.

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/review-bare-python"
    echo ""
    echo "Results: 0 passed, 1 failed, 0 skipped"
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): the fixture repos must not
# inherit the developer's git hooks or global excludes, or the installed
# pre-commit hook fires inside them.
EMPTY_HOOKS="$TMP/no-hooks"; mkdir -p "$EMPTY_HOOKS"
EMPTY_EXCLUDES="$TMP/empty-excludes"; : > "$EMPTY_EXCLUDES"

make_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS"
    git -C "$repo" config core.excludesFile "$EMPTY_EXCLUDES"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" checkout -q -b main
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
}

# expand_placeholders — a table cell cannot hold the field delimiter, leading
# whitespace is trimmed by the row parser, and the interpreter names must not
# appear literally in this file (see SELF-EXEMPTION NOTE above).
#   %PIPE% -> literal shell pipe   %WS% -> four leading spaces
#   %PY3%  -> the versioned interpreter name   %PY% -> the unversioned one
expand_placeholders() {
    local s="$1"
    s="${s//%PIPE%/|}"
    s="${s//%WS%/    }"
    s="${s//%PY3%/pyth""on3}"
    s="${s//%PY%/pyth""on}"
    printf '%s' "$s"
}

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# write_case <repo> <relpath> <line> — a minimal .sh whose only interesting
# content is the candidate line under test.
write_case() {
    local repo="$1" rel="$2" line="$3"
    mkdir -p "$repo/$(dirname "$rel")"
    {
        printf '#!/bin/bash\n'
        printf '%s\n' "$line"
    } > "$repo/$rel"
}

# ===========================================================================
# Fixture repo. Every row of sections DS and X becomes one committed .sh file,
# and ONE `--all` run classifies all of them at once.
#
# The tables are shell strings iterated through process substitution rather than
# an unquoted heredoc: several cells contain `$(...)` and `$CODE` on purpose, and
# an unquoted heredoc would expand them before they ever reach a fixture file.
# ===========================================================================
REPO="$TMP/repo"
make_repo "$REPO"
git -C "$REPO" checkout -q -b feature

# SANCTION_RE exempts the matched SPAN, not the physical line: scan_file() strips
# every `uv run` spelling out of the line and re-tests the remainder, so a second,
# bare invocation sharing the line is still a finding. The four `mask-` rows say
# so for a real, a quoted, a trailing-commented and a `.`-glued spelling;
# `mask-control-alone` carries the identical bare text alone, and M2b pins the
# verdict to the stripping step rather than to DETECT_RE.
DS_TABLE='
det-versioned-dq      | HARD  | %PY3% -c "import sys"
det-unversioned-dq    | HARD  | %PY% -c "import sys"
det-versioned-sq      | HARD  | %PY3% -c '"'"'import sys'"'"'
det-leading-ws        | HARD  | %WS%%PY3% -c "x"
det-after-semicolon   | HARD  | true; %PY3% -c "x"
det-after-pipe        | HARD  | echo x %PIPE% %PY3% -c "x"
det-after-and         | HARD  | true && %PY3% -c "x"
det-after-open-paren  | HARD  | (%PY3% -c "x")
det-cmdsubst          | HARD  | out=$(%PY3% -c "x")
det-multi-space       | HARD  | %PY3%   -c   "x"
det-sudo-prefix       | HARD  | sudo %PY3% -c "x"
det-env-prefix        | HARD  | FOO=1 %PY3% -c "x"
det-comment-line      | HARD  | # %PY3% -c "x"
det-inside-dq-string  | HARD  | echo "%PY3% -c '"'"'x'"'"'"
neg-abs-path          | CLEAN | /usr/bin/%PY3% -c "x"
neg-rel-path          | CLEAN | ./%PY3% -c "x"
neg-hyphen-prefix     | CLEAN | my-%PY3% -c "x"
neg-underscore-prefix | CLEAN | MY_%PY% -c "x"
neg-alnum-prefix      | CLEAN | foo%PY3% -c "x"
neg-dot-prefix        | CLEAN | venv.%PY3% -c "x"
neg-versioned-minor   | CLEAN | %PY3%.11 -c "x"
neg-python2           | CLEAN | %PY%2 -c "x"
neg-no-space-quote    | CLEAN | %PY3% -c"x"
neg-unquoted-code     | CLEAN | %PY3% -c $CODE
neg-module-flag       | CLEAN | %PY3% -m json.tool
neg-script-arg        | CLEAN | %PY3% script.py
neg-flag-before-c     | CLEAN | %PY3% -B -c "x"
neg-pip-install       | CLEAN | pip install requests
neg-c-flag-not-first  | CLEAN | %PY3% foo.py -c "x"
san-uv-versioned      | CLEAN | uv run %PY3% -c "x"
san-uv-unversioned    | CLEAN | uv run %PY% -c "x"
san-uv-cmdsubst       | CLEAN | out=$(uv run %PY% -c "x")
san-uv-sudo           | CLEAN | sudo uv run %PY% -c "x"
san-uv-multi-space    | CLEAN | uv  run  %PY%  -c "x"
san-glued-uv-prefix   | HARD  | myuv run %PY% -c "x"
san-hyphen-uv         | HARD  | uv-run %PY% -c "x"
san-uvx-not-uv        | HARD  | uvx run %PY% -c "a"; %PY3% -c "b"
san-run-m-flag        | HARD  | uv run %PY% -m json.tool; %PY3% -c "b"
san-flag-between      | HARD  | uv run %PY3% -B -c "a"; %PY3% -c "b"
san-uv-twice          | CLEAN | uv run %PY% -c "a"; uv run %PY3% -c "b"
mask-sed-metachars    | HARD  | uv run %PY% -c "a&b\c"; %PY3% -c "d"
mask-same-line        | HARD  | uv run %PY% -c "a"; %PY3% -c "b"
mask-mention-only     | HARD  | echo "uv run %PY% -c" ; %PY3% -c "b"
mask-trailing-comment | HARD  | %PY3% -c "b"  # uv run %PY% -c
mask-dot-glued-uv     | HARD  | foo.uv run %PY% -c "a"; %PY3% -c "b"
mask-control-alone    | HARD  | %PY3% -c "b"
'

while IFS='|' read -r name want line; do
    name="$(trim "$name")"
    [ -z "$name" ] && continue
    write_case "$REPO" "probe/$name.sh" "$(expand_placeholders "$(trim "$line")")"
done < <(printf '%s\n' "$DS_TABLE")

# The EXCLUDED_FILES allowlist. Every entry gets a file carrying an unambiguous
# violation, so a CLEAN verdict can only come from the allowlist and not from
# the regex. The `xm-` near-miss paths prove the comparison is EXACT string
# equality: an allowlist matched by prefix, suffix, or basename would exempt
# them too, and each of those is a plausible "simplification" of is_excluded().
X_TABLE='
x-fix277           | CLEAN | tests/fix-277-doc-append-merge-union.sh
x-bash-c-cd-scope  | CLEAN | tests/enforce-worktree-bash-c-cd-scope.sh
x-parallel-basics  | CLEAN | tests/feature-parallel-sessions-worktree-bash-patterns/basics.sh
x-system-ops       | CLEAN | tests/feature-enforce-system-ops.sh
x-main-cleanup     | CLEAN | tests/fix-enforce-worktree-main-cleanup.sh
x-self             | CLEAN | tests/fix-992-bare-python.sh
x-round6-identity  | CLEAN | tests/enforce-protected-marker-write/cases-round6-identity.sh
x-round6-stdin     | CLEAN | tests/enforce-protected-marker-write/cases-round6-stdin.sh
x-round7-proof     | CLEAN | tests/enforce-protected-marker-write/cases-round7-proof.sh
x-round8-operand   | CLEAN | tests/enforce-protected-marker-write/cases-round8-operand.sh
x-round12-attack   | CLEAN | tests/fix-1780-round12-classifier-attack-shapes.sh
x-round12-interp   | CLEAN | tests/fix-1780-round12-parser-unit-tables/cases-interpreter.sh
x-clear-consumer   | CLEAN | tests/enforce-clearance-token-write/consumer-allow-direction-cases.sh
x-clear-interp     | CLEAN | tests/enforce-clearance-token-write/interpreter-language-scope-cases.sh
x-clear-readonly   | CLEAN | tests/enforce-clearance-token-write/read-only-allowlist-cases.sh
xm-suffix-added    | HARD  | tests/fix-992-bare-python-extra.sh
xm-prefixed-dir    | HARD  | nested/tests/fix-992-bare-python.sh
xm-sibling-name    | HARD  | tests/enforce-protected-marker-write/cases-round6-identity2.sh
xm-deeper-dir      | HARD  | tests/enforce-protected-marker-write/sub/cases-round6-identity.sh
xm-basename-only   | HARD  | fix-277-doc-append-merge-union.sh
'

while IFS='|' read -r name want path; do
    name="$(trim "$name")"
    [ -z "$name" ] && continue
    write_case "$REPO" "$(trim "$path")" "$(expand_placeholders '%PY3% -c "import sys"')"
done < <(printf '%s\n' "$X_TABLE")

git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m "probe corpus"

ALL_OUT="$TMP/all-out.txt"
ALL_RC=0
( cd "$REPO" && run_with_timeout 120 bash "$SCRIPT" --all ) > "$ALL_OUT" 2>&1 || ALL_RC=$?

# verdict_for <repo-relative-path> -> HARD | CLEAN
verdict_for() {
    if grep -qF "HARD: $1:" "$ALL_OUT"; then printf 'HARD'; else printf 'CLEAN'; fi
}

# ── harness self-check: an empty or crashed --all run would report every row as
# CLEAN. Pin both directions before trusting any table below.
assert_eq "H1 --all exits 0" "0" "$ALL_RC"
if grep -q "^## Bare Python Review: PERFORMED (all-scan mode)$" "$ALL_OUT"; then
    pass "H2 --all emitted the all-scan-mode heading"
else
    fail "H2 --all heading missing — output: $(head -5 "$ALL_OUT")"
fi
assert_eq "H3 a known violation is reported"  "HARD"  "$(verdict_for "probe/det-versioned-dq.sh")"
assert_eq "H4 a known clean file is not"      "CLEAN" "$(verdict_for "probe/neg-module-flag.sh")"

# ===========================================================================
# Section DS - DETECT_RE and SANCTION_RE, row by row.
# ===========================================================================
while IFS='|' read -r name want line; do
    name="$(trim "$name")"
    [ -z "$name" ] && continue
    want="$(trim "$want")"
    assert_eq "DS $name" "$want" "$(verdict_for "probe/$name.sh")"
done < <(printf '%s\n' "$DS_TABLE")

# The echoed match must be the ORIGINAL line: the sanction-stripped remainder is
# an internal artefact, and quoting it would point the reader at text no file has.
if grep -A1 -F "HARD: probe/mask-same-line.sh:" "$ALL_OUT" | grep -qF 'uv run'; then
    pass "DS mask-same-line quotes the original line, sanctioned span included"
else
    fail "DS mask-same-line — the echoed match lost the stripped span: $(grep -A1 -F 'HARD: probe/mask-same-line.sh:' "$ALL_OUT" | tr '\n' ' ')"
fi

# ===========================================================================
# Section X - EXCLUDED_FILES allowlist membership (exact-equality contract).
# ===========================================================================
while IFS='|' read -r name want path; do
    name="$(trim "$name")"
    [ -z "$name" ] && continue
    want="$(trim "$want")"
    assert_eq "X $name" "$want" "$(verdict_for "$(trim "$path")")"
done < <(printf '%s\n' "$X_TABLE")

# The allowlist row count is part of the contract: an entry silently dropped
# turns a fixture probe into a workflow-blocking HARD finding, and an entry
# silently added exempts a real file. Pinned against the source so the X table
# above cannot drift out of sync with EXCLUDED_FILES.
EXCL_COUNT=$(sed -n '/^EXCLUDED_FILES=(/,/^)/p' "$SCRIPT" | grep -cE '^[[:space:]]*"[^"]+"[[:space:]]*$')
assert_eq "X allowlist entry count matches the rows asserted above" "15" "$EXCL_COUNT"

# ===========================================================================
# Section G - argument handling and mode-specific exit codes. `--all` never
# blocks (exit 0 even with findings); diff mode exits 1 on any HARD. Every
# SKIPPED path must exit 0 so a lint that cannot run never blocks the workflow.
# ===========================================================================
run_script() {
    # run_script <repo> <args...> -> "<exit>|<stdout+stderr on one line>"
    local repo="$1"; shift
    local out rc=0
    out=$( ( cd "$repo" && run_with_timeout 120 bash "$SCRIPT" "$@" ) 2>&1 ) || rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

check_mode() {
    # check_mode <name> <want-exit> <want-substring> <repo> <args...>
    local name="$1" want_rc="$2" want_sub="$3" repo="$4"; shift 4
    local res rc body
    res="$(run_script "$repo" "$@")"
    rc="${res%%|*}"
    body="${res#*|}"
    if [ "$rc" != "$want_rc" ]; then
        fail "G $name — want exit $want_rc, got $rc (output: $body)"
        return
    fi
    case "$body" in
        *"$want_sub"*) pass "G $name (exit $rc, matched: $want_sub)" ;;
        *) fail "G $name — exit $rc correct but output lacks '$want_sub' (output: $body)" ;;
    esac
}

check_mode "all-mode-exits-0-with-findings"    0 "HARD:" "$REPO" --all
check_mode "diff-mode-exits-1-with-findings"   1 "HARD:" "$REPO" --base main
check_mode "base-missing-argument"             0 "--base requires an argument" "$REPO" --base
check_mode "base-and-all-mutually-exclusive"   0 "--base and --all are mutually exclusive" "$REPO" --base main --all
check_mode "unknown-flag-is-ignored"           0 "Bare Python Review" "$REPO" --frobnicate
check_mode "unresolvable-base-skips"           0 "merge-base unresolved" "$REPO" --base no/such/ref
check_mode "base-metachar-skips"               0 "merge-base unresolved" "$REPO" --base 'main; echo injected'

# A `--base` value that would be a shell injection must not EXECUTE. The word
# necessarily appears inside the diagnostic ("merge-base unresolved: main; echo
# injected"), so a substring search would be vacuous — the discriminator is
# whether a line consisting of ONLY the marker was produced, which is what an
# actually-executed `echo injected` emits.
INJ_OUT="$TMP/inj-out.txt"
( cd "$REPO" && run_with_timeout 120 bash "$SCRIPT" --base 'main; echo injected' ) > "$INJ_OUT" 2>&1
if grep -qx "injected" "$INJ_OUT"; then
    fail "G base-metachar-injection-not-executed — a bare 'injected' line was emitted"
else
    pass "G base-metachar-injection-not-executed"
fi
# ...and the diagnostic must still name the offending ref, so the guard above is
# not passing merely because the script produced no output at all.
if grep -q "merge-base unresolved: main; echo injected" "$INJ_OUT"; then
    pass "G base-metachar-reported-verbatim-in-diagnostic"
else
    fail "G base-metachar-reported-verbatim-in-diagnostic — output: $(cat "$INJ_OUT")"
fi

# ===========================================================================
# Section T - diff-mode target collection. The script unions four git sources
# (merge-base diff, staged, unstaged, untracked). Each is a separate command
# whose output can be dropped independently, so each gets its own row.
# ===========================================================================
REPO2="$TMP/repo2"
make_repo "$REPO2"
write_case "$REPO2" "src/tracked.sh" 'echo clean'
git -C "$REPO2" add -A >/dev/null 2>&1
git -C "$REPO2" commit -q -m "tracked baseline"
git -C "$REPO2" checkout -q -b feature

write_case "$REPO2" "src/committed.sh" "$(expand_placeholders '%PY3% -c "a"')"
git -C "$REPO2" add -A >/dev/null 2>&1
git -C "$REPO2" commit -q -m "committed violation"

write_case "$REPO2" "src/staged.sh" "$(expand_placeholders '%PY3% -c "b"')"
git -C "$REPO2" add "src/staged.sh" >/dev/null 2>&1

# unstaged modification of an already-tracked file
write_case "$REPO2" "src/tracked.sh" "$(expand_placeholders '%PY3% -c "c"')"
# never added to the index
write_case "$REPO2" "src/untracked.sh" "$(expand_placeholders '%PY3% -c "d"')"

DIFF_OUT="$TMP/diff-out.txt"
DIFF_RC=0
( cd "$REPO2" && run_with_timeout 120 bash "$SCRIPT" --base main ) > "$DIFF_OUT" 2>&1 || DIFF_RC=$?
assert_eq "T diff mode exits 1 when any source contributes a finding" "1" "$DIFF_RC"

while IFS='|' read -r name want path; do
    name="$(trim "$name")"
    [ -z "$name" ] && continue
    want="$(trim "$want")"
    path="$(trim "$path")"
    if grep -qF "HARD: $path:" "$DIFF_OUT"; then got=HARD; else got=CLEAN; fi
    assert_eq "T $name" "$want" "$got"
done < <(printf '%s\n' '
src-committed-on-branch  | HARD | src/committed.sh
src-staged-not-committed | HARD | src/staged.sh
src-unstaged-modified    | HARD | src/tracked.sh
src-untracked            | HARD | src/untracked.sh
')

# A .sh-only scope is what keeps this lint cheap; a non-.sh sibling carrying the
# same text must stay out of the target set in the same run.
write_case "$REPO2" "src/notshell.py" "$(expand_placeholders '%PY3% -c "e"')"
DIFF_RC=0
( cd "$REPO2" && run_with_timeout 120 bash "$SCRIPT" --base main ) > "$DIFF_OUT" 2>&1 || DIFF_RC=$?
if grep -qF "HARD: src/notshell.py:" "$DIFF_OUT"; then
    fail "T non-sh-file-out-of-scope — a .py file was scanned"
else
    pass "T non-sh-file-out-of-scope"
fi

# The scanned-count line is the only signal that the target set was non-empty;
# asserted numerically so a collapsed target list cannot pass silently.
SCANNED=$(sed -n 's/^Changed \.sh files scanned: \([0-9]*\)$/\1/p' "$DIFF_OUT" | head -1)
if [ -n "$SCANNED" ] && [ "$SCANNED" -ge 4 ] 2>/dev/null; then
    pass "T scanned-count line reports the unioned target set (count=$SCANNED)"
else
    fail "T scanned-count line — want >=4, got '$SCANNED'"
fi

# ===========================================================================
# Section M - mutation evidence. Each probe neuters ONE constant in a COPY of
# the script and asserts the rows that depend on it flip, while an unrelated row
# is unaffected. Without this, the tables above prove only that today's code
# answers as tabulated — not that they would notice the constant disappearing.
# ===========================================================================
mutant_run() {
    # mutant_run <sed-expression> -> path to the mutant's --all output
    local sedexpr="$1" mutant="$TMP/mutant-lint" out="$TMP/mutant-out.txt"
    sed "$sedexpr" "$SCRIPT" > "$mutant"
    ( cd "$REPO" && run_with_timeout 120 bash "$mutant" --all ) > "$out" 2>&1
    printf '%s' "$out"
}

# M1 - DETECT_RE neutered: no line can be a candidate any more, so the whole
# finding set must vanish.
M1_OUT="$(mutant_run "s|^DETECT_RE=.*|DETECT_RE='zzz-never-matches-detect'|")"
if grep -q "^HARD:" "$M1_OUT"; then
    fail "M1 DETECT_RE mutation — findings survived a never-match DETECT_RE"
else
    pass "M1 DETECT_RE mutation kills every finding (the constant is live)"
fi

# M2 - SANCTION_RE neutered: the sanctioned rows must become findings. This is
# the row set that ONLY SANCTION_RE explains, so it separates "the exemption
# works" from "DETECT_RE never matched those lines in the first place".
M2_OUT="$(mutant_run "s|^SANCTION_RE=.*|SANCTION_RE='zzz-never-matches-sanction'|")"
if grep -qF "HARD: probe/san-uv-versioned.sh:" "$M2_OUT"; then
    pass "M2 SANCTION_RE mutation exposes the sanctioned rows (the exemption is live)"
else
    fail "M2 SANCTION_RE mutation — sanctioned row stayed clean, so the DS table never exercised SANCTION_RE"
fi
if grep -qF "HARD: probe/neg-module-flag.sh:" "$M2_OUT"; then
    fail "M2 control — an unrelated clean row also flipped, so the mutation was too broad"
else
    pass "M2 control — an unrelated clean row is unaffected by the SANCTION_RE mutation"
fi

# M2b - span vs line. Reverting scan_file() to the pre-fix WHOLE-LINE exemption
# (drop the line entirely when SANCTION_RE matches anywhere on it) must turn every
# `mask-` row CLEAN. That is the proof their HARD verdict comes from stripping the
# sanctioned SPAN, and not from SANCTION_RE simply failing to match those lines.
M2B_OUT="$(mutant_run 's#^ *stripped=.*#  stripped=$(printf %s "$content" | grep -vE "$SANCTION_RE")#')"
for mask_row in mask-same-line mask-mention-only mask-trailing-comment mask-dot-glued-uv mask-sed-metachars; do
    if grep -qF "HARD: probe/$mask_row.sh:" "$M2B_OUT"; then
        fail "M2b $mask_row survived whole-line masking — its HARD verdict is not span-stripping"
    else
        pass "M2b $mask_row goes CLEAN under whole-line masking (span-stripping is what finds it)"
    fi
done
if grep -qF "HARD: probe/mask-control-alone.sh:" "$M2B_OUT"; then
    pass "M2b control — a line carrying no sanctioned span keeps its finding"
else
    fail "M2b control — mask-control-alone lost its finding, so the mutation was too broad"
fi
if grep -qF "HARD: probe/san-uv-versioned.sh:" "$M2B_OUT"; then
    fail "M2b control — a sanctioned row flipped, so the mutation removed the exemption itself"
else
    pass "M2b control — a sanctioned-only row stays exempt under whole-line masking"
fi

# M3 - one allowlist entry neutered: that fixture must become a finding while
# the other entries stay exempt.
M3_OUT="$(mutant_run 's|^  "tests/fix-277-doc-append-merge-union.sh"|  "tests/zzz-not-a-real-entry.sh"|')"
if grep -qF "HARD: tests/fix-277-doc-append-merge-union.sh:" "$M3_OUT"; then
    pass "M3 allowlist mutation exposes the excluded fixture (the entry is live)"
else
    fail "M3 allowlist mutation — the excluded fixture stayed clean, so the X row never exercised EXCLUDED_FILES"
fi
if grep -qF "HARD: tests/feature-enforce-system-ops.sh:" "$M3_OUT"; then
    fail "M3 control — a different allowlist entry also flipped, so the mutation was too broad"
else
    pass "M3 control — the other allowlist entries are unaffected"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
