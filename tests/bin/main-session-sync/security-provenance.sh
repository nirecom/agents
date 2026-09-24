# Tests: install/linux/session-sync-init.sh
# Tags: bin, install, git, session-sync, security, installer, scope:issue-specific
# Part of tests/main-session-sync.sh; sourced after security.sh, whose _sec_run /
# _sec_old_root / _sec_temp_leftovers helpers it reuses, and after
# security-remote.sh, whose _sec_cfg_layout / _sec_cfg_run build the relocated
# `.env` layout the config-derived rows at the bottom of this file need.

echo ""
echo "=== session-sync-init.sh migration provenance (#1773) ==="

# detail.md A1: a pre-existing $CLAUDE_DIR/.git may be migrated only when an
# expected origin exists AND the old repo's origin matches it. Expected origin
# resolves as explicit --expected-origin > the validated --remote-url > absent.
# Absent is fail-closed, because an unidentified repo under ~/.claude may be the
# user's own unrelated work and migration destroys it.

SEC_PROV_A="https://example.invalid/provenance-a.git"
SEC_PROV_B="https://example.invalid/provenance-b.git"
SEC_PROV_DEFAULT="git@github.com:nirecom/agent-sessions.git"

# _SEC_PROV_EXE — when non-empty, the accept/reject helpers below run that
# installer copy instead of the shipped script. The config-derived rows need a
# relocated layout so their `.env` is the one under test, and they assert exactly
# what the explicit-flag rows assert; the indirection buys that reuse without a
# second copy of the assertions (CPR-SSOT).
_SEC_PROV_EXE=""

# _sec_prov_run <installer-args...>
_sec_prov_run() {
    if [ -n "$_SEC_PROV_EXE" ]; then
        _sec_cfg_run "$_SEC_PROV_EXE" "$@"
    else
        _sec_run "$@"
    fi
}

# _sec_prov_reject <name> <old-origin|""> <installer-args...>
# Negative assertion (protection-fix-tests.md Pattern 1) plus the C3 ordering
# guard: a refusal must leave $PROJECTS_DIR uncreated, because provenance is
# evaluated before the first mkdir.
# "Unchanged" is proved on content, not on HEAD: an uncommitted overwrite of the
# working tree leaves HEAD exactly where it was, so every tracked file's bytes
# and a clean `status --porcelain` — before and after — carry the claim.
_sec_prov_reject() {
    sec_name="$1"; shift
    sec_origin="$1"; shift
    sec_claude="$TMPDIR_BASE/prov-$sec_name/.claude"
    _sec_old_root "$sec_claude" "$sec_origin"
    sec_head_before="$_SEC_OLD_HEAD"
    sec_snap_before=$(_sec_tracked_snapshot "$sec_claude")
    sec_status_before=$(_sec_worktree_status "$sec_claude")

    _sec_prov_run --claude-dir "$sec_claude" "$@"

    sec_head_after=$(git -C "$sec_claude" rev-parse --verify HEAD 2>/dev/null || echo "none")
    sec_snap_after=$(_sec_tracked_snapshot "$sec_claude")
    sec_status_after=$(_sec_worktree_status "$sec_claude")
    sec_leftover="$(_sec_temp_leftovers "$sec_claude")$(_sec_temp_leftovers "$sec_claude/projects")"
    if [ -n "$sec_status_before" ]; then
        fail "provenance/$sec_name: the fixture was already dirty before the run ($sec_status_before)"
    elif [ "$_SEC_RC" -eq 0 ]; then
        fail "provenance/$sec_name: migration was allowed without matching provenance"
    elif [ -e "$sec_claude/projects" ]; then
        fail "provenance/$sec_name: \$PROJECTS_DIR was created before the provenance verdict"
    elif [ ! -d "$sec_claude/.git" ] || [ "$sec_head_after" != "$sec_head_before" ]; then
        fail "provenance/$sec_name: the old repo was moved or damaged by a rejected run"
    elif [ ! -f "$sec_claude/.gitignore" ] || [ ! -f "$sec_claude/.gitattributes" ]; then
        fail "provenance/$sec_name: the old seed files were removed by a rejected run"
    elif [ "$sec_snap_after" != "$sec_snap_before" ]; then
        fail "provenance/$sec_name: the tracked working tree changed under a rejected run"
    elif [ -n "$sec_status_after" ]; then
        fail "provenance/$sec_name: a rejected run left working-tree residue ($sec_status_after)"
    elif [ -n "$sec_leftover" ]; then
        fail "provenance/$sec_name: transaction artifact left behind: $sec_leftover"
    else
        pass "provenance/$sec_name: refused with the old repo byte-identical and clean"
    fi
}

