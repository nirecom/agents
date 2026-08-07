#!/usr/bin/env bash
# tests/feature-530-notes-promotion-triage-flow/resolve-branches.sh
# Tests: bin/worktree-notes-triage.js, bin/worktree-notes-triage/resolve.js
# Tags: notes-promotion, worktree-notes, triage, cli, subprocess, TL2, scope:issue-specific
#
# G1 ownership gate, G2 the five resolution branches, G3 priority, G4 unresolved,
# G5 output contract, G8 intent-scan exact issue matching.
#
# Every G2 branch asserts the full tuple — action, resolvedVia, the exact
# canonical notesPath, and exit code — plus, where a lower-priority candidate
# exists, that the branch under test wins over it. Asserting resolvedVia alone
# would let a wrong path or a wrong action ride along unnoticed.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# assert_resolution <label> <want-via> <want-notes-path> — checks the whole tuple
# against the last resolve() call.
assert_resolution() {
    local label="$1" want_via="$2" want_path="$3"
    local missing="" action via got
    action="$(jfield "$RESOLVE_OUT" action)"
    via="$(jfield "$RESOLVE_OUT" resolvedVia)"
    got="$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")"
    want_path="$(norm_path "$want_path")"

    [ "$action" = "promote" ]   || missing="$missing action=$action"
    [ "$via" = "$want_via" ]    || missing="$missing resolvedVia=$via"
    [ "$got" = "$want_path" ]   || missing="$missing notesPath=$got(want=$want_path)"
    [ "$RESOLVE_RC" = "0" ]     || missing="$missing rc=$RESOLVE_RC"

    if [ -z "$missing" ]; then
        pass "$label"
    else
        fail "$label" "$missing (out=$RESOLVE_OUT err=$RESOLVE_ERR)"
    fi
}

# ===========================================================================
# G1 — ownership gate runs BEFORE path resolution
# ===========================================================================
g1_ownership_gate() {
    local wt action reason missing=""

    # A resolvable notes path is deliberately present: the gate must still skip,
    # proving ownership is decided before the filesystem is consulted.
    wt="$TMPD/g1-wt"
    write_notes "$wt" "sess-g1" >/dev/null

    resolve --caller issue-close-finalize --from-session --worktree "$(nodepath "$wt")"
    action="$(jfield "$RESOLVE_OUT" action)"
    reason="$(jfield "$RESOLVE_OUT" skipReason)"
    [ "$action" = "skip" ] || missing="$missing from-session-action=$action"
    [ "$reason" = "owned-by-session-close" ] || missing="$missing from-session-reason=$reason"
    [ "$RESOLVE_RC" = "0" ] || missing="$missing from-session-rc=$RESOLVE_RC"

    # Same caller WITHOUT --from-session: this run is its own, so the
    # ownership skip must not fire.
    resolve --caller issue-close-finalize --issue 42 --worktree "$(nodepath "$wt")"
    reason="$(jfield "$RESOLVE_OUT" skipReason)"
    [ "$reason" = "owned-by-session-close" ] && missing="$missing standalone-wrongly-skipped"

    # The other two callers always pass the ownership gate.
    local c
    for c in worktree-end session-close; do
        resolve --caller "$c" --worktree "$(nodepath "$wt")"
        reason="$(jfield "$RESOLVE_OUT" skipReason)"
        [ "$reason" = "owned-by-session-close" ] && missing="$missing $c-wrongly-skipped"
    done

    if [ -z "$missing" ]; then
        pass "G1a: --caller issue-close-finalize --from-session skips as owned-by-session-close, before path resolution"
    else
        fail "G1a: ownership gate wrong" "$missing (last out=$RESOLVE_OUT)"
    fi

    # Unknown / missing caller is an unusable invocation → exit 1.
    local bad=""
    resolve --caller not-a-caller --worktree "$(nodepath "$wt")"
    [ "$RESOLVE_RC" = "1" ] || bad="$bad unknown-caller-rc=$RESOLVE_RC"
    resolve --worktree "$(nodepath "$wt")"
    [ "$RESOLVE_RC" = "1" ] || bad="$bad missing-caller-rc=$RESOLVE_RC"
    # Control: without this, G1b would pass merely because `resolve` itself is
    # unrecognized and every invocation exits 1.
    resolve --caller worktree-end --worktree "$(nodepath "$wt")"
    [ "$RESOLVE_RC" = "0" ] || bad="$bad valid-caller-rc=$RESOLVE_RC"
    if [ -z "$bad" ]; then
        pass "G1b: unknown and missing --caller both exit 1"
    else
        fail "G1b: caller validation wrong" "$bad"
    fi
}

