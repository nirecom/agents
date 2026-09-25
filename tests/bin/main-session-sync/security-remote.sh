# Tests: install/linux/session-sync-init.sh
# Tags: bin, install, git, session-sync, security, installer, scope:issue-specific
# Part of tests/main-session-sync.sh; sourced after security.sh, whose _sec_run /
# _sec_temp_leftovers helpers it reuses.

# TL3 gap (skills/_shared/test-design.md): TL2 — the installer runs for real, but
# the `.env` it reads is one this suite plants in a copied layout, and no remote
# is ever contacted. Not covered: the shipped repo's own `.env`, a credential
# helper or ~/.gitconfig insteadOf rewriting the URL git finally uses, and a
# terminal that renders the printed URL differently from the captured stream.
# Mitigation: checked at WORKFLOW_USER_VERIFIED preflight, category installer.

echo ""
echo "=== session-sync-init.sh remote-URL sourcing and output (#1773) ==="

SEC_REM_TRUSTED="https://example.invalid/trusted.git"
SEC_REM_EXT='ext::sh -c "touch pwned"'
SEC_REM_OPT="--upload-pack=touch pwned"

# --- Config-dependent branch: the remote URL that arrives from .env ----------
# skills/_shared/test-design.md "Config-dependent branches": the URL resolves
# from --remote-url > .env > the built-in default, and a suite that never writes
# .env silently tests only whichever value the checkout happens to carry. The
# installer derives the .env path from its own location, so each branch gets a
# throwaway layout — `<root>/install/linux/session-sync-init.sh` plus `<root>/.env`
# — and the value under test is pinned in that copy.

# _sec_cfg_layout <tag> <env-value|""> [empty] — layout; echo the installer path.
_sec_cfg_layout() {
    sec_root="$TMPDIR_BASE/cfg-$1"
    rm -rf "$sec_root"
    mkdir -p "$sec_root/install/linux"
    cp "$SEC_INIT" "$sec_root/install/linux/session-sync-init.sh"
    chmod +x "$sec_root/install/linux/session-sync-init.sh"
    if [ -n "${2:-}" ]; then
        printf 'SESSION_SYNC_REMOTE_URL=%s\n' "$2" > "$sec_root/.env"
    elif [ "${3:-}" = "empty" ]; then
        # Key present, value empty — a different state from "no .env at all".
        printf 'SESSION_SYNC_REMOTE_URL=\n' > "$sec_root/.env"
    fi
    printf '%s' "$sec_root/install/linux/session-sync-init.sh"
}

# _sec_cfg_run <installer> <args...> — _sec_run against a relocated installer.
_sec_cfg_run() {
    sec_exe="$1"; shift
    _SEC_OUT=$("$sec_exe" "$@" 2>&1 </dev/null) && _SEC_RC=0 || _SEC_RC=$?
}

echo "[security] .env supplies an allowed remote URL"
SEC_CFG_URL="https://example.invalid/from-env.git"
SEC_CFG_EXE=$(_sec_cfg_layout "env-ok" "$SEC_CFG_URL")
SEC_CFG_CLAUDE="$TMPDIR_BASE/cfg-env-ok-home/.claude"
mkdir -p "$SEC_CFG_CLAUDE"
_sec_cfg_run "$SEC_CFG_EXE" --claude-dir "$SEC_CFG_CLAUDE"
SEC_CFG_GOT=$(git -C "$SEC_CFG_CLAUDE/projects" remote get-url origin 2>/dev/null || true)
if [ "$_SEC_RC" -eq 0 ] && [ "$SEC_CFG_GOT" = "$SEC_CFG_URL" ]; then
    pass "config/valid: the .env URL reached git remote add"
else
    fail "config/valid: .env URL not applied (rc=$_SEC_RC origin=$SEC_CFG_GOT)"
fi

# The attack this closes: .env is a file an installer copies around, so a
# forbidden value there must die on the same allowlist a CLI value does — and,
# like the CLI path, before the first filesystem write.
echo "[security] .env supplying a forbidden remote URL is refused"
SEC_CFG_EXE=$(_sec_cfg_layout "env-bad" "$SEC_REM_EXT")
SEC_CFG_CLAUDE="$TMPDIR_BASE/cfg-env-bad-home/.claude"
mkdir -p "$SEC_CFG_CLAUDE"
_sec_cfg_run "$SEC_CFG_EXE" --claude-dir "$SEC_CFG_CLAUDE"
if [ "$_SEC_RC" -eq 0 ]; then
    fail "config/forbidden: an ext:: URL from .env was accepted"
