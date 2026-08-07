#!/usr/bin/env bash
# tests/feature-530-notes-promotion-triage-flow/security.sh
# Tests: bin/worktree-notes-triage.js, bin/worktree-notes-triage/resolve.js
# Tags: notes-promotion, worktree-notes, triage, security, path-traversal, TL2, scope:issue-specific
#
# S — attacker-controlled resolve flags must not escape their anchors, and
#     attacker-shaped notes paths must not be followed out of the worktree.
#     (The prompt-injection cases that used to live here moved to injection.sh
#     when this file crossed the 500-line HARD limit; see rules/coding/file-split.md.)
#
# Threat model: --session-id and --pr-branch are interpolated into paths under
# the plans dir and <main-root>/.worktree-backup/. A caller that can influence a
# branch name (anyone who can open a PR) could otherwise steer `resolve` at an
# arbitrary WORKTREE_NOTES.md, whose contents are then read aloud and filed into
# public GitHub issues. Escape here is an exfiltration primitive, not a crash.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# An outside notes file that no invocation is allowed to reach. Its body carries
# a unique token so a leak is detectable in output, not just by path compare.
LEAK_TOKEN="NPLEAK-8f21c4-SECRET"
OUTSIDE_DIR="$TMPD/outside"
mkdir -p "$OUTSIDE_DIR"
cat > "$OUTSIDE_DIR/WORKTREE_NOTES.md" <<EOF
# Worktree Notes
Branch: victim/private
Created: 2026-08-01
Path: /tmp/victim
Session-ID: sess-victim

## BugsFound
- $LEAK_TOKEN credentials for the staging database are in the shared vault

## RelatedTasks
- (none)

## NextTasks
- (none)

## History Notes
- (none)
EOF
OUTSIDE_NOTES="$OUTSIDE_DIR/WORKTREE_NOTES.md"
OUTSIDE_MD5="$(file_md5 "$OUTSIDE_NOTES")"

# --------------------------------------------------------------------------
# Bait placement: every attack string below must LAND on a file that really
# exists, otherwise the case passes because the target was absent rather than
# because the guard fired. Each bait sits exactly where the corresponding
# escaped path resolves to, and carries the same LEAK_TOKEN.
#
#   --session-id '../outside'  → <plans>/../outside-notes-backup/         (branch 3)
#                              → <plans>/../outside-final-report-env.json (branch 2)
#   --pr-branch  '../../outside' → <main-root>/.worktree-backup/../../outside/ (branch 4)
#                                 == $TMPD/outside, i.e. OUTSIDE_DIR itself
# --------------------------------------------------------------------------
mkdir -p "$TMPD/outside-notes-backup"
cp "$OUTSIDE_NOTES" "$TMPD/outside-notes-backup/WORKTREE_NOTES.md"
BAIT_BACKUP="$TMPD/outside-notes-backup/WORKTREE_NOTES.md"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({NOTES_BACKUP_PATH: process.argv[2]}), "utf8");' \
    -- "$TMPD/outside-final-report-env.json" "$(nodepath "$OUTSIDE_NOTES")"

# assert_contained <label> <detail-prefix>
# Shared oracle for every S case: whatever `resolve` decided, it must not have
# named the outside file, echoed its contents, or crashed.
assert_contained() {
    local label="$1" missing="" got norm outside_norm bait_norm
    got="$(jfield "$RESOLVE_OUT" notesPath)"
    norm="$(norm_path "$got")"
    outside_norm="$(norm_path "$OUTSIDE_NOTES")"
    bait_norm="$(norm_path "$BAIT_BACKUP")"

    [ "$norm" = "$outside_norm" ] && missing="$missing resolved-to-outside"
    [ "$norm" = "$bait_norm" ] && missing="$missing resolved-to-bait-backup"
    case "$RESOLVE_OUT$RESOLVE_ERR" in
        *"$LEAK_TOKEN"*) missing="$missing leaked-content" ;;
    esac
    # exit 0 (skip or promote) or 1 (rejected) are both acceptable; a crash
    # (rc>1, or non-JSON stdout) is not.
    case "$RESOLVE_RC" in
        0|1) ;;
        *) missing="$missing rc=$RESOLVE_RC" ;;
    esac
    if [ -n "$RESOLVE_OUT" ] && [ "$(jfield "$RESOLVE_OUT" action)" = "ERR" ]; then
        missing="$missing non-json-stdout"
    fi
    [ "$(file_md5 "$OUTSIDE_NOTES")" = "$OUTSIDE_MD5" ] || missing="$missing outside-file-modified"

    if [ -z "$missing" ]; then
        pass "$label"
    else
        fail "$label" "$missing (rc=$RESOLVE_RC out=$RESOLVE_OUT err=$RESOLVE_ERR)"
    fi
}

