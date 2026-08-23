#!/bin/bash
# Tests: bin/github-issues/issue-to-history.sh, bin/github-issues/lib/extract-field.sh, bin/doc-append.py
# Tags: history, docs, github, issues, bin, scope:issue-specific, layer:TL2
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"

# Documented marker recipe (SSOT: extract-field.sh, extract_field_or_marker()).
MARKER_ERE='\(no (Background|Changes|Cause|Fix) recorded\)'

# Resolve a runnable Python BEFORE setup_ith_tmp prepends gh-mock to PATH, so
# `command -v` cannot resolve through the fixture dir. On Windows bare
# `python`/`python3` may be the Microsoft Store stub, so prefer `uv run python`
# (pattern from tests/fix-277-doc-append-merge-union.sh).
if command -v uv >/dev/null 2>&1; then
    PY_RUNNER=(uv run python)
elif command -v python3 >/dev/null 2>&1 && python3 -c "import sys" >/dev/null 2>&1; then
    PY_RUNNER=(python3)
else
    PY_RUNNER=(python)
fi
if [ ! -f "$LIB" ]; then
    echo "FAIL: precondition missing — $LIB"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi
source "$LIB"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# TL3 gap (what this test does NOT catch):
# - GitHub's hosted form rendering an empty title/body, and GitHub refusing an
#   untouched required field — both are server-side only.
# - `gh` is tests/fixtures/gh-mock/gh, so no real issue JSON, label payload or
#   auth path runs; a real gh contract change stays invisible here.
# - setup_ith_tmp prepends that fixture dir to PATH, so `doc-append` resolves to
#   the stub, not bin/doc-append.py — real formatting is pinned by DA1/DA2 only.
# Closest-to-action mitigation: bin/check-verification-gate.sh has no category
# for these paths (pwsh-required, hook-registration, skill-orchestration,
# installer, merge-base-suspect); closed by the plan's S10 manual render check.

assert_eq() {
    local field="$1"; local body="$2"; local expected="$3"; local label="$4"
    local got; got="$(BODY="$body" extract_field "$field")"
    if [ "$got" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$got')"; fi
}

# S1: inline label
assert_eq Background $'Background: foo bar\nChanges: baz' "foo bar" "S1 inline label"
# S2: H2 header
assert_eq Background $'## Background\n\nfoo bar\n\n## Changes\n\nbaz' "foo bar" "S2 H2 header"
# S3: H3 header multiline
assert_eq Background $'### Background\n\nfoo\nbar\n\n### Changes\n\nbaz' "foo bar" "S3 H3 multiline"
# S4: lowercase inline
assert_eq Background $'background: lower' "lower" "S4 lowercase inline"
# S5: lowercase H2
assert_eq Background $'## background\nfoo' "foo" "S5 lowercase H2"
# S6: wrong field name
assert_eq Background $'Changes: only-changes' "" "S6 wrong field"
# S7: changes field with sub-heading before it
assert_eq Changes $'## Background\nfirst\n## Sub\nirrelevant\n## Changes\nbaz' "baz" "S7 changes with sub-heading"
# S8: inline Cause
assert_eq Cause $'Cause: x\nFix: y' "x" "S8 cause inline"
# S9: H2 Fix
assert_eq Fix $'## Cause\n\nx\n\n## Fix\n\ny' "y" "S9 fix H2"

# === issue-to-history.sh: --history-notes-file / --non-github-mode shapes ===

SCRIPT="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout "$1" "${@:2}"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi
}

# Config-dependent branch, pinned per invocation (test-design.md "Config-dependent
# branches"): issue-to-history.sh switches on DRY_RUN, and every H/P/NG/Sidecar
# case below needs the REAL append arm. An inherited DRY_RUN=1 would silently
# reroute them to the print arm, so each of those runs sets `DRY_RUN=` explicitly
# instead of trusting the ambient value — and, because "empty output" and "print
# arm" are indistinguishable from a grep alone, assert_appended re-checks that
# docs/history.md itself actually changed. NG4/NG5 keep DRY_RUN=1 on purpose:
# they assert the argument vector, not the file.
HIST_BEFORE=""
assert_appended() {  # assert_appended <label>
    local after; after="$(cksum <"$ITH_TMP/docs/history.md" 2>/dev/null)"
    if [ "$after" != "$HIST_BEFORE" ]; then
        pass "$1: the real append path ran — docs/history.md changed"
    else
        fail "$1: docs/history.md unchanged ($after) — nothing was appended (DRY_RUN leak?)"
    fi
}