elif [ -e "$SEC_CFG_CLAUDE/projects" ]; then
    fail "config/forbidden: \$PROJECTS_DIR was created before the .env URL was judged"
elif [ -e "$SEC_CFG_CLAUDE/pwned" ] || [ -e "pwned" ]; then
    fail "config/forbidden: the ext:: payload executed"
else
    pass "config/forbidden: refused before any filesystem write"
fi

echo "[security] --remote-url outranks .env"
SEC_CFG_EXE=$(_sec_cfg_layout "env-override" "$SEC_CFG_URL")
SEC_CFG_CLAUDE="$TMPDIR_BASE/cfg-override-home/.claude"
mkdir -p "$SEC_CFG_CLAUDE"
_sec_cfg_run "$SEC_CFG_EXE" --claude-dir "$SEC_CFG_CLAUDE" --remote-url "$SEC_REM_TRUSTED"
SEC_CFG_GOT=$(git -C "$SEC_CFG_CLAUDE/projects" remote get-url origin 2>/dev/null || true)
if [ "$_SEC_RC" -eq 0 ] && [ "$SEC_CFG_GOT" = "$SEC_REM_TRUSTED" ]; then
    pass "config/override: the CLI value won over .env"
else
    fail "config/override: .env value survived the CLI flag (rc=$_SEC_RC origin=$SEC_CFG_GOT)"
fi

# Third branch of the same resolution chain: with no .env at all the built-in
# default applies, and it must satisfy the installer's own allowlist.
echo "[security] no .env falls back to the built-in default"
SEC_CFG_EXE=$(_sec_cfg_layout "env-absent" "")
SEC_CFG_CLAUDE="$TMPDIR_BASE/cfg-absent-home/.claude"
mkdir -p "$SEC_CFG_CLAUDE"
_sec_cfg_run "$SEC_CFG_EXE" --claude-dir "$SEC_CFG_CLAUDE"
SEC_CFG_GOT=$(git -C "$SEC_CFG_CLAUDE/projects" remote get-url origin 2>/dev/null || true)
if [ "$_SEC_RC" -eq 0 ] && [ "$SEC_CFG_GOT" = "git@github.com:nirecom/agent-sessions.git" ]; then
    pass "config/default: the shipped default applied and passed its own allowlist"
else
    fail "config/default: default not applied (rc=$_SEC_RC origin=$SEC_CFG_GOT)"
fi

# Same chain, the state between branches two and three: the key is present and
# its value is empty. The resolver's own priority makes that a fall-through to
# the built-in default, not "configured to nothing" and not an error — an
# implementation testing key presence instead of value emptiness diverges here.
echo "[security] an empty .env value falls through to the built-in default"
SEC_CFG_EXE=$(_sec_cfg_layout "env-empty" "" empty)
SEC_CFG_CLAUDE="$TMPDIR_BASE/cfg-empty-home/.claude"
mkdir -p "$SEC_CFG_CLAUDE"
_sec_cfg_run "$SEC_CFG_EXE" --claude-dir "$SEC_CFG_CLAUDE"
SEC_CFG_GOT=$(git -C "$SEC_CFG_CLAUDE/projects" remote get-url origin 2>/dev/null || true)
if [ "$_SEC_RC" -eq 0 ] && [ "$SEC_CFG_GOT" = "git@github.com:nirecom/agent-sessions.git" ]; then
    pass "config/empty: an empty value fell through to the shipped default"
else
    fail "config/empty: empty value not treated as absent (rc=$_SEC_RC origin=$SEC_CFG_GOT)"
fi

# --- A denied URL must not disturb an already-configured repo ----------------
# The table cases all start from an empty directory, where "nothing happened" and
# "nothing existed" are indistinguishable. Here a trusted origin is already in
# place, so a refusal has something to damage: set-url runs on this path, not
# remote add.
echo "[security] a denied URL leaves an existing trusted origin alone"

