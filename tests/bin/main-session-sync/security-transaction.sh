# Tests: install/linux/session-sync-init.sh
# Tags: bin, install, git, session-sync, security, installer, scope:issue-specific
# Part of tests/bin/main-session-sync.sh; sourced after security.sh, whose _sec_run /
# _sec_temp_leftovers helpers it reuses.

# The transaction's staging names embed the installer's own $$, which no outside
# observer can predict. So these cases extract migrate_git_root and
# no_clobber_rename out of the installer and run them inside this shell, where
# $$ is ours: staging paths become addressable, and a failure can be injected at
# an exact rename instead of at a proxy like a `git init` shim.

echo ""
echo "=== session-sync-init.sh migration transaction (#1773) ==="

# TL3 gap (skills/_shared/test-design.md): TL2 — the two functions are lifted out
# of the shipped script and driven here, so the installer's own wiring is assumed
# rather than run. Not covered: that the installer calls migrate_git_root on the
# real pre-migration layout and honors its status; that the live process's $$
# produces the staging names Phase 0 scans for; and the real filesystem failures
# behind the injected ones — a cross-device `mv` degrading to copy+unlink, an
# NTFS/SMB sharing violation on an open `.git`, a case-insensitive volume, and a
# crash between Phase 1b and Phase 2 leaving staging names for the next run.
# Mitigation: checked at WORKFLOW_USER_VERIFIED preflight, category installer.

SEC_TX_LIB="$TMPDIR_BASE/sec-tx-lib.sh"
SEC_TX_OK=true

# _sec_extract_fn <file> <name> — print a top-level `name() { ... }` definition,
# closing brace included. Column-0 anchored, matching the installer's style.
_sec_extract_fn() {
    awk -v fn="$2" '
        !inside && $0 ~ "^" fn "\\(\\) *\\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$1"
}

: > "$SEC_TX_LIB"
for sec_fn in no_clobber_rename migrate_git_root; do
    _sec_extract_fn "$SEC_INIT" "$sec_fn" >> "$SEC_TX_LIB"
    printf '\n' >> "$SEC_TX_LIB"
    if ! grep -qE "^$sec_fn\\(\\) *\\{" "$SEC_TX_LIB"; then
        fail "transaction: $sec_fn() is not defined in session-sync-init.sh"
        SEC_TX_OK=false
    fi
done

if [ "$SEC_TX_OK" = "true" ] && ! bash -n "$SEC_TX_LIB" 2>/dev/null; then
    fail "transaction: the extracted functions do not parse in isolation"
    SEC_TX_OK=false
fi
if [ "$SEC_TX_OK" = "true" ]; then
    # shellcheck disable=SC1090
    . "$SEC_TX_LIB"
    pass "transaction: migrate_git_root and no_clobber_rename extracted and loaded"
fi

# _sec_tx_state <dir> — compact signature of the three migrated names, so a
# before/after comparison covers both existence and content in one assertion.
_sec_tx_state() {
    for sec_n in .git/marker .gitignore .gitattributes; do
        printf '%s=%s;' "$sec_n" "$(cat "$1/$sec_n" 2>/dev/null || echo MISSING)"
    done
}

# _sec_tx_fixture <base> — the realistic layout: SRC is the claude dir, DST the
# projects dir nested inside it, both carrying all three names so every phase of
# the transaction has work to do.
_sec_tx_fixture() {
    SEC_TX_SRC="$1/.claude"
    SEC_TX_DST="$SEC_TX_SRC/projects"
    rm -rf "$1"
    mkdir -p "$SEC_TX_SRC/.git" "$SEC_TX_DST/.git"
    printf 'src-git\n' > "$SEC_TX_SRC/.git/marker"
    printf 'src-ignore\n' > "$SEC_TX_SRC/.gitignore"
    printf 'src-attrs\n' > "$SEC_TX_SRC/.gitattributes"
    printf 'dst-git\n' > "$SEC_TX_DST/.git/marker"
    printf 'dst-ignore\n' > "$SEC_TX_DST/.gitignore"
    printf 'dst-attrs\n' > "$SEC_TX_DST/.gitattributes"
}

