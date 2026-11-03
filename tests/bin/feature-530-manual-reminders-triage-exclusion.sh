#!/bin/bash
# tests/bin/feature-530-manual-reminders-triage-exclusion.sh
# Tests: bin/worktree-notes-triage.js, hooks/lib/worktree-notes.js, hooks/lib/worktree-notes-sections.js
# Tags: notes-promotion, worktree-notes, triage, manual-reminders, bin, TL2, scope:issue-specific
# #530: `## ManualReminders` is not a triage section (a reminder is for the session closer, not an issue).
# M1 a reminder is invisible to `list`; M2 a pre-section notes file still parses; M3 the list/annotate
# contract WE-11 depends on does not drift (list keys gain userAcknowledged in #2903). TL2: real CLI.
# TL3 gap: whether the live protocol surfaces reminders (NP-11) or files them anyway; checked at
# WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh category: skill-orchestration).

set -u

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi
TRIAGE_BIN="${_SCRIPT_CHECKOUT_ROOT_NODE}/bin/worktree-notes-triage.js"

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
    [ "$keys" = "hasMarker,lineNumber,raw,section,userAcknowledged" ] || failures="$failures keys=$keys"

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