# _sec_prov_accept <name> <old-origin> <installer-args...>
# The other direction (Pattern 4): a verified repo must actually migrate, and
# migrate whole — the final names in $PROJECTS_DIR are bare, never .bak, and the
# commit history proves the old repo moved rather than a new one being init'd.
# The restore step is scoped to the `projects` pathspec against the OLD root as
# work-tree, so the fixture's root-level `old-session.jsonl` is deliberately left
# where it is: relocating it into $PROJECTS_DIR would be the re-scattering bug —
# an unscoped restore, or one run with $PROJECTS_DIR as the work-tree, recreates
# exactly that copy. Both directions are asserted below.
_sec_prov_accept() {
    sec_name="$1"; shift
    sec_origin="$1"; shift
    sec_claude="$TMPDIR_BASE/prov-$sec_name/.claude"
    _sec_old_root "$sec_claude" "$sec_origin"
    sec_head_before="$_SEC_OLD_HEAD"

    _sec_prov_run --claude-dir "$sec_claude" "$@"

    sec_head_after=$(git -C "$sec_claude/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")
    sec_residue=$(ls -A "$sec_claude" 2>/dev/null | grep -E '^\.git(ignore|attributes)?(\.|$)' | tr '\n' ' ' || true)
    sec_leftover="$(_sec_temp_leftovers "$sec_claude")$(_sec_temp_leftovers "$sec_claude/projects")"
    if [ "$_SEC_RC" -ne 0 ]; then
        fail "provenance/$sec_name: a verified repo was refused (rc=$_SEC_RC, output: $_SEC_OUT)"
    elif [ "$sec_head_after" != "$sec_head_before" ]; then
        fail "provenance/$sec_name: \$PROJECTS_DIR/.git does not carry the old history ($sec_head_after)"
    elif [ -n "$sec_residue" ]; then
        fail "provenance/$sec_name: \$CLAUDE_DIR still holds git metadata: $sec_residue"
    elif [ ! -f "$sec_claude/old-session.jsonl" ]; then
        fail "provenance/$sec_name: a root-level tracked file was destroyed by the migration"
    elif [ -e "$sec_claude/projects/old-session.jsonl" ]; then
        fail "provenance/$sec_name: a root-level tracked file was re-scattered into \$PROJECTS_DIR"
    elif [ -n "$sec_leftover" ]; then
        fail "provenance/$sec_name: transaction artifact left behind: $sec_leftover"
    else
        pass "provenance/$sec_name: migrated with history intact and nothing left behind"
    fi
}

# Row 1 — expected origin absent. --no-remote resolves no URL, so nothing can be
# compared against; fail-closed even though the old repo is perfectly readable.
_sec_prov_reject "expected-absent" "$SEC_PROV_A" --no-remote

# Row 2 — expected origin present, old origin unreadable (the repo has none).
_sec_prov_reject "old-origin-missing" "" --expected-origin "$SEC_PROV_A" --no-remote

# Row 3 — expected origin present, old origin present but different.
_sec_prov_reject "old-origin-mismatch" "$SEC_PROV_B" --expected-origin "$SEC_PROV_A" --no-remote

# Row 4 — expected origin present and matching: the only accepting row.
_sec_prov_accept "explicit-match" "$SEC_PROV_A" --expected-origin "$SEC_PROV_A" --no-remote