if [ "$SEC_TX_OK" != "true" ]; then
    fail "transaction: Phase 0 stale-staging abort not verifiable (functions missing)"
    fail "transaction: no_clobber_rename false-success detection not verifiable"
    fail "transaction: rollback on a mid-Phase-1a failure not verifiable"
    fail "transaction: rollback on a mid-Phase-1b failure not verifiable"
    fail "transaction: rollback on a mid-Phase-2 failure not verifiable"
    fail "transaction: Phase 3 cleanup failure not verifiable"
else

# --- no_clobber_rename, happy path ---
echo "[security] no_clobber_rename moves when the destination is free"
SEC_NCR="$TMPDIR_BASE/ncr"
rm -rf "$SEC_NCR"
mkdir -p "$SEC_NCR"
printf 'payload\n' > "$SEC_NCR/from"
if no_clobber_rename "$SEC_NCR/from" "$SEC_NCR/to" && [ ! -e "$SEC_NCR/from" ] && [ "$(cat "$SEC_NCR/to")" = "payload" ]; then
    pass "no_clobber_rename: renames and reports success"
else
    fail "no_clobber_rename: failed to rename onto a free destination"
fi

# --- no_clobber_rename, occupied destination ---
# The destination must survive untouched and `from` must stay put, so the caller
# can safely leave the name off its staged_* list.
echo "[security] no_clobber_rename refuses an occupied destination"
rm -rf "$SEC_NCR"
mkdir -p "$SEC_NCR"
printf 'payload\n' > "$SEC_NCR/from"
printf 'incumbent\n' > "$SEC_NCR/to"
SEC_NCR_RC=0
no_clobber_rename "$SEC_NCR/from" "$SEC_NCR/to" || SEC_NCR_RC=$?
if [ "$SEC_NCR_RC" -eq 0 ]; then
    fail "no_clobber_rename: reported success over an occupied destination"
elif [ ! -e "$SEC_NCR/from" ]; then
    fail "no_clobber_rename: consumed the source while reporting failure"
elif [ "$(cat "$SEC_NCR/to")" != "incumbent" ]; then
    fail "no_clobber_rename: clobbered the occupied destination"
else
    pass "no_clobber_rename: refused, source kept, destination intact"
fi

# --- no_clobber_rename under an mv that lies ---
# GNU `mv -n` exits 0 when it skips, so an exit-code-only implementation would
# call this a success. The destination is deliberately FREE here: a pre-existing
# destination would be caught by the pre-check alone and would prove nothing
# about the post-condition. The stub moves nothing and exits 0 — only verifying
# that `from` is gone can detect it.
echo "[security] no_clobber_rename ignores a lying exit code"
SEC_SHIM="$TMPDIR_BASE/sec-shim-bin"
rm -rf "$SEC_SHIM"
mkdir -p "$SEC_SHIM"
printf '#!/bin/sh\nexit 0\n' > "$SEC_SHIM/mv"
chmod +x "$SEC_SHIM/mv"
rm -rf "$SEC_NCR"
mkdir -p "$SEC_NCR"
printf 'payload\n' > "$SEC_NCR/from"
SEC_PATH_SAVED="$PATH"
PATH="$SEC_SHIM:$PATH"
SEC_NCR_RC=0
no_clobber_rename "$SEC_NCR/from" "$SEC_NCR/to" || SEC_NCR_RC=$?
PATH="$SEC_PATH_SAVED"
if [ "$SEC_NCR_RC" -eq 0 ]; then
    fail "no_clobber_rename: trusted a no-op mv that exited 0"
elif [ ! -f "$SEC_NCR/from" ]; then
    fail "no_clobber_rename: source vanished under the stub mv"
else
    pass "no_clobber_rename: post-condition caught the no-op mv"
fi

# --- Phase 0: stale staging paths abort before anything moves ---
# A leftover staging name means a crashed run, a recycled PID, or a concurrent
# installer. Fail-closed: abort, change nothing, and do not tidy it away either —
# deleting it would destroy the evidence the user needs.
echo "[security] Phase 0 aborts on a stale staging path"
_sec_tx_fixture "$TMPDIR_BASE/tx-stale"
printf 'stale\n' > "$SEC_TX_DST/.gitignore.old.$$"
SEC_TX_SRC_BEFORE=$(_sec_tx_state "$SEC_TX_SRC")
SEC_TX_DST_BEFORE=$(_sec_tx_state "$SEC_TX_DST")
SEC_TX_RC=0
migrate_git_root "$SEC_TX_SRC" "$SEC_TX_DST" || SEC_TX_RC=$?
if [ "$SEC_TX_RC" -eq 0 ]; then
    fail "Phase 0: migration proceeded despite a stale staging path"