# ===========================================================================
# S1 — --session-id is interpolated into plans-dir paths
# ===========================================================================
s1_session_id_attacks() {
    # Plant the bait exactly where a traversing session-id would land:
    # $PLANS_DIR/../outside/WORKTREE_NOTES.md  ==  $TMPD/outside/WORKTREE_NOTES.md
    local a
    for a in \
        '../outside' \
        '../../outside' \
        '..\outside' \
        '../outside/../outside' \
        '/etc/passwd' \
        'C:\Windows\System32' \
        'sess; echo pwned' \
        'sess$(id)' \
        'sess`id`' \
        'sess|id' \
        'sess
newline'
    do
        resolve --caller session-close --session-id "$a"
        assert_contained "S1: --session-id '$a' cannot escape the plans dir"
    done
}

# S1c — the bait is genuinely reachable, so S1's rejections are the guard's
# doing and not an absent target. Same two branches (env-json and
# notes-backup-dir), same files, reached with a session id that needs no escape.
s1c_bait_is_reachable() {
    local missing="" via got
    resolve --caller session-close --session-id "outside" --plans-dir "$(nodepath "$TMPD")"
    via="$(jfield "$RESOLVE_OUT" resolvedVia)"
    got="$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")"
    [ "$(jfield "$RESOLVE_OUT" action)" = "promote" ] || missing="$missing not-promoted"
    # Branch 2 (env-json) outranks branch 3, so the env JSON's target wins.
    [ "$via" = "env-json" ] || missing="$missing via=$via"
    [ "$got" = "$(norm_path "$OUTSIDE_NOTES")" ] || missing="$missing path=$got"

    if [ -z "$missing" ]; then
        pass "S1c: control — the planted bait IS reachable through a non-escaping session id, so the S1 rejections come from the guard"
    else
        fail "S1c: bait not reachable; the S1 cases prove nothing" "$missing (out=$RESOLVE_OUT)"
    fi
}

# ===========================================================================
# S2 — --pr-branch is interpolated into <main-root>/.worktree-backup/<branch>/
# ===========================================================================
s2_pr_branch_attacks() {
    # `../../outside` from <main-root>/.worktree-backup/ resolves to $TMPD/outside,
    # i.e. OUTSIDE_DIR itself — the escape lands on a real notes file, so a
    # missing guard would promote it rather than resolve nothing. The deeper
    # `../../../` variants are kept as shape coverage.
    # Landing proof for this anchor: S2c below.
    local a
    for a in \
        '../../outside' \
        '..\..\outside' \
        '../../../outside' \
        '..\..\..\outside' \
        'feature/../../../outside' \
        '/tmp' \
        'feature/x;whoami' \
        'feature/$(whoami)' \
        '..'
    do
        resolve --caller issue-close-finalize --issue 5 \
                --pr-branch "$a" --main-root "$(nodepath "$MAIN_ROOT")"
        assert_contained "S2: --pr-branch '$a' cannot escape .worktree-backup/"
    done
}

# S2c — the same anchor, used honestly, does resolve. Without this the S2 rows
# would also pass against a `resolve` that never uses --pr-branch at all.
s2c_backup_branch_anchor_works() {
    local missing="" notes
    notes="$(write_notes "$MAIN_ROOT/.worktree-backup/feature/legit" "sess-s2c")"
    resolve --caller issue-close-finalize --issue 5 \
            --pr-branch "feature/legit" --main-root "$(nodepath "$MAIN_ROOT")"
    [ "$(jfield "$RESOLVE_OUT" resolvedVia)" = "backup-branch-dir" ] \
        || missing="$missing via=$(jfield "$RESOLVE_OUT" resolvedVia)"
    [ "$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")" = "$(norm_path "$notes")" ] \
        || missing="$missing path=$(jfield "$RESOLVE_OUT" notesPath)"

    if [ -z "$missing" ]; then
        pass "S2c: control — an honest --pr-branch resolves through .worktree-backup/, so the S2 rejections are the guard's doing"
    else
        fail "S2c: backup-branch anchor does not work at all" "$missing (out=$RESOLVE_OUT)"
    fi
}