# ===========================================================================
# G2 — each of the five resolution branches: full tuple + precedence
# ===========================================================================

# 1. worktree — highest priority; every lower candidate is present in the fixture.
g2_branch_worktree() {
    local sid="sess-g2a" wt notes
    wt="$TMPD/g2-worktree"
    notes="$(write_notes "$wt" "$sid")"

    # Lower-priority decoys for the same session: env-json (2), notes-backup (3),
    # backup-branch (4) and intent-scan (5).
    local decoy="$TMPD/g2a-decoy"
    write_notes "$decoy" "$sid" >/dev/null
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({NOTES_BACKUP_PATH: process.argv[2]}), "utf8");' \
        -- "$PLANS_DIR/$sid-final-report-env.json" "$(nodepath "$decoy/WORKTREE_NOTES.md")"
    write_notes "$PLANS_DIR/$sid-notes-backup" "$sid" >/dev/null
    write_notes "$MAIN_ROOT/.worktree-backup/feature/g2a" "$sid" >/dev/null
    printf '%s\n' '# Intent' '' '## Issues' '- #2001' > "$PLANS_DIR/$sid-intent.md"

    resolve --caller worktree-end --worktree "$(nodepath "$wt")" \
            --session-id "$sid" --issue 2001 --pr-branch "feature/g2a" \
            --main-root "$(nodepath "$MAIN_ROOT")"
    assert_resolution "G2.1: --worktree resolves via 'worktree' and beats all four lower candidates" \
        "worktree" "$notes"
}

# 2. env-json — beats notes-backup-dir (3) for the same session.
g2_branch_env_json() {
    local sid="sess-g2b" dir notes
    dir="$TMPD/g2-envjson"
    notes="$(write_notes "$dir" "$sid")"
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({NOTES_BACKUP_PATH: process.argv[2]}), "utf8");' \
        -- "$PLANS_DIR/$sid-final-report-env.json" "$notes"
    # Lower-priority decoy.
    write_notes "$PLANS_DIR/$sid-notes-backup" "$sid" >/dev/null

    resolve --caller session-close --session-id "$sid"
    assert_resolution "G2.2: NOTES_BACKUP_PATH resolves via 'env-json' and beats the notes-backup dir" \
        "env-json" "$notes"
}

# 3. notes-backup-dir — reached when env JSON is corrupt; beats backup-branch-dir.
g2_branch_notes_backup_dir() {
    local sid="sess-g2c" notes
    notes="$(write_notes "$PLANS_DIR/$sid-notes-backup" "$sid")"
    # Env JSON deliberately corrupt: the chain must fall through, not abort.
    printf '%s' '{not json' > "$PLANS_DIR/$sid-final-report-env.json"
    # Lower-priority decoy.
    write_notes "$MAIN_ROOT/.worktree-backup/feature/g2c" "$sid" >/dev/null

    resolve --caller session-close --session-id "$sid" \
            --pr-branch "feature/g2c" --main-root "$(nodepath "$MAIN_ROOT")"
    assert_resolution "G2.3: corrupt env JSON falls through to 'notes-backup-dir', which beats backup-branch-dir" \
        "notes-backup-dir" "$notes"
}

