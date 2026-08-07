#!/usr/bin/env bash
# tests/feature-530-notes-promotion-triage-flow/security-anchors.sh
# Tests: bin/worktree-notes-triage/resolve.js, hooks/lib/worktree-notes.js
# Tags: notes-promotion, worktree-notes, triage, security, path-traversal, shell-metachar, TL2, scope:issue-specific
#
# A — the two *directory* flags, --worktree and --main-root.
#
# security.sh covers the two attacker-shaped *identifier* flags (--session-id,
# --pr-branch). The directory flags are the symmetric other half (CPR-ORTH) and are
# attacked differently:
#
#   A1/A2  shell metacharacters. The resolved notesPath is interpolated into a
#          shell command by the caller (notes-promotion.md NP-5/NP-8), so a
#          notes file living under a directory named `x;id` must never be handed
#          back as a promotable path — resolve must skip with notes-path-unsafe.
#   A3     anchor semantics for ABSOLUTE paths. --main-root is an anchor, not a
#          notes location: pointing it straight at a directory that holds a
#          WORKTREE_NOTES.md must not promote that file; only
#          <main-root>/.worktree-backup/<branch>/ counts.
#   A4     `..` inside an ABSOLUTE path. hasTraversal() screens the RAW argument,
#          so an absolute path is not exempt from the traversal check just
#          because it is rooted.
#
# Each attack case is paired with a control that differs only in the attacked
# character/segment, so a blanket-deny implementation cannot pass the file.
#
# TL3 gap (what this test does NOT catch):
# - Whether the SKILL.md callsites quote the notesPath when they interpolate it
#   into the Bash tool, i.e. whether notes-path-unsafe is the only thing standing
#   between a metachar path and execution. Only a live session shows that.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

A_LEAK="NPANCHOR-3d90b7-SECRET"

# node_sees <node-path> — true when node's fs can stat the file at exactly this
# path. Some metacharacters survive `mkdir` under MSYS but are unreachable
# through the Win32 API node uses (`|`), and cygpath rewrites others out of the
# string entirely. Either way the fixture is not the one the case describes, so
# the case must skip rather than assert against a sanitized or absent path.
node_sees() {
    node -e 'const fs=require("fs");try{process.exit(fs.statSync(process.argv[1]).isFile()?0:1)}catch(e){process.exit(1)}' \
        -- "$1" 2>/dev/null
}

# nodepath_keep <parent> <leaf> — node-facing path for <parent>/<leaf> with the
# leaf appended AFTER normalization. cygpath rewrites some metacharacters out of
# a path it is given whole (`wt|x` → `wtx`), which would hand the CLI a sanitized
# argument and make the case vacuous.
nodepath_keep() { printf '%s/%s' "$(nodepath "$1")" "$2"; }

# plant_notes <dir> — a notes file whose body carries the leak token.
plant_notes() {
    mkdir -p "$1" 2>/dev/null || return 1
    cat > "$1/WORKTREE_NOTES.md" <<EOF
# Worktree Notes
Branch: feature/anchor
Session-ID: sess-anchor

## BugsFound
- $A_LEAK

## RelatedTasks
- (none)

## NextTasks
- (none)

## History Notes
- (none)
EOF
}

# The metacharacter set screened by hooks/lib/worktree-notes.js hasShellMetachar.
# `$` covers `$(...)`; `(`/`)` alone are not screened and are not asserted here.
METACHARS='; | & ` $'

# ---------------------------------------------------------------------------
# A1 — --worktree under a directory whose name carries a shell metacharacter
# ---------------------------------------------------------------------------
a1_worktree_metachars() {
    local i=0 c dir np missing action reason
    for c in $METACHARS; do
        i=$((i + 1))
        dir="$TMPD/a1-$i/wt${c}x"
        np="$(nodepath_keep "$TMPD/a1-$i" "wt${c}x")"
        if ! plant_notes "$dir" || ! node_sees "$np/WORKTREE_NOTES.md"; then
            skip "A1[$c]: this environment cannot address '$c' inside a directory path"
            continue
        fi
        missing=""
        resolve --caller worktree-end --worktree "$np"
        action="$(jfield "$RESOLVE_OUT" action)"
        reason="$(jfield "$RESOLVE_OUT" skipReason)"
        [ "$RESOLVE_RC" = "0" ] || missing="$missing rc=$RESOLVE_RC"
        [ "$action" = "skip" ] || missing="$missing action=$action"
        [ "$reason" = "notes-path-unsafe" ] || missing="$missing reason=$reason"
        [ "$(jfield "$RESOLVE_OUT" notesPath)" = "(absent)" ] || missing="$missing notesPath-returned"
        case "$RESOLVE_OUT$RESOLVE_ERR" in *"$A_LEAK"*) missing="$missing leaked-body" ;; esac

        if [ -z "$missing" ]; then
            pass "A1: --worktree holding '$c' is skipped as notes-path-unsafe, not returned for interpolation"
        else
            fail "A1: metachar '$c' in --worktree not screened" "$missing (out=$RESOLVE_OUT err=$RESOLVE_ERR)"
        fi
    done
}

