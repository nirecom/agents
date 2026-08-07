#!/bin/bash
# tests/feature-530-manual-reminders-triage-exclusion.sh
# Tests: bin/worktree-notes-triage.js, hooks/lib/worktree-notes.js, hooks/lib/worktree-notes-sections.js
# Tags: notes-promotion, worktree-notes, triage, manual-reminders, bin, TL2, scope:issue-specific
#
# Issue #530 — WORKTREE_NOTES.md gains a `## ManualReminders` section for things
# the user must do by hand. Unlike BugsFound / RelatedTasks / NextTasks it is
# NOT a triage section: auto-promoting a reminder into a GitHub issue is exactly
# the wrong outcome, because the reminder is addressed to the person closing the
# session, not to a future implementer.
#
# M1  a reminder is invisible to `list`
# M2  a notes file predating the section still parses (3 entries, no crash)
# M3  the list/annotate contract WE-11 depends on does not drift when the new
#     `resolve` subcommand lands alongside it
#
# Split out of tests/feature-worktree-end-step55-promotion.sh, which crossed the
# 500-line HARD limit; that file keeps the F/R promotion-flow cases.
#
# TL2: spawns the real CLI against real fixture files.
#
# TL3 gap (what this test does NOT catch):
# - Whether the live protocol reads `## ManualReminders` aloud to the user
#   (NP-11). The CLI proves only that the section is never promoted; a reminder
#   that is neither filed nor surfaced is silently lost, and only a real session
#   can show which of the two happened.
# - Whether the model, seeing a reminder in the notes it just read, files it as
#   an issue anyway despite the CLI omitting it from `list`.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.
#
# Status at write-tests time: M1/M2 already hold — bin/worktree-notes-triage.js
# has a fixed SECTIONS list that ManualReminders is not in — so these are
# regression guards, not RED specs. They fail the moment someone "helpfully"
# adds ManualReminders to that list.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
TRIAGE_BIN="${_AGENTS_DIR_NODE}/bin/worktree-notes-triage.js"

PASS=0; FAIL=0; SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$1" "${@:2}"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$@"
    else
        "${@:2}"
    fi
}

require_bin() {
    if [ ! -f "$TRIAGE_BIN" ]; then
        skip "$1 (bin/worktree-notes-triage.js not implemented yet)"
        return 1
    fi
    return 0
}

TMPDIR_BASE="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/manual-reminders-$$")"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}


# Notes file carrying a REAL (non-placeholder) ManualReminders entry alongside
# one promotable entry per triage section. Echoes the absolute path.
make_notes_with_manual_reminders() {
    local subdir="$1"
    local dir="$TMPDIR_BASE/$subdir"
    mkdir -p "$dir"
    cat > "$dir/WORKTREE_NOTES.md" <<'EOF'
# Worktree Notes
Branch: test
Created: 2026-05-22
Path: /tmp/test
WORKTREE_BASE_DIR: (default)

## Gitignored files copied from main
- (none)

## BugsFound
- bug entry one

## RelatedTasks
- related entry one

## NextTasks
- next entry one

## ManualReminders
- rotate the staging credential by hand before merge

## History Notes
- (none)

## Changelog Notes
- (none)

## SiblingWorktrees
- (none)
EOF
    node_path "$dir/WORKTREE_NOTES.md"
}

# Pre-#530 notes file: NO ## ManualReminders section at all. Exactly 3
# promotable entries (one per triage section).
make_notes_legacy_format() {
    local subdir="$1"
    local dir="$TMPDIR_BASE/$subdir"
    mkdir -p "$dir"
    cat > "$dir/WORKTREE_NOTES.md" <<'EOF'
# Worktree Notes
Branch: test
Created: 2026-05-22
Path: /tmp/test
WORKTREE_BASE_DIR: (default)

## Gitignored files copied from main
- (none)

## BugsFound
- legacy bug entry

## RelatedTasks
- legacy related entry

## NextTasks
- legacy next entry

## History Notes
- (none)
EOF
    node_path "$dir/WORKTREE_NOTES.md"
}

# ============ Tests ============