elif [ "$(_sec_tx_state "$SEC_TX_SRC")" != "$SEC_TX_SRC_BEFORE" ]; then
    fail "Phase 0: SRC was modified by an aborted transaction"
elif [ "$(_sec_tx_state "$SEC_TX_DST")" != "$SEC_TX_DST_BEFORE" ]; then
    fail "Phase 0: DST was modified by an aborted transaction"
elif [ ! -f "$SEC_TX_DST/.gitignore.old.$$" ]; then
    fail "Phase 0: the stale staging path was silently deleted instead of reported"
else
    pass "Phase 0: aborted with both trees and the stale evidence untouched"
fi

# --- Failure injection at an exact rename ---
# With all three names present on both sides the call order is fixed: 1-3 are
# Phase 1a, 4-6 Phase 1b, 7-9 Phase 2. Failing the 2nd-or-later rename of a
# phase leaves earlier ones already committed, which is what rollback must undo.
eval "_sec_tx_real_ncr() $(declare -f no_clobber_rename | tail -n +2)"
_SEC_NCR_N=0
_SEC_NCR_FAIL_AT=0
no_clobber_rename() {
    _SEC_NCR_N=$((_SEC_NCR_N + 1))
    if [ "$_SEC_NCR_FAIL_AT" -gt 0 ] && [ "$_SEC_NCR_N" -eq "$_SEC_NCR_FAIL_AT" ]; then
        return 1
    fi
    _sec_tx_real_ncr "$@"
}

# _sec_tx_rollback_case <label> <fail-at-rename-number>
_sec_tx_rollback_case() {
    sec_label="$1"
    _sec_tx_fixture "$TMPDIR_BASE/tx-$sec_label"
    sec_src_before=$(_sec_tx_state "$SEC_TX_SRC")
    sec_dst_before=$(_sec_tx_state "$SEC_TX_DST")
    _SEC_NCR_N=0
    _SEC_NCR_FAIL_AT="$2"
    sec_rc=0
    migrate_git_root "$SEC_TX_SRC" "$SEC_TX_DST" || sec_rc=$?
    _SEC_NCR_FAIL_AT=0
    sec_left="$(_sec_temp_leftovers "$SEC_TX_SRC")$(_sec_temp_leftovers "$SEC_TX_DST")"
    if [ "$sec_rc" -eq 0 ]; then
        fail "rollback/$sec_label: migration reported success despite a failed rename"
    elif [ "$(_sec_tx_state "$SEC_TX_SRC")" != "$sec_src_before" ]; then
        fail "rollback/$sec_label: SRC not restored [$sec_src_before] -> [$(_sec_tx_state "$SEC_TX_SRC")]"
    elif [ "$(_sec_tx_state "$SEC_TX_DST")" != "$sec_dst_before" ]; then
        fail "rollback/$sec_label: DST not restored [$sec_dst_before] -> [$(_sec_tx_state "$SEC_TX_DST")]"
    elif [ -n "$sec_left" ]; then
        fail "rollback/$sec_label: staging artifact survived: $sec_left"
    else
        pass "rollback/$sec_label: both trees restored, no staging artifact left"
    fi
}

# Phase 1a is the phase the other two cases cannot reach: it stages DST's own
# incumbents, so a failure here must undo moves made to the destination tree
# before Phase 1b has touched SRC at all. Failing rename 2 leaves exactly one
# incumbent already staged — the state a rollback that only handles SRC misses.
echo "[security] rollback from a mid-Phase-1a failure"
_sec_tx_rollback_case "phase1a" 2

echo "[security] rollback from a mid-Phase-1b failure"
_sec_tx_rollback_case "phase1b" 5

echo "[security] rollback from a mid-Phase-2 failure"
_sec_tx_rollback_case "phase2" 8