# Control: the identical layout under a metachar-free name promotes. Without
# this, A1 would also pass if --worktree were broken outright.
a1c_clean_worktree_promotes() {
    local dir="$TMPD/a1c/wt-x" missing=""
    plant_notes "$dir"
    resolve --caller worktree-end --worktree "$(nodepath "$dir")"
    [ "$(jfield "$RESOLVE_OUT" action)" = "promote" ] || missing="$missing action=$(jfield "$RESOLVE_OUT" action)"
    [ "$(jfield "$RESOLVE_OUT" resolvedVia)" = "worktree" ] || missing="$missing via=$(jfield "$RESOLVE_OUT" resolvedVia)"
    [ "$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")" = "$(norm_path "$dir/WORKTREE_NOTES.md")" ] \
        || missing="$missing path=$(jfield "$RESOLVE_OUT" notesPath)"

    if [ -z "$missing" ]; then
        pass "A1c: control — the same layout without a metacharacter promotes, so A1's skips come from the screen"
    else
        fail "A1c: clean --worktree did not promote" "$missing (out=$RESOLVE_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# A2 — --main-root under a directory whose name carries a shell metacharacter
# ---------------------------------------------------------------------------
a2_main_root_metachars() {
    local i=0 c root np missing action reason
    for c in $METACHARS; do
        i=$((i + 1))
        root="$TMPD/a2-$i/root${c}x"
        np="$(nodepath_keep "$TMPD/a2-$i" "root${c}x")"
        if ! plant_notes "$root/.worktree-backup/feature/anchor" \
           || ! node_sees "$np/.worktree-backup/feature/anchor/WORKTREE_NOTES.md"; then
            skip "A2[$c]: this environment cannot address '$c' inside a directory path"
            continue
        fi
        missing=""
        resolve --caller worktree-end --main-root "$np" --pr-branch feature/anchor
        action="$(jfield "$RESOLVE_OUT" action)"
        reason="$(jfield "$RESOLVE_OUT" skipReason)"
        [ "$RESOLVE_RC" = "0" ] || missing="$missing rc=$RESOLVE_RC"
        [ "$action" = "skip" ] || missing="$missing action=$action"
        [ "$reason" = "notes-path-unsafe" ] || missing="$missing reason=$reason"
        case "$RESOLVE_OUT$RESOLVE_ERR" in *"$A_LEAK"*) missing="$missing leaked-body" ;; esac

        if [ -z "$missing" ]; then
            pass "A2: --main-root holding '$c' is skipped as notes-path-unsafe on the backup-branch-dir branch"
        else
            fail "A2: metachar '$c' in --main-root not screened" "$missing (out=$RESOLVE_OUT err=$RESOLVE_ERR)"
        fi
    done
}

