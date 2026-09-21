#!/usr/bin/env bash
# tests/fix-2357-security-code-exit9-guard.sh
# Tests: skills/review-code-security/scripts/run-codex-review-loop.sh
# Tags: review-code-security, terminal-guard, exit9, fingerprint, scope:issue-specific, pwsh-not-required, TL2
#
# #2357: the #2276 fingerprint auto-clear lets a caller change the reviewed code to
# clear an exit-6 (HIGH_UNRESOLVED) marker and re-open a fresh 2+1 budget. The exit-9
# gate must fire (keeping the marker) when PREV_RC==6 and no accept marker exists; an
# accept marker sanctions the through-path.
# TL3 gap: real /review-code-security with live codex session not exercised.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

SCRIPT_SEC="$AGENTS_DIR/skills/review-code-security/scripts/run-codex-review-loop.sh"

if ! command -v git >/dev/null 2>&1; then
    skip "git unavailable — cannot exercise the diff-fingerprint seam"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0
fi

# --- fake AGENTS_CONFIG_DIR: only the two bin scripts the wrapper shells out to ---
build_fake_config_sec() {
    local fake; fake=$(make_tmp)
    mkdir -p "$fake/bin"
    cat > "$fake/bin/run-codex-review-loop" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_RC:-0}"
STUB
    cat > "$fake/bin/resolve-accepted-tradeoffs-file" <<'STUB'
#!/usr/bin/env bash
echo /dev/null
exit 0
STUB
    chmod +x "$fake/bin/run-codex-review-loop" "$fake/bin/resolve-accepted-tradeoffs-file"
    printf '%s' "$fake"
}

# --- a git repo with one commit so `git rev-parse HEAD` succeeds ---
build_repo_sec() {
    local repo; repo=$(make_tmp)
    git -C "$repo" init -q 2>/dev/null
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    echo "code" > "$repo/code.sh"
    git -C "$repo" add code.sh 2>/dev/null
    git -C "$repo" commit -q -m "initial" 2>/dev/null
    printf '%s' "$repo"
}

TERMINAL_SUFFIX_SEC="-security-code-terminal.txt"
ACCEPT_SUFFIX_SEC="-security-code-exit6-accepted.txt"

# run_loop_sec <plans> <fake> <repo> <stub_rc> → prints exit code
run_loop_sec() {
    local plans="$1" fake="$2" repo="$3" rc="$4" ec
    ( cd "$repo" && AGENTS_CONFIG_DIR="$fake" SESSION_ID="sid1361" PLANS_DIR="$plans" \
        EXTENSIONS_USED=0 STUB_RC="$rc" "$RWT" 40 bash "$SCRIPT_SEC" >/dev/null 2>&1 )
    ec=$?
    printf '%s' "$ec"
}