# Priority: with no --expected-origin, the validated --remote-url stands in.
_sec_prov_accept "remote-url-standin" "git@example.com:repo.git" --remote-url "git@example.com:repo.git"

# Priority: an explicit --expected-origin outranks the resolved --remote-url.
# The old repo matches the explicit value only, so acceptance proves which one won.
_sec_prov_accept "explicit-outranks-remote" "$SEC_PROV_B" --remote-url "git@example.com:repo.git" --expected-origin "$SEC_PROV_B"

# The same pair inverted: matching the --remote-url is not enough once an
# explicit expected origin has been named. Without this row, an implementation
# that OR-ed the two candidates would pass the row above.
_sec_prov_reject "explicit-outranks-remote-inverse" "git@example.com:repo.git" --remote-url "git@example.com:repo.git" --expected-origin "$SEC_PROV_B"

# No old git root at all: provenance is not evaluated, so a plain --no-remote run
# still succeeds. Guards against the fail-closed rule leaking onto fresh installs.
echo "[security] no old git root means no provenance gate"
SEC_FRESH="$TMPDIR_BASE/prov-fresh/.claude"
mkdir -p "$SEC_FRESH"
_sec_run --claude-dir "$SEC_FRESH" --no-remote
if [ "$_SEC_RC" -eq 0 ] && [ -d "$SEC_FRESH/projects/.git" ]; then
    pass "fresh install unaffected by the provenance gate"
else
    fail "fresh install was blocked by the provenance gate (rc=$_SEC_RC, output: $_SEC_OUT)"
fi

# --- Config-derived expected origin (no explicit CLI remote/origin) ----------
# install.sh runs this script with neither flag, so on a real upgrade the value
# that decides whether ~/.claude/.git is migrated comes from the `.env` >
# built-in-default chain (test-design.md "Config-dependent branches"). A gate
# that recognizes only the explicit flags refuses every genuine upgrade; one
# that skips the comparison on the fallback migrates unidentified repos.
# The relocated layout comes from security-remote.sh's _sec_cfg_layout, so the
# `.env` under test is this suite's, never the checkout's own.

# _sec_prov_cfg <name> <env-value|""> <accept|reject> <old-origin> [empty]
_sec_prov_cfg() {
    sec_cfg_name="$1"; sec_cfg_env="$2"; sec_cfg_verdict="$3"; sec_cfg_origin="$4"
    _SEC_PROV_EXE=$(_sec_cfg_layout "prov-$sec_cfg_name" "$sec_cfg_env" "${5:-}")
    if [ "$sec_cfg_verdict" = "accept" ]; then
        _sec_prov_accept "cfg-$sec_cfg_name" "$sec_cfg_origin"
    else
        _sec_prov_reject "cfg-$sec_cfg_name" "$sec_cfg_origin"
    fi
    _SEC_PROV_EXE=""
}

# .env supplies the expectation and the recorded origin matches it: identified,
# so the repo must migrate whole.
_sec_prov_cfg "env-match" "$SEC_PROV_A" accept "$SEC_PROV_A"

# Same layout, a repo that is not the sync repo — the user's own unrelated work
# under ~/.claude. Nothing may be moved.
_sec_prov_cfg "env-mismatch" "$SEC_PROV_A" reject "$SEC_PROV_B"

# No .env: the built-in default is the expectation a stock install compares
# against, in both directions.
_sec_prov_cfg "default-match" "" accept "$SEC_PROV_DEFAULT"
_sec_prov_cfg "default-mismatch" "" reject "$SEC_PROV_A"

# `SESSION_SYNC_REMOTE_URL=` with no value: the resolver falls through to the
# built-in default, so provenance must be judged against that default and not
# against an empty expectation — which, being empty, would fail closed on the
# very repo a stock upgrade is supposed to migrate.
_sec_prov_cfg "default-empty-env" "" accept "$SEC_PROV_DEFAULT" empty
_sec_prov_cfg "default-empty-env-mismatch" "" reject "$SEC_PROV_A" empty