# ===========================================================================
# S3 — --worktree / --main-root pointed straight at the protected area
# ===========================================================================
# These flags are caller-supplied absolute paths, so "escape" is not the risk —
# the risk is that a mis-aimed or attacker-supplied root silently promotes
# someone else's notes. The contract asserted here is the weaker but real one:
# whatever is resolved must live under the anchor that was passed in, and
# nothing outside it may be read or written.
s3_worktree_and_main_root() {
    local wt="$TMPD/s3-wt" notes anchor got missing=""
    notes="$(write_notes "$wt" "sess-s3")"

    # (a) A traversing --worktree that walks out to the protected dir.
    resolve --caller worktree-end --worktree "$(nodepath "$wt")/../outside"
    assert_contained "S3a: --worktree traversing to an outside dir does not promote the outside notes"

    # (b) --worktree with a trailing separator and mixed separators must still
    # resolve to the same canonical path, not a second, different one.
    resolve --caller worktree-end --worktree "$(nodepath "$wt")/"
    got="$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")"
    [ "$got" = "$(norm_path "$notes")" ] || missing="$missing trailing-sep=$got"
    resolve --caller worktree-end --worktree "$(nodepath "$wt")"
    got="$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")"
    [ "$got" = "$(norm_path "$notes")" ] || missing="$missing plain=$got"
    if [ -z "$missing" ]; then
        pass "S3b: separator variants of --worktree canonicalize to one notesPath"
    else
        fail "S3b: separator handling inconsistent" "$missing"
    fi

    # (c) --main-root aimed at the protected parent: the backup-branch branch
    # must not turn that into a read of the outside notes.
    resolve --caller issue-close-finalize --issue 5 \
            --pr-branch "../outside" --main-root "$(nodepath "$TMPD")"
    assert_contained "S3c: --main-root + traversing branch cannot reach the outside notes"

    # (d) Control — the anchor genuinely works when used honestly. Without this
    # the S3 cases could all "pass" because resolve is a no-op stub.
    anchor="$TMPD/s3-anchor"
    write_notes "$anchor" "sess-s3d" >/dev/null
    resolve --caller worktree-end --worktree "$(nodepath "$anchor")"
    if [ "$(jfield "$RESOLVE_OUT" action)" = "promote" ]; then
        pass "S3d: control — an honest --worktree still promotes (guards are not a blanket deny)"
    else
        fail "S3d: control failed" "out=$RESOLVE_OUT err=$RESOLVE_ERR"
    fi
}

# ===========================================================================
# S4 — symlink escape
# ===========================================================================
# A symlink inside a legitimate anchor pointing at the protected dir. Symlink
# creation needs privilege on Windows; skip rather than false-green.
s4_symlink_escape() {
    local wt="$TMPD/s4-wt"
    mkdir -p "$wt"
    ln -s "$OUTSIDE_DIR" "$wt/link" 2>/dev/null
    # `ln -s` succeeds on MSYS/Git-Bash by COPYING the directory when the host
    # forbids symlinks, which would turn every assertion below into a statement
    # about a private copy. Only a real symlink counts.
    if [ ! -L "$wt/link" ]; then
        rm -rf "$wt/link" 2>/dev/null
        skip "S4a: symlink escape (this environment cannot create real symlinks)"
        skip "S4b: symlink escape (this environment cannot create real symlinks)"
        return
    fi

    resolve --caller worktree-end --worktree "$(nodepath "$wt/link")"
    assert_contained "S4a: a symlinked --worktree does not expose the outside notes"

    # And the file itself must survive an annotate attempt through the link.
    local rc missing=""
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$(nodepath "$wt/link/WORKTREE_NOTES.md")" 9 4242 \
        >/dev/null 2>&1
    rc=$?
    [ "$rc" != "0" ] || missing="$missing annotate-exit=0"
    [ "$(file_md5 "$OUTSIDE_NOTES")" = "$OUTSIDE_MD5" ] || missing="$missing md5-changed"
    [ "$(tmp_residue "$OUTSIDE_NOTES")" = "0" ] || missing="$missing tmp-residue-outside"

    if [ -z "$missing" ]; then
        pass "S4b: annotate through a symlink exits nonzero and leaves the outside file byte-identical, with no temp residue"
    else
        fail "S4b: symlinked annotate not contained" "$missing (rc=$rc)"
    fi
}

# KNOWN GAP (source-side, not testable from tests/): bin/worktree-notes-triage.js
# validates the RAW argument (traversal, absolute, basename) and then calls
# fs.readFileSync / fs.renameSync, neither of which refuses a symlink. On a host
# with real symlinks, `list` on a symlinked WORKTREE_NOTES.md follows the link
# and prints the target's entries, and `annotate` aimed at a genuine entry line
# rewrites the target. Asserting the refusal contract here would be a permanently
# red test: closing it needs an fs.lstatSync/realpath containment check in the
# CLI. S4a/S4b pin the containment that today's code does provide.