# --- Success path of the transaction itself ---
# The complement of the rollback cases (Pattern 4): with no injection the three
# names must end up in DST under their bare final names carrying SRC's content,
# SRC must be empty of them, and the staged incumbents must be gone.
echo "[security] transaction success leaves bare final names only"
_sec_tx_fixture "$TMPDIR_BASE/tx-success"
_SEC_NCR_N=0
_SEC_NCR_FAIL_AT=0
SEC_TX_RC=0
migrate_git_root "$SEC_TX_SRC" "$SEC_TX_DST" || SEC_TX_RC=$?
SEC_TX_LEFT="$(_sec_temp_leftovers "$SEC_TX_SRC")$(_sec_temp_leftovers "$SEC_TX_DST")"
SEC_TX_SRC_LEFT=$(ls -A "$SEC_TX_SRC" 2>/dev/null | grep -E '^\.git(ignore|attributes)?$' | tr '\n' ' ' || true)
if [ "$SEC_TX_RC" -ne 0 ]; then
    fail "transaction success: migrate_git_root failed on a clean fixture (rc=$SEC_TX_RC)"
elif [ "$(_sec_tx_state "$SEC_TX_DST")" != ".git/marker=src-git;.gitignore=src-ignore;.gitattributes=src-attrs;" ]; then
    fail "transaction success: DST does not carry SRC's content under bare names"
elif [ -n "$SEC_TX_SRC_LEFT" ]; then
    fail "transaction success: SRC still holds $SEC_TX_SRC_LEFT"
elif [ -n "$SEC_TX_LEFT" ]; then
    fail "transaction success: staging artifact survived: $SEC_TX_LEFT"
else
    pass "transaction success: three bare names in DST, nothing left in SRC"
fi

# --- Phase 3 cleanup failure does not change the verdict ---
# detail.md D: deleting the staged `.old.$$` incumbents is best-effort — the data
# is already migrated at that point, so an undeletable leftover is litter, not a
# failed migration. Reporting failure here would be the worse bug: the caller
# would roll back or re-run over a tree that is already correct. The `rm` stub
# refuses only paths carrying `.old.`, so the fixture teardown is unaffected.
echo "[security] Phase 3 cleanup failure keeps the success verdict"
SEC_RM_REAL=$(command -v rm)
SEC_RM_SHIM="$TMPDIR_BASE/sec-rm-shim"
rm -rf "$SEC_RM_SHIM"
mkdir -p "$SEC_RM_SHIM"
printf '#!/bin/sh\nfor a in "$@"; do\n  case "$a" in *.old.*) exit 1 ;; esac\ndone\nexec %s "$@"\n' "$SEC_RM_REAL" > "$SEC_RM_SHIM/rm"
chmod +x "$SEC_RM_SHIM/rm"
_sec_tx_fixture "$TMPDIR_BASE/tx-phase3"
_SEC_NCR_N=0
_SEC_NCR_FAIL_AT=0
SEC_PATH_SAVED="$PATH"
PATH="$SEC_RM_SHIM:$PATH"
SEC_TX_RC=0
migrate_git_root "$SEC_TX_SRC" "$SEC_TX_DST" || SEC_TX_RC=$?
PATH="$SEC_PATH_SAVED"
SEC_TX_TMP_LEFT=$(ls -d "$SEC_TX_SRC"/*.migrate-tmp.* "$SEC_TX_DST"/*.migrate-tmp.* 2>/dev/null | head -1 || true)
SEC_TX_OLD_LEFT=$(ls -d "$SEC_TX_DST"/*.old.* 2>/dev/null | head -1 || true)
if [ "$SEC_TX_RC" -ne 0 ]; then
    fail "Phase 3: a best-effort cleanup failure turned a completed migration into a failure (rc=$SEC_TX_RC)"
elif [ "$(_sec_tx_state "$SEC_TX_DST")" != ".git/marker=src-git;.gitignore=src-ignore;.gitattributes=src-attrs;" ]; then
    fail "Phase 3: promotion was undone by the cleanup failure"
elif [ -n "$SEC_TX_TMP_LEFT" ]; then
    fail "Phase 3: a Phase-1b staging name survived promotion: $SEC_TX_TMP_LEFT"
elif [ -z "$SEC_TX_OLD_LEFT" ]; then
    fail "Phase 3: the undeletable incumbent vanished, so the stub never took effect"
else
    pass "Phase 3: success kept, promotion intact, residue confined to the .old staging name"
fi

fi