# _sec_rem_denied_case <tag> <denied-url>
_sec_rem_denied_case() {
    sec_claude="$TMPDIR_BASE/rem-$1/.claude"
    rm -rf "$TMPDIR_BASE/rem-$1"
    mkdir -p "$sec_claude"
    _sec_run --claude-dir "$sec_claude" --remote-url "$SEC_REM_TRUSTED"
    if [ "$_SEC_RC" -ne 0 ]; then
        fail "denied/$1: the trusted setup run itself failed (rc=$_SEC_RC, output: $_SEC_OUT)"
        return 0
    fi
    printf 'payload\n' > "$sec_claude/projects/keep.txt"
    git -C "$sec_claude/projects" add -A >/dev/null 2>&1
    git -C "$sec_claude/projects" commit -q -m "existing work" >/dev/null 2>&1
    sec_head_before=$(git -C "$sec_claude/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")

    _sec_run --claude-dir "$sec_claude" --remote-url "$2"

    sec_origin=$(git -C "$sec_claude/projects" remote get-url origin 2>/dev/null || echo "none")
    sec_head_after=$(git -C "$sec_claude/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")
    if [ "$_SEC_RC" -eq 0 ]; then
        fail "denied/$1: a forbidden URL was accepted over a configured repo"
    elif [ "$sec_origin" != "$SEC_REM_TRUSTED" ]; then
        fail "denied/$1: origin was rewritten to [$sec_origin]"
    elif [ "$sec_head_after" != "$sec_head_before" ] || [ ! -f "$sec_claude/projects/keep.txt" ]; then
        fail "denied/$1: the existing repository was disturbed by the refusal"
    else
        pass "denied/$1: refused with origin and repository unchanged"
    fi
}

_sec_rem_denied_case "ext" "$SEC_REM_EXT"
_sec_rem_denied_case "option" "$SEC_REM_OPT"

# --- Credential-bearing URLs must not be echoed -------------------------------
# The allowlist deliberately permits userinfo, so `https://user:token@host/…` is
# a configuration the installer is expected to accept — and both print branches
# ("Remote set to …" on add, "Remote updated to …" on set-url) render the whole
# URL. Installer output lands in CI logs and install transcripts, so the secret
# must not be in it (test-design.md security cases: secret leakage, OWASP ASVS V8).
SEC_REM_SENTINEL="SENTINEL-NOT-A-REAL-TOKEN"
SEC_REM_CRED="https://ci-user:$SEC_REM_SENTINEL@example.invalid/repo.git"
SEC_REM_CRED2="https://ci-user:$SEC_REM_SENTINEL@example.invalid/other.git"
SEC_REM_CRED_CLAUDE="$TMPDIR_BASE/rem-cred/.claude"
mkdir -p "$SEC_REM_CRED_CLAUDE"

echo "[security] the add branch does not print the credential"
_sec_run --claude-dir "$SEC_REM_CRED_CLAUDE" --remote-url "$SEC_REM_CRED"
SEC_REM_GOT=$(git -C "$SEC_REM_CRED_CLAUDE/projects" remote get-url origin 2>/dev/null || true)
if [ "$_SEC_RC" -ne 0 ] || [ "$SEC_REM_GOT" != "$SEC_REM_CRED" ]; then
    fail "credential/add: a legitimate userinfo URL was not configured (rc=$_SEC_RC origin=$SEC_REM_GOT)"
elif echo "$_SEC_OUT" | grep -qF "$SEC_REM_SENTINEL"; then
    fail "credential/add: the password appears in installer output"
else
    pass "credential/add: configured without printing the password"
fi

echo "[security] the set-url branch does not print the credential"
_sec_run --claude-dir "$SEC_REM_CRED_CLAUDE" --remote-url "$SEC_REM_CRED2"
SEC_REM_GOT=$(git -C "$SEC_REM_CRED_CLAUDE/projects" remote get-url origin 2>/dev/null || true)
if [ "$_SEC_RC" -ne 0 ] || [ "$SEC_REM_GOT" != "$SEC_REM_CRED2" ]; then
    fail "credential/update: the updated userinfo URL was not configured (rc=$_SEC_RC origin=$SEC_REM_GOT)"
elif echo "$_SEC_OUT" | grep -qF "$SEC_REM_SENTINEL"; then
    fail "credential/update: the password appears in installer output"
else
    pass "credential/update: updated without printing the password"
fi