a2c_clean_main_root_promotes() {
    local root="$TMPD/a2c/root-x" missing=""
    plant_notes "$root/.worktree-backup/feature/anchor"
    resolve --caller worktree-end --main-root "$(nodepath "$root")" --pr-branch feature/anchor
    [ "$(jfield "$RESOLVE_OUT" action)" = "promote" ] || missing="$missing action=$(jfield "$RESOLVE_OUT" action)"
    [ "$(jfield "$RESOLVE_OUT" resolvedVia)" = "backup-branch-dir" ] || missing="$missing via=$(jfield "$RESOLVE_OUT" resolvedVia)"

    if [ -z "$missing" ]; then
        pass "A2c: control — the same --main-root layout without a metacharacter resolves via backup-branch-dir"
    else
        fail "A2c: clean --main-root did not promote" "$missing (out=$RESOLVE_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# A3 — an absolute --main-root is an anchor, not a notes location
# ---------------------------------------------------------------------------
# --main-root is caller-supplied, so it is honored as an absolute path — but only
# through the <main-root>/.worktree-backup/<branch>/ segments. Handing it a
# directory that already contains a WORKTREE_NOTES.md must resolve nothing.
a3_main_root_is_anchor_only() {
    local root="$TMPD/a3/root" missing=""
    plant_notes "$root"                     # decoy: sits directly at --main-root
    resolve --caller worktree-end --main-root "$(nodepath "$root")" --pr-branch feature/anchor
    [ "$RESOLVE_RC" = "0" ] || missing="$missing rc=$RESOLVE_RC"
    [ "$(jfield "$RESOLVE_OUT" action)" = "skip" ] || missing="$missing action=$(jfield "$RESOLVE_OUT" action)"
    [ "$(jfield "$RESOLVE_OUT" skipReason)" = "notes-path-unresolved" ] \
        || missing="$missing reason=$(jfield "$RESOLVE_OUT" skipReason)"
    [ "$(jfield "$RESOLVE_OUT" notesPath)" = "(absent)" ] || missing="$missing notesPath=$(jfield "$RESOLVE_OUT" notesPath)"
    case "$RESOLVE_OUT$RESOLVE_ERR" in *"$A_LEAK"*) missing="$missing leaked-body" ;; esac

    # Same root, same branch — now with the anchor segments present. The only
    # difference is the .worktree-backup/<branch>/ path, so A3's skip is the
    # anchor requirement and not a dead branch.
    plant_notes "$root/.worktree-backup/feature/anchor"
    resolve --caller worktree-end --main-root "$(nodepath "$root")" --pr-branch feature/anchor
    [ "$(jfield "$RESOLVE_OUT" action)" = "promote" ] || missing="$missing control-action=$(jfield "$RESOLVE_OUT" action)"
    [ "$(norm_path "$(jfield "$RESOLVE_OUT" notesPath)")" = "$(norm_path "$root/.worktree-backup/feature/anchor/WORKTREE_NOTES.md")" ] \
        || missing="$missing control-path=$(jfield "$RESOLVE_OUT" notesPath)"

    if [ -z "$missing" ]; then
        pass "A3: an absolute --main-root only resolves through .worktree-backup/<branch>/ — a notes file sitting at the root itself is not promoted"
    else
        fail "A3: --main-root treated as a notes location" "$missing (out=$RESOLVE_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# A4 — `..` inside an ABSOLUTE path is still traversal
# ---------------------------------------------------------------------------
# hasTraversal() screens the raw argument before path.resolve() collapses it, so
# an absolute path is not exempt. Both flags must behave the same way (CPR-ORTH).
a4_absolute_traversal_segments() {
    local base="$TMPD/a4" abs missing=""
    plant_notes "$base/wt"
    plant_notes "$base/root/.worktree-backup/feature/anchor"
    # Normalize the base ONCE and append the `..` by hand: cygpath collapses the
    # segment, so nodepath "$base/wt/../wt" would hand the CLI a clean path and
    # the case would assert nothing.
    abs="$(nodepath "$base")"

    # (1) --worktree: absolute, exists, but routed through a `..` segment.
    resolve --caller worktree-end --worktree "$abs/wt/../wt"
    [ "$RESOLVE_RC" = "0" ] || missing="$missing wt-rc=$RESOLVE_RC"
    [ "$(jfield "$RESOLVE_OUT" action)" = "skip" ] || missing="$missing wt-action=$(jfield "$RESOLVE_OUT" action)"
    [ "$(jfield "$RESOLVE_OUT" skipReason)" = "notes-path-unresolved" ] \
        || missing="$missing wt-reason=$(jfield "$RESOLVE_OUT" skipReason)"
    case "$RESOLVE_OUT$RESOLVE_ERR" in *"$A_LEAK"*) missing="$missing wt-leaked-body" ;; esac

    # (2) --main-root: same shape, other flag.
    resolve --caller worktree-end --main-root "$abs/root/../root" --pr-branch feature/anchor
    [ "$(jfield "$RESOLVE_OUT" action)" = "skip" ] || missing="$missing root-action=$(jfield "$RESOLVE_OUT" action)"
    [ "$(jfield "$RESOLVE_OUT" skipReason)" = "notes-path-unresolved" ] \
        || missing="$missing root-reason=$(jfield "$RESOLVE_OUT" skipReason)"
    case "$RESOLVE_OUT$RESOLVE_ERR" in *"$A_LEAK"*) missing="$missing root-leaked-body" ;; esac

    # Controls: the same two invocations with the `..` segment removed resolve.
    # This is what makes (1) and (2) assertions about the segment, not the path.
    resolve --caller worktree-end --worktree "$abs/wt"
    [ "$(jfield "$RESOLVE_OUT" action)" = "promote" ] || missing="$missing wt-control=$(jfield "$RESOLVE_OUT" action)"
    resolve --caller worktree-end --main-root "$abs/root" --pr-branch feature/anchor
    [ "$(jfield "$RESOLVE_OUT" action)" = "promote" ] || missing="$missing root-control=$(jfield "$RESOLVE_OUT" action)"

    if [ -z "$missing" ]; then
        pass "A4: a '..' segment inside an absolute --worktree/--main-root is refused even though the collapsed path exists"
    else
        fail "A4: absolute traversal accepted" "$missing"
    fi
}

a1_worktree_metachars
a1c_clean_worktree_promotes
a2_main_root_metachars
a2c_clean_main_root_promotes
a3_main_root_is_anchor_only
a4_absolute_traversal_segments

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