setup_ith_tmp() {
    ITH_TMP=$(mktemp -d)
    mkdir -p "$ITH_TMP/docs/history"
    touch "$ITH_TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$ITH_TMP"
    export PATH="$MOCK_DIR:$PATH"
    HIST_BEFORE="$(cksum <"$ITH_TMP/docs/history.md" 2>/dev/null)"
}

teardown_ith_tmp() {
    [ -n "${ITH_TMP:-}" ] && rm -rf "$ITH_TMP"
    unset AGENTS_CONFIG_DIR ITH_TMP
}

if [ -f "$SCRIPT" ]; then

# H1: --history-notes-file with ## History Notes section → "item A" in Changes:
setup_ith_tmp
NOTES_FILE=$(mktemp)
printf '## History Notes\n- item A\n- item B\n' > "$NOTES_FILE"
out=$(DRY_RUN= GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$SCRIPT" 42 --commit abc1234 \
    --history-notes-file "$NOTES_FILE" 2>/dev/null)
rc=$?
if { [ "$rc" -eq 0 ] && echo "$out" | grep -qE "item A|item B"; } || \
   grep -qE "item A|item B" "$ITH_TMP/docs/history.md" 2>/dev/null; then
    pass "H1: --history-notes-file merges History Notes bullets into history entry"
else
    if grep -qE "item A|item B" "$ITH_TMP/docs/history.md" 2>/dev/null; then
        pass "H1: --history-notes-file merges History Notes bullets into history entry"
    else
        fail "H1: rc=$rc, history.md=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null | head -20)"
    fi
fi
assert_appended "H1a"
rm -f "$NOTES_FILE"
teardown_ith_tmp

# H2: --history-notes-file with only "- (none)" → no history notes appended
setup_ith_tmp
NOTES_FILE=$(mktemp)
printf '## History Notes\n- (none)\n' > "$NOTES_FILE"
out=$(DRY_RUN= GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$SCRIPT" 42 --commit abc1234 \
    --history-notes-file "$NOTES_FILE" 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
if [ "$rc" -eq 0 ] && ! echo "$history_content" | grep -qi "History Notes:"; then
    pass "H2: --history-notes-file with only '- (none)' → History Notes: not appended"
else
    fail "H2: rc=$rc, unexpected History Notes: in output"
fi
# H2 asserts an ABSENCE, so it would also pass if nothing had been appended at
# all; this pins that the entry itself was really written (and P1 below reads it).
assert_appended "H2a"
# P1 (classifier counterpart, CPR-ORTH): every other subprocess case here pins
# the marker verdict. P1 pins the other one — a fully populated task issue must
# reach history.md with its own values, byte-exact, and with no marker at all.
# Rides on H2's already-completed run (its `- (none)` notes add no suffix), so
# it costs no extra subprocess. gh-mock's issue_task body is
# "Background: test\nChanges: did stuff"; grep -x pins the whole line so a
# borrowed-and-appended value could not satisfy it.
p1_markers=$(printf '%s\n' "$history_content" | grep -cE "$MARKER_ERE")
if printf '%s\n' "$history_content" | grep -qx "Background: test" \
    && printf '%s\n' "$history_content" | grep -qx "Changes: did stuff"; then
    pass "P1: populated task issue → both fields reach history.md verbatim"
else
    fail "P1: history.md='$history_content'"
fi
if [ "$p1_markers" -eq 0 ]; then
    pass "P1b: no marker appears anywhere in a populated task entry"
else
    fail "P1b: expected 0 marker lines in a populated entry, got $p1_markers"
fi
rm -f "$NOTES_FILE"
teardown_ith_tmp

# P2: CPR-ORTH counterpart of P1 on the INCIDENT branch. Needs its own
# subprocess — no existing arm drives issue-to-history.sh with a populated
# incident, and the Cause/Fix assembly is a separate code path from P1's.
setup_ith_tmp
out=$(DRY_RUN= GH_MOCK_SCENARIO=issue_incident run_with_timeout 30 bash "$SCRIPT" 42 \
    --commit abc1234 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
p2_markers=$(printf '%s\n' "$history_content" | grep -cE "$MARKER_ERE")
if [ "$rc" -eq 0 ] && printf '%s\n' "$history_content" | grep -q "INCIDENT" \
    && printf '%s\n' "$history_content" | grep -qx "Cause: bug" \
    && printf '%s\n' "$history_content" | grep -qx "Fix: patched"; then
    pass "P2: populated incident issue → both fields reach history.md verbatim"
else
    fail "P2: rc=$rc, history.md='$history_content'"
fi
if [ "$p2_markers" -eq 0 ]; then
    pass "P2b: no marker appears anywhere in a populated incident entry"
else
    fail "P2b: expected 0 marker lines in a populated entry, got $p2_markers"
fi
assert_appended "P2c"
teardown_ith_tmp

# NG1: --non-github-mode → doc-append without gh issue view
setup_ith_tmp
BODY_FILE=$(mktemp)
printf '## Background / Motivation\nSome background text\n\n## Changes\nSome changes\n' > "$BODY_FILE"
out=$(DRY_RUN= run_with_timeout 15 bash "$SCRIPT" 999 --commit abc1234 \
    --non-github-mode --title "Non-GitHub Test" --body-file "$BODY_FILE" \
    --closed-date "2026-01-01" 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
if [ "$rc" -eq 0 ] && echo "$history_content" | grep -q "Non-GitHub Test"; then
    pass "NG1: --non-github-mode creates history entry without gh issue view"
else
    fail "NG1: rc=$rc, history.md='$history_content'"
fi
# `## Background / Motivation` is a suffixed heading extract_field does not
# recognize, so Background is unextractable here: it must become the marker,
# never the issue title. This is the primary regression cover for #2098's
# title-borrowing fallback.
if echo "$history_content" | grep -qF "Background: (no Background recorded)"; then
    pass "NG1b: unextractable Background reaches history.md as the marker"
else
    fail "NG1b: expected 'Background: (no Background recorded)' in history.md='$history_content'"
fi
if echo "$history_content" | grep -qF "Background: Non-GitHub Test"; then
    fail "NG1c: issue title was borrowed into Background — fabricating fallback is back"
else
    pass "NG1c: issue title is never borrowed into Background"
fi
assert_appended "NG1d"
rm -f "$BODY_FILE"
teardown_ith_tmp

# NG2: FEATURE with Changes missing → only Changes becomes a marker
setup_ith_tmp
BODY_FILE=$(mktemp)
printf '## Background\nreal-bg-text\n' > "$BODY_FILE"
out=$(DRY_RUN= run_with_timeout 15 bash "$SCRIPT" 998 --commit abc1234 \
    --non-github-mode --title "NG2 changes missing" --body-file "$BODY_FILE" \
    --closed-date "2026-01-01" 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
if [ "$rc" -eq 0 ] && echo "$history_content" | grep -qF "Background: real-bg-text" \
    && echo "$history_content" | grep -qF "Changes: (no Changes recorded)"; then
    pass "NG2: extracted Background survives while missing Changes becomes the marker"
else
    fail "NG2: rc=$rc, history.md='$history_content'"
fi
assert_appended "NG2b"
rm -f "$BODY_FILE"
teardown_ith_tmp

# NG3: INCIDENT with both Cause and Fix missing, via gh-mock → real history.md
# Note: setup_ith_tmp prepends tests/fixtures/gh-mock to PATH, so the file is
# written by the `doc-append` STUB there, not by bin/doc-append.py. What is
# pinned here is the grep recipe against the stub's formatting; the matching
# guarantee for bin/doc-append.py itself is DA1/DA2 below.
setup_ith_tmp
out=$(DRY_RUN= GH_MOCK_SCENARIO=issue_incident_no_fields run_with_timeout 30 bash "$SCRIPT" 42 \
    --commit abc1234 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
marker_count=$(printf '%s\n' "$history_content" | grep -cE "$MARKER_ERE")
if [ "$rc" -eq 0 ] && echo "$history_content" | grep -q "INCIDENT" \
    && echo "$history_content" | grep -qF "Cause: (no Cause recorded)" \
    && echo "$history_content" | grep -qF "Fix: (no Fix recorded)"; then
    pass "NG3: INCIDENT with no Cause/Fix → both markers reach the real history.md"
else
    fail "NG3: rc=$rc, history.md='$history_content'"
fi
if echo "$history_content" | grep -qF "Cause: Outage no fields"; then
    fail "NG3b: issue title was borrowed into Cause — fabricating fallback is back"
else
    pass "NG3b: issue title is never borrowed into Cause"
fi
if [ "$marker_count" -eq 2 ]; then
    pass "NG3c: documented grep ERE finds exactly the 2 markers written"
else
    fail "NG3c: expected 2 marker lines, got $marker_count"
fi
assert_appended "NG3d"
teardown_ith_tmp

# NG4: FEATURE, both fields missing — argument-vector check (DRY_RUN, no I/O)
out=$(DRY_RUN=1 ISSUE_CATEGORY=FEATURE ISSUE_NUMBER=0 ISSUE_TITLE="dry-title" \
    ISSUE_BODY="prose only" run_with_timeout 15 bash "$SCRIPT" 0 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] \
    && [ "${out#*--background (no Background recorded) --changes (no Changes recorded)}" != "$out" ]; then
    pass "NG4: DRY_RUN arg vector carries both FEATURE markers"
else
    fail "NG4: rc=$rc, out='$out'"
fi
if [ "${out#*--background dry-title}" != "$out" ]; then
    fail "NG4b: --background was filled with the issue title"
else
    pass "NG4b: --background is never filled with the issue title"
fi

# NG5: INCIDENT, both fields missing — argument-vector check (DRY_RUN, no I/O)
out=$(DRY_RUN=1 ISSUE_CATEGORY=INCIDENT ISSUE_NUMBER=0 ISSUE_TITLE="dry-title" \
    ISSUE_BODY="prose only" run_with_timeout 15 bash "$SCRIPT" 0 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] \
    && [ "${out#*--cause (no Cause recorded) --fix (no Fix recorded)}" != "$out" ]; then
    pass "NG5: DRY_RUN arg vector carries both INCIDENT markers"
else
    fail "NG5: rc=$rc, out='$out'"
fi
if [ "${out#*--cause dry-title}" != "$out" ]; then
    fail "NG5b: --cause was filled with the issue title"
else
    pass "NG5b: --cause is never filled with the issue title"
fi

# NG6/NG7: the literal #2094 shape — the field LABELS are present but empty
# (template `value:` prefill submitted untouched) and the title still carries
# the `title:` prefill. extract_field's regex matches such lines and captures
# nothing, so the old fallback borrowed the TITLE for the first field and the
# body's first non-heading line (`Cause: ` / `Background: `) for the second.
# Both borrowings are asserted absent; table-driven over the INCIDENT and
# non-INCIDENT branches (CPR-ORTH).
while IFS='|' read -r name scenario category title f1 f2 borrowed; do
    name="${name// /}"; scenario="${scenario// /}"; category="${category// /}"
    f1="${f1// /}"; f2="${f2// /}"
    [ -z "$name" ] && continue
    title="${title# }"; title="${title% }"
    borrowed="${borrowed# }"; borrowed="${borrowed% }"
    setup_ith_tmp
    out=$(DRY_RUN= GH_MOCK_SCENARIO="$scenario" run_with_timeout 30 bash "$SCRIPT" 42 \
        --commit abc1234 2>/dev/null)
    rc=$?
    history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
    marker_count=$(printf '%s\n' "$history_content" | grep -cE "$MARKER_ERE")
    if [ "$rc" -eq 0 ] && echo "$history_content" | grep -q "$category" \
        && echo "$history_content" | grep -qF "$f1: (no $f1 recorded)" \
        && echo "$history_content" | grep -qF "$f2: (no $f2 recorded)"; then
        pass "$name: empty-valued $f1/$f2 labels → both markers reach history.md"
    else
        fail "$name: rc=$rc, history.md='$history_content'"
    fi
    if echo "$history_content" | grep -qF "$f1: $title"; then
        fail "${name}b: issue title was borrowed into $f1 — fabricating fallback is back"
    else
        pass "${name}b: issue title is never borrowed into $f1"
    fi
    if echo "$history_content" | grep -qF "$f2: $borrowed"; then
        fail "${name}c: body line '$borrowed' was borrowed into $f2"
    else
        pass "${name}c: no other body line is borrowed into $f2"
    fi
    if [ "$marker_count" -eq 2 ]; then
        pass "${name}d: documented grep ERE finds exactly the 2 markers written"
    else
        fail "${name}d: expected 2 marker lines, got $marker_count"
    fi
    assert_appended "${name}e"
    # From here on the file has already grown, so re-pin the baseline: the NG8
    # re-run below must leave it byte-identical (skip path), which is the
    # opposite verdict and would be unassertable against the stale snapshot.
    HIST_BEFORE="$(cksum <"$ITH_TMP/docs/history.md" 2>/dev/null)"
    # Idempotency: converting the same issue again must not append a second
    # entry or a second set of markers. Exercised on the INCIDENT row only —
    # issue-to-history.sh's skip-grep runs before CATEGORY is derived, so it is
    # branch-independent and a second subprocess per row would buy nothing.
    if [ "$name" = "NG6" ]; then
        out2=$(DRY_RUN= GH_MOCK_SCENARIO="$scenario" run_with_timeout 30 bash "$SCRIPT" 42 \
            --commit abc1234 2>/dev/null)
        rc2=$?
        if [ "$(cksum <"$ITH_TMP/docs/history.md" 2>/dev/null)" = "$HIST_BEFORE" ]; then
            pass "NG8d: the re-run left docs/history.md byte-identical"
        else
            fail "NG8d: docs/history.md changed on the re-run — the skip path did not hold"
        fi
        history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
        entry_count=$(printf '%s\n' "$history_content" | grep -c '^### ')
        marker_count=$(printf '%s\n' "$history_content" | grep -cE "$MARKER_ERE")
        if [ "$rc2" -eq 0 ] && [ "$entry_count" -eq 1 ]; then
            pass "NG8: re-converting the same issue appends no second entry"
        else
            fail "NG8: rc2=$rc2 entries=$entry_count, history.md='$history_content'"
        fi
        if [ "$marker_count" -eq 2 ]; then
            pass "NG8b: exactly one set of 2 markers survives the re-run"
        else
            fail "NG8b: expected 2 marker lines after two runs, got $marker_count"
        fi
        if echo "$out2" | grep -q "Already in history"; then
            pass "NG8c: the re-run reports the skip instead of silently duplicating"
        else
            fail "NG8c: expected 'Already in history' on the second run, got '$out2'"
        fi
    fi
    teardown_ith_tmp
done <<'TABLE'
NG6 | issue_incident_empty_labels | INCIDENT | <short subject>fix issues | Cause      | Fix     | Cause:
NG7 | issue_task_empty_labels     | FEATURE  | <short title>update stuff | Background | Changes | Background:
TABLE

# Sidecar-1: WORKTREE_NOTES.md sidecar handoff (Phase 1 → Phase 2 simulation)
setup_ith_tmp
SIDECAR_DIR=$(mktemp -d)
SIDECAR_FILE="$SIDECAR_DIR/issue-42-worktree-notes.md"
printf '# Worktree Notes\nBranch: fix/test\n\n## History Notes\n- sidecar-note-alpha\n- sidecar-note-beta\n' > "$SIDECAR_FILE"
out=$(DRY_RUN= GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$SCRIPT" 42 --commit abc1234 \
    --history-notes-file "$SIDECAR_FILE" 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
if [ "$rc" -eq 0 ] && echo "$history_content" | grep -q "sidecar-note-alpha"; then
    pass "Sidecar-1: per-issue sidecar handoff → notes appear in history entry"
else
    fail "Sidecar-1: rc=$rc, history.md='$history_content'"
fi
assert_appended "Sidecar-1b"
rm -rf "$SIDECAR_DIR"
teardown_ith_tmp

else
    fail "H1 (precondition): $SCRIPT not found"
    fail "H2 (precondition): $SCRIPT not found"
    fail "P1 (precondition): $SCRIPT not found"
    fail "P2 (precondition): $SCRIPT not found"
    fail "NG1 (precondition): $SCRIPT not found"
    fail "NG2 (precondition): $SCRIPT not found"
    fail "NG3 (precondition): $SCRIPT not found"
    fail "NG4 (precondition): $SCRIPT not found"
    fail "NG5 (precondition): $SCRIPT not found"
    fail "NG6 (precondition): $SCRIPT not found"
    fail "NG7 (precondition): $SCRIPT not found"
    fail "NG8 (precondition): $SCRIPT not found"
    fail "Sidecar-1 (precondition): $SCRIPT not found"
fi

# === bin/doc-append.py directly: marker formatting matches the grep recipe ===
# NG1-NG3 above only pin the gh-mock doc-append STUB's formatting. DA1/DA2 run
# the real bin/doc-append.py so the documented ERE is pinned against both
# branches of _build_entry (INCIDENT vs non-INCIDENT).
DOC_APPEND_PY="$AGENTS_DIR/bin/doc-append.py"
DA_TMP=$(mktemp)
DA_TMP2=$(mktemp)
trap 'rm -f "$DA_TMP" "$DA_TMP2"' EXIT

if [ -f "$DOC_APPEND_PY" ]; then

# DA1: INCIDENT branch (doc-append.py Cause:/Fix: assembly)
run_with_timeout 15 "${PY_RUNNER[@]}" "$DOC_APPEND_PY" "$DA_TMP" \
    --category INCIDENT --subject "DA1 direct doc-append.py marker check" \
    --date 2026-01-01 --cause "(no Cause recorded)" --fix "(no Fix recorded)" >/dev/null 2>&1
rc=$?
da1_count=$(grep -cE "$MARKER_ERE" "$DA_TMP" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && grep -qF "Cause: (no Cause recorded)" "$DA_TMP" \
    && grep -qF "Fix: (no Fix recorded)" "$DA_TMP"; then
    pass "DA1: bin/doc-append.py INCIDENT branch writes both markers verbatim"
else
    fail "DA1: rc=$rc, file='$(cat "$DA_TMP" 2>/dev/null)'"
fi
if [ "${da1_count:-0}" -eq 2 ]; then
    pass "DA1b: documented grep ERE finds exactly 2 markers in the INCIDENT entry"
else
    fail "DA1b: expected 2 marker lines, got ${da1_count:-0}"
fi

# DA2: non-INCIDENT branch (doc-append.py Background:/Changes: assembly).
# Separate temp file on purpose — sharing DA_TMP would make the count 4.
run_with_timeout 15 "${PY_RUNNER[@]}" "$DOC_APPEND_PY" "$DA_TMP2" \
    --category FEATURE --subject "DA2 direct doc-append.py marker check" \
    --date 2026-01-01 --background "(no Background recorded)" \
    --changes "(no Changes recorded)" >/dev/null 2>&1
rc=$?
da2_count=$(grep -cE "$MARKER_ERE" "$DA_TMP2" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && grep -qF "Background: (no Background recorded)" "$DA_TMP2" \
    && grep -qF "Changes: (no Changes recorded)" "$DA_TMP2"; then
    pass "DA2: bin/doc-append.py FEATURE branch writes both markers verbatim"
else
    fail "DA2: rc=$rc, file='$(cat "$DA_TMP2" 2>/dev/null)'"
fi
if [ "${da2_count:-0}" -eq 2 ]; then
    pass "DA2b: documented grep ERE finds exactly 2 markers in the FEATURE entry"
else
    fail "DA2b: expected 2 marker lines, got ${da2_count:-0}"
fi

else
    fail "DA1 (precondition): $DOC_APPEND_PY not found"
    fail "DA2 (precondition): $DOC_APPEND_PY not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