# 4. backup-branch-dir — the standalone issue-close-finalize main route; beats intent-scan.
g2_branch_backup_branch_dir() {
    local branch="feature/np-g2d" sid="sess-g2d" notes
    notes="$(write_notes "$MAIN_ROOT/.worktree-backup/$branch" "$sid")"
    # Lower-priority decoy: an intent that also points at issue 77.
    printf '%s\n' '# Intent' '' '## Issues' '- #77' > "$PLANS_DIR/$sid-intent.md"
    write_notes "$PLANS_DIR/$sid-notes-backup" "$sid" >/dev/null

    resolve --caller issue-close-finalize --issue 77 \
            --pr-branch "$branch" --main-root "$(nodepath "$MAIN_ROOT")"
    assert_resolution "G2.4: <main-root>/.worktree-backup/<branch>/ resolves via 'backup-branch-dir' and beats intent-scan" \
        "backup-branch-dir" "$notes"
}

# 5. intent-scan — last resort: only --issue is known. No lower candidate exists.
g2_branch_intent_scan() {
    local sid="sess-g2e" notes
    printf '%s\n' '# Intent' '' '## Issues' '- #918' '' '## Scope' '- x' \
        > "$PLANS_DIR/$sid-intent.md"
    notes="$(write_notes "$PLANS_DIR/$sid-notes-backup" "$sid")"

    resolve --caller issue-close-finalize --issue 918
    assert_resolution "G2.5: --issue alone resolves via 'intent-scan' to the session's notes backup" \
        "intent-scan" "$notes"
}

# ===========================================================================
# G3 — priority within the chain
# ===========================================================================
g3_worktree_beats_backup() {
    local sid="sess-g3a" wt notes
    wt="$TMPD/g3-wt"
    notes="$(write_notes "$wt" "$sid")"
    write_notes "$PLANS_DIR/$sid-notes-backup" "$sid" >/dev/null

    resolve --caller session-close --session-id "$sid" --worktree "$(nodepath "$wt")"
    assert_resolution "G3a: --worktree wins over an equally-valid backup path" "worktree" "$notes"
}

g3_newest_intent_wins() {
    local older="sess-g3-old" newer="sess-g3-new" notes
    printf '%s\n' '# Intent' '' '## Issues' '- #1234' > "$PLANS_DIR/$older-intent.md"
    write_notes "$PLANS_DIR/$older-notes-backup" "$older" >/dev/null
    # Make the mtime ordering unambiguous rather than relying on write order.
    node -e '
      const fs = require("fs");
      const old = new Date(Date.now() - 3600e3);
      fs.utimesSync(process.argv[1], old, old);
    ' -- "$PLANS_DIR/$older-intent.md"

    printf '%s\n' '# Intent' '' '## Issues' '- #1234' > "$PLANS_DIR/$newer-intent.md"
    notes="$(write_notes "$PLANS_DIR/$newer-notes-backup" "$newer")"

    resolve --caller issue-close-finalize --issue 1234
    assert_resolution "G3b: when two intents reference the same issue, the newest session wins" \
        "intent-scan" "$notes"
}

# ===========================================================================
# G4 — nothing resolvable is a skip, not an error
# ===========================================================================
g4_unresolved() {
    local missing="" action reason
    resolve --caller issue-close-finalize --issue 999999
    action="$(jfield "$RESOLVE_OUT" action)"
    reason="$(jfield "$RESOLVE_OUT" skipReason)"
    [ "$action" = "skip" ] || missing="$missing action=$action"
    [ "$reason" = "notes-path-unresolved" ] || missing="$missing skipReason=$reason"
    [ "$RESOLVE_RC" = "0" ] || missing="$missing rc=$RESOLVE_RC"
    if [ -z "$missing" ]; then
        pass "G4: unresolvable notes path → action=skip, skipReason=notes-path-unresolved, exit 0"
    else
        fail "G4: unresolved contract wrong" "$missing (out=$RESOLVE_OUT err=$RESOLVE_ERR)"
    fi
}