# ---- M1 (#530): ManualReminders entries are never listed for promotion ----
test_M1_manual_reminders_excluded_from_list() {
    require_bin "M1: ManualReminders excluded from list" || return

    local notes; notes="$(make_notes_with_manual_reminders "m1")"
    local out
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"

    local summary
    summary="$(node -e "
        try {
            const j = JSON.parse(process.argv[1]);
            const sections = [...new Set(j.map(e => e.section))].sort().join('+');
            const leaked = j.some(e =>
                e.section === 'ManualReminders' ||
                String(e.raw || '').includes('rotate the staging credential'));
            process.stdout.write(j.length + '|' + sections + '|' + leaked);
        } catch (e) { process.stdout.write('ERR|ERR|ERR'); }
    " -- "$out" 2>/dev/null)"

    local len sections leaked
    len="${summary%%|*}"
    sections="$(printf '%s' "$summary" | cut -d'|' -f2)"
    leaked="${summary##*|}"

    if [ "$len" = "3" ] && [ "$leaked" = "false" ] \
       && [ "$sections" = "BugsFound+NextTasks+RelatedTasks" ]; then
        pass "M1: list returns only BugsFound/RelatedTasks/NextTasks; ManualReminders entry not promoted"
    else
        fail "M1: len=$len sections=$sections leaked=$leaked (out=$out)"
    fi
}

# ---- M2 (#530): notes files without a ManualReminders section still parse ----
test_M2_legacy_notes_without_manual_reminders() {
    require_bin "M2: legacy notes without ManualReminders" || return

    local notes; notes="$(make_notes_legacy_format "m2")"
    local out
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"

    local summary
    summary="$(node -e "
        try {
            const j = JSON.parse(process.argv[1]);
            const sections = [...new Set(j.map(e => e.section))].sort().join('+');
            process.stdout.write(j.length + '|' + sections);
        } catch (e) { process.stdout.write('ERR|ERR'); }
    " -- "$out" 2>/dev/null)"

    local len sections
    len="${summary%%|*}"
    sections="${summary##*|}"

    if [ "$len" = "3" ] && [ "$sections" = "BugsFound+NextTasks+RelatedTasks" ]; then
        pass "M2: pre-#530 notes file (no ## ManualReminders) still yields 3 promotable entries"
    else
        fail "M2: len=$len sections=$sections (out=$out)"
    fi
}

# ---- M3 (#530): list/annotate contract unchanged after `resolve` is added ----
# Regression guard: the new subcommand must not alter the argument shape, the
# per-entry JSON keys, or the exit codes that WE-11 already depends on.
test_M3_list_annotate_contract_unchanged() {
    require_bin "M3: list/annotate contract unchanged" || return

    local notes; notes="$(make_notes_with_manual_reminders "m3")"
    local failures=""

    # (a) `list <path>` — exit 0, JSON array, exact per-entry key set.
    local out rc keys
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    rc=$?
    [ "$rc" = "0" ] || failures="$failures list-exit=$rc"
    keys="$(node -e "
        try {
            const j = JSON.parse(process.argv[1]);
            if (!Array.isArray(j) || j.length === 0) { process.stdout.write('NOT_ARRAY'); }
            else { process.stdout.write(Object.keys(j[0]).sort().join(',')); }
        } catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"
    [ "$keys" = "hasMarker,lineNumber,raw,section" ] || failures="$failures keys=$keys"

    # (b) `annotate <path> <line> <issue>` — 3 positional args, exit 0.
    local target_line
    target_line="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j[0].lineNumber)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"
    if [ "$target_line" = "ERR" ] || [ -z "$target_line" ]; then
        failures="$failures annotate-target-unreadable"
    else
        run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$target_line" 4242 >/dev/null 2>&1
        rc=$?
        [ "$rc" = "0" ] || failures="$failures annotate-exit=$rc"
        grep -q "<!-- promoted: #4242 -->" "$notes" 2>/dev/null || failures="$failures annotate-marker-missing"
    fi

    # (c) unknown subcommand still exits 1, and bare invocation still exits 1.
    run_with_timeout 30 node "$TRIAGE_BIN" bogus-subcommand "$notes" >/dev/null 2>&1
    rc=$?
    [ "$rc" = "1" ] || failures="$failures unknown-subcommand-exit=$rc"
    run_with_timeout 30 node "$TRIAGE_BIN" >/dev/null 2>&1
    rc=$?
    [ "$rc" = "1" ] || failures="$failures no-args-exit=$rc"

    if [ -z "$failures" ]; then
        pass "M3: list/annotate argument shape, JSON keys and exit codes unchanged"
    else
        fail "M3: contract drift —$failures"
    fi
}

# ============ Run all ============

test_M1_manual_reminders_excluded_from_list
test_M2_legacy_notes_without_manual_reminders
test_M3_list_annotate_contract_unchanged

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