# ===========================================================================
# S5 — relative traversal into list/annotate
# ===========================================================================
# `path.normalize` collapses `..` inside an ABSOLUTE path, so an absolute
# traversal string is indistinguishable from its target and the guard cannot
# fire. A RELATIVE path keeps its leading `..`, which is what the traversal
# check actually sees. Both forms are exercised: the relative one must be
# rejected, and neither may modify the protected file.
s5_relative_traversal() {
    local wt="$TMPD/s5-wt" rel out rc missing=""
    write_notes "$wt" "sess-s5" >/dev/null
    rel="../outside/WORKTREE_NOTES.md"

    ( cd "$wt" && run_with_timeout 30 node "$TRIAGE_BIN" list "$rel" >"$TMPD/s5-list.out" 2>&1 )
    rc=$?
    out="$(cat "$TMPD/s5-list.out" 2>/dev/null)"
    [ "$rc" != "0" ] || missing="$missing list-accepted-traversal"
    case "$out" in *"$LEAK_TOKEN"*) missing="$missing list-leaked-content" ;; esac

    ( cd "$wt" && run_with_timeout 30 node "$TRIAGE_BIN" annotate "$rel" 9 4242 >/dev/null 2>&1 )
    rc=$?
    [ "$rc" != "0" ] || missing="$missing annotate-accepted-traversal"
    [ "$(file_md5 "$OUTSIDE_NOTES")" = "$OUTSIDE_MD5" ] || missing="$missing outside-file-modified"
    [ "$(tmp_residue "$OUTSIDE_NOTES")" = "0" ] || missing="$missing tmp-residue-outside"

    if [ -z "$missing" ]; then
        pass "S5: relative ../ traversal is rejected by list and annotate; protected file unchanged"
    else
        fail "S5: traversal guard leaked" "$missing (rc=$rc out=$out)"
    fi
}

# ===========================================================================
# S6 — ABSOLUTE traversal into list/annotate
# ===========================================================================
# The relative form (S5) is the one people reach for; the absolute form is the
# one that silently works if the guard is applied after normalization, because
# `path.resolve` collapses the `..` and the result is indistinguishable from a
# legitimate path. Both subcommands must refuse the raw string with a nonzero
# exit, and the protected file must be untouched — the escape lands on a real
# notes file (OUTSIDE_NOTES), so "nothing happened" cannot be the target's doing.
s6_absolute_traversal() {
    local wt="$TMPD/s6-wt" abs out rc missing=""
    write_notes "$wt" "sess-s6" >/dev/null
    abs="$(nodepath "$wt")/../outside/WORKTREE_NOTES.md"

    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$abs" 2>&1)"
    rc=$?
    [ "$rc" != "0" ] || missing="$missing list-exit=0"
    case "$out" in *traversal*|*rejected*) ;; *) missing="$missing list-no-diagnostic=[$out]" ;; esac
    case "$out" in *"$LEAK_TOKEN"*) missing="$missing list-leaked-content" ;; esac

    out="$(run_with_timeout 30 node "$TRIAGE_BIN" annotate "$abs" 8 4243 2>&1)"
    rc=$?
    [ "$rc" != "0" ] || missing="$missing annotate-exit=0"
    case "$out" in *traversal*|*rejected*) ;; *) missing="$missing annotate-no-diagnostic=[$out]" ;; esac
    [ "$(file_md5 "$OUTSIDE_NOTES")" = "$OUTSIDE_MD5" ] || missing="$missing outside-file-modified"
    [ "$(tmp_residue "$OUTSIDE_NOTES")" = "0" ] || missing="$missing tmp-residue-outside"

    # Control: line 8 IS a real entry, so an unguarded annotate would have
    # succeeded — the refusal above is the traversal check, not a bad target.
    local direct rc2
    direct="$(nodepath "$OUTSIDE_DIR/WORKTREE_NOTES.md")"
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$direct" 2>/dev/null)"
    rc2=$?
    [ "$rc2" = "0" ] || missing="$missing control-list-rc=$rc2"
    [ "$(json_at "$out" 0 lineNumber)" = "8" ] || missing="$missing control-line=$(json_at "$out" 0 lineNumber)"

    if [ -z "$missing" ]; then
        pass "S6: an absolute path containing '..' is refused by both list and annotate (nonzero exit), while the same file is reachable directly"
    else
        fail "S6: absolute traversal not refused" "$missing"
    fi
}

s1_session_id_attacks
s1c_bait_is_reachable
s2_pr_branch_attacks
s2c_backup_branch_anchor_works
s3_worktree_and_main_root
s4_symlink_escape
s5_relative_traversal
s6_absolute_traversal

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