# ===========================================================================
# G5 — output contract: one line of JSON, absolute notesPath
# ===========================================================================
g5_output_contract() {
    local wt; wt="$TMPD/g5-wt"
    write_notes "$wt" "sess-g5" >/dev/null
    resolve --caller worktree-end --worktree "$(nodepath "$wt")"

    local missing="" lines action path abs
    lines="$(printf '%s' "$RESOLVE_OUT" | grep -c '' || true)"
    [ "$lines" = "1" ] || missing="$missing stdout-lines=$lines"
    action="$(jfield "$RESOLVE_OUT" action)"
    [ "$action" = "promote" ] || missing="$missing action=$action"
    path="$(jfield "$RESOLVE_OUT" notesPath)"
    case "$path" in
        *WORKTREE_NOTES.md) ;;
        *) missing="$missing basename=$path" ;;
    esac
    case "$path" in
        *..*) missing="$missing unnormalized-dotdot" ;;
    esac
    abs="$(node -e '
      const p = require("path");
      process.stdout.write(String(p.win32.isAbsolute(process.argv[1]) || p.posix.isAbsolute(process.argv[1])));
    ' -- "$path" 2>/dev/null)"
    [ "$abs" = "true" ] || missing="$missing not-absolute=$path"

    if [ -z "$missing" ]; then
        pass "G5: promote output is exactly one JSON line with an absolute, normalized notesPath ending in WORKTREE_NOTES.md"
    else
        fail "G5: output contract wrong" "$missing (out=$RESOLVE_OUT)"
    fi
}

# ===========================================================================
# G8 — intent-scan matches issue numbers EXACTLY
# ===========================================================================
# `#18` must not be found inside `#118`; a substring match would promote a
# different session's notes and file its findings under the wrong issue.
g8_intent_scan_no_substring_match() {
    local sid="sess-g8-118"
    printf '%s\n' '# Intent' '' '## Issues' '- #118' > "$PLANS_DIR/$sid-intent.md"
    write_notes "$PLANS_DIR/$sid-notes-backup" "$sid" >/dev/null

    resolve --caller issue-close-finalize --issue 18
    local action reason
    action="$(jfield "$RESOLVE_OUT" action)"
    reason="$(jfield "$RESOLVE_OUT" skipReason)"
    if [ "$action" = "skip" ] && [ "$reason" = "notes-path-unresolved" ]; then
        pass "G8a: --issue 18 does not match an intent that references #118 (no substring match)"
    else
        fail "G8a: substring match leaked" "action=$action reason=$reason out=$RESOLVE_OUT"
    fi

    # Control: the same fixture DOES resolve for the issue it really references.
    resolve --caller issue-close-finalize --issue 118
    assert_resolution "G8b: --issue 118 resolves the very fixture #18 was refused (control)" \
        "intent-scan" "$PLANS_DIR/$sid-notes-backup/WORKTREE_NOTES.md"
}

g8_malformed_issue_tokens() {
    local sid="sess-g8-bad" missing="" action
    printf '%s\n' '# Intent' '' '## Issues' '- #abc' '- ##19' '- #' '- 19' \
        > "$PLANS_DIR/$sid-intent.md"
    write_notes "$PLANS_DIR/$sid-notes-backup" "$sid" >/dev/null

    # `##19` is a malformed token, not a reference to issue 19; a naive
    # /#(\d+)/ scan would match it.
    resolve --caller issue-close-finalize --issue 19
    action="$(jfield "$RESOLVE_OUT" action)"
    [ "$action" = "skip" ] || missing="$missing hash-hash-19-matched(action=$action)"

    if [ -z "$missing" ]; then
        pass "G8c: malformed issue tokens (#abc, ##19, bare 19) are not treated as references"
    else
        fail "G8c: malformed token matched" "$missing (out=$RESOLVE_OUT)"
    fi
}