# ===================== (sec-a) exit 6 + new untracked file → exit 9 =====================
run_case_sec_a() {
    local plans fake repo term rc2
    plans=$(make_tmp); fake=$(build_fake_config_sec); repo=$(build_repo_sec)
    term="$plans/sid1361$TERMINAL_SUFFIX_SEC"
    run_loop_sec "$plans" "$fake" "$repo" 6 >/dev/null   # arm exit-6 marker
    echo "attacker" > "$repo/extra.sh"                   # new untracked → fingerprint flips
    rc2=$(run_loop_sec "$plans" "$fake" "$repo" 1)
    if [ "$rc2" = "9" ] && [ -f "$term" ]; then
        pass "(sec-a) exit-6 marker + new untracked file → exit 9, marker retained (bypass blocked)"
    else
        fail "(sec-a) RED-EXPECTED (exit-9 gate absent): rc=$rc2 (want 9), marker present=$([ -f "$term" ] && echo yes || echo no)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (sec-a2) exit 6 + tracked file edit → exit 9 =======================
run_case_sec_a2() {
    local plans fake repo term rc2
    plans=$(make_tmp); fake=$(build_fake_config_sec); repo=$(build_repo_sec)
    term="$plans/sid1361$TERMINAL_SUFFIX_SEC"
    run_loop_sec "$plans" "$fake" "$repo" 6 >/dev/null   # arm exit-6 marker
    if [ ! -f "$term" ]; then
        fail "(sec-a2-arm) exit 6 did not write terminal marker — setup failed"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    echo "changed tracked" >> "$repo/code.sh"            # tracked edit → git diff HEAD changes
    rc2=$(run_loop_sec "$plans" "$fake" "$repo" 1)
    if [ "$rc2" = "9" ] && [ -f "$term" ]; then
        pass "(sec-a2) exit-6 + tracked file edit → exit 9, marker retained"
    else
        fail "(sec-a2) RED-EXPECTED: rc=$rc2 (want 9), marker present=$([ -f "$term" ] && echo yes || echo no)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (sec-a3) exit 6 + existing untracked content change → exit 9 ========
run_case_sec_a3() {
    local plans fake repo term rc2
    plans=$(make_tmp); fake=$(build_fake_config_sec); repo=$(build_repo_sec)
    term="$plans/sid1361$TERMINAL_SUFFIX_SEC"
    echo "original untracked" > "$repo/untracked.sh"     # pre-existing untracked file
    run_loop_sec "$plans" "$fake" "$repo" 6 >/dev/null   # arm with fingerprint including it
    if [ ! -f "$term" ]; then
        fail "(sec-a3-arm) exit 6 did not write terminal marker — setup failed"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    echo "changed untracked" > "$repo/untracked.sh"      # content change → hash changes
    rc2=$(run_loop_sec "$plans" "$fake" "$repo" 1)
    if [ "$rc2" = "9" ] && [ -f "$term" ]; then
        pass "(sec-a3) exit-6 + existing untracked content change → exit 9, marker retained"
    else
        fail "(sec-a3) RED-EXPECTED: rc=$rc2 (want 9), marker present=$([ -f "$term" ] && echo yes || echo no)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (sec-b) exit 6 + accept marker → NOT exit 9 =====================
run_case_sec_b() {
    local plans fake repo term accept rc2
    plans=$(make_tmp); fake=$(build_fake_config_sec); repo=$(build_repo_sec)
    term="$plans/sid1361$TERMINAL_SUFFIX_SEC"
    accept="$plans/sid1361$ACCEPT_SUFFIX_SEC"
    run_loop_sec "$plans" "$fake" "$repo" 6 >/dev/null   # arm exit-6 marker
    printf 'accepted\n' > "$accept"                      # sanction the residual HIGH
    echo "changed" > "$repo/extra.sh"                    # legitimate re-edit
    rc2=$(run_loop_sec "$plans" "$fake" "$repo" 1)
    if [ "$rc2" = "1" ] && [ ! -f "$term" ]; then
        pass "(sec-b) exit-6 marker + accept file → rc=$rc2, marker deleted (guard stood down, accept path cleared marker)"
    elif [ "$rc2" = "1" ]; then
        fail "(sec-b) rc=1 but terminal marker was not deleted on accept path"
    else
        fail "(sec-b) accept file must let review through with rc=1 (got rc=$rc2, over-blocking or stub bypassed)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (sec-c) PREV_RC=2/7 + code change → NOT exit 9, marker deleted ======
# CPR-ORTH: exit-9 gate is specific to exit-6 (HIGH_UNRESOLVED); exit-2/exit-7 must not fire it.
# Arm via a real exit-2/7 run (arm_terminal_guard fires on 2|6|7), then change fingerprint.
# Expected: NOT exit 9 AND marker deleted (auto-clear ran because fingerprint changed).
run_case_sec_c() {
    local plans fake repo term rc2
    plans=$(make_tmp); fake=$(build_fake_config_sec); repo=$(build_repo_sec)
    term="$plans/sid1361$TERMINAL_SUFFIX_SEC"
    run_loop_sec "$plans" "$fake" "$repo" 2 >/dev/null   # arm exit-2 marker
    if [ ! -f "$term" ]; then
        fail "(sec-c-arm) exit-2 did not write terminal marker — setup failed"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    echo "attacker" > "$repo/extra.sh"       # fingerprint change
    rc2=$(run_loop_sec "$plans" "$fake" "$repo" 1)
    if [ "$rc2" != "9" ] && [ ! -f "$term" ]; then
        pass "(sec-c) exit-2 arm + code change → NOT exit 9, marker auto-cleared (rc=$rc2)"
    elif [ "$rc2" = "9" ]; then
        fail "(sec-c) exit-9 fired for non-exit-6 terminal (over-blocking): rc=$rc2"
    else
        fail "(sec-c) marker not deleted after auto-clear path (rc=$rc2)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

run_case_sec_c2() {
    local plans fake repo term rc2
    plans=$(make_tmp); fake=$(build_fake_config_sec); repo=$(build_repo_sec)
    term="$plans/sid1361$TERMINAL_SUFFIX_SEC"
    run_loop_sec "$plans" "$fake" "$repo" 7 >/dev/null   # arm exit-7 marker
    if [ ! -f "$term" ]; then
        fail "(sec-c2-arm) exit-7 did not write terminal marker — setup failed"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    echo "attacker" > "$repo/extra.sh"       # fingerprint change
    rc2=$(run_loop_sec "$plans" "$fake" "$repo" 1)
    if [ "$rc2" != "9" ] && [ ! -f "$term" ]; then
        pass "(sec-c2) exit-7 arm + code change → NOT exit 9, marker auto-cleared (rc=$rc2)"
    elif [ "$rc2" = "9" ]; then
        fail "(sec-c2) exit-9 fired for exit-7 terminal (over-blocking): rc=$rc2"
    else
        fail "(sec-c2) marker not deleted after auto-clear path (rc=$rc2)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (sec-d) --prestaged-report bypasses terminal guard ================
# PRESTAGED_RERUN=1 skips the entire guard block: exit 9 must not fire even with
# an exit-6 marker present and a fingerprint change after arming.
run_loop_sec_prestaged() {
    local plans="$1" fake="$2" repo="$3" rc="$4" ec
    ( cd "$repo" && AGENTS_CONFIG_DIR="$fake" SESSION_ID="sid1361" PLANS_DIR="$plans" \
        EXTENSIONS_USED=0 STUB_RC="$rc" "$RWT" 40 bash "$SCRIPT_SEC" --prestaged-report >/dev/null 2>&1 )
    ec=$?
    printf '%s' "$ec"
}

run_case_sec_d() {
    local plans fake repo term rc2
    plans=$(make_tmp); fake=$(build_fake_config_sec); repo=$(build_repo_sec)
    term="$plans/sid1361$TERMINAL_SUFFIX_SEC"
    run_loop_sec "$plans" "$fake" "$repo" 6 >/dev/null  # arm with real fingerprint
    if [ ! -f "$term" ]; then
        fail "(sec-d-arm) exit 6 did not write terminal marker — setup failed"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    echo "new code" > "$repo/extra.sh"                  # change fingerprint after arming
    rc2=$(run_loop_sec_prestaged "$plans" "$fake" "$repo" 1)
    if [ "$rc2" = "1" ] && [ -f "$term" ]; then
        pass "(sec-d) --prestaged-report + exit-6 marker + code change → rc=$rc2, marker retained (guard skipped)"
    elif [ "$rc2" = "1" ]; then
        fail "(sec-d) rc=1 but terminal marker was deleted — --prestaged-report must not touch the marker"
    else
        fail "(sec-d) --prestaged-report must bypass the terminal guard (want rc=1, got rc=$rc2)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

run_case_sec_a
run_case_sec_a2
run_case_sec_a3
run_case_sec_b
run_case_sec_c
run_case_sec_c2
run_case_sec_d

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