g8_duplicate_references() {
    local sid="sess-g8-dup" notes
    printf '%s\n' '# Intent' '' '## Issues' '- #4242' '- #4242' '' '## Scope' '- also #4242' \
        > "$PLANS_DIR/$sid-intent.md"
    notes="$(write_notes "$PLANS_DIR/$sid-notes-backup" "$sid")"

    resolve --caller issue-close-finalize --issue 4242
    assert_resolution "G8d: an intent referencing the same issue three times resolves once, normally" \
        "intent-scan" "$notes"
}

# Tie-break contract: equal mtimes must still produce ONE deterministic answer.
# The pinned rule is mtime descending, then filename descending — an unstable
# tie-break would make standalone finalize promote a different session's notes
# on a re-run.
g8_equal_mtime_tiebreak() {
    local a="sess-g8-aaa" b="sess-g8-zzz" missing="" r1 r2 r3
    printf '%s\n' '# Intent' '' '## Issues' '- #5150' > "$PLANS_DIR/$a-intent.md"
    printf '%s\n' '# Intent' '' '## Issues' '- #5150' > "$PLANS_DIR/$b-intent.md"
    write_notes "$PLANS_DIR/$a-notes-backup" "$a" >/dev/null
    write_notes "$PLANS_DIR/$b-notes-backup" "$b" >/dev/null
    node -e '
      const fs = require("fs");
      const t = new Date(Date.now() - 600e3);
      for (const f of process.argv.slice(1)) fs.utimesSync(f, t, t);
    ' -- "$PLANS_DIR/$a-intent.md" "$PLANS_DIR/$b-intent.md"

    resolve --caller issue-close-finalize --issue 5150; r1="$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")"
    resolve --caller issue-close-finalize --issue 5150; r2="$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")"
    resolve --caller issue-close-finalize --issue 5150; r3="$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")"

    [ "$r1" = "$r2" ] && [ "$r2" = "$r3" ] || missing="$missing non-deterministic($r1|$r2|$r3)"
    [ "$r1" = "$(norm_path "$PLANS_DIR/$b-notes-backup/WORKTREE_NOTES.md")" ] \
        || missing="$missing tiebreak-not-filename-descending(got=$r1)"

    if [ -z "$missing" ]; then
        pass "G8e: equal-mtime intents tie-break deterministically on filename (descending)"
    else
        fail "G8e: equal-mtime tie-break wrong" "$missing"
    fi
}

# An intent that matches but whose session has no notes backup at all must fall
# through quietly — not crash, not return a path that does not exist.
g8_intent_without_backup() {
    local sid="sess-g8-nobackup" missing="" action reason path
    printf '%s\n' '# Intent' '' '## Issues' '- #6060' > "$PLANS_DIR/$sid-intent.md"

    resolve --caller issue-close-finalize --issue 6060
    action="$(jfield "$RESOLVE_OUT" action)"
    reason="$(jfield "$RESOLVE_OUT" skipReason)"
    path="$(jfield "$RESOLVE_OUT" notesPath)"
    [ "$RESOLVE_RC" = "0" ] || missing="$missing rc=$RESOLVE_RC"
    [ "$action" = "skip" ] || missing="$missing action=$action"
    [ "$reason" = "notes-path-unresolved" ] || missing="$missing skipReason=$reason"
    [ "$path" = "(absent)" ] || missing="$missing notesPath-emitted=$path"

    if [ -z "$missing" ]; then
        pass "G8f: an intent match with no notes backup skips as unresolved (exit 0, no phantom path)"
    else
        fail "G8f: missing-backup fallthrough wrong" "$missing (out=$RESOLVE_OUT err=$RESOLVE_ERR)"
    fi
}

g1_ownership_gate
g2_branch_worktree
g2_branch_env_json
g2_branch_notes_backup_dir
g2_branch_backup_branch_dir
g2_branch_intent_scan
g3_worktree_beats_backup
g3_newest_intent_wins
g4_unresolved
g5_output_contract
g8_intent_scan_no_substring_match
g8_malformed_issue_tokens
g8_duplicate_references
g8_equal_mtime_tiebreak
g8_intent_without_backup

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
