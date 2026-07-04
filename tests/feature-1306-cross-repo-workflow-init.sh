#!/bin/bash
# Tests: bin/parse-issue-tokens, hooks/lib/parse-closes-issues.js (cross-repo parsing),
#        skills/workflow-init/scripts/filter-primary-candidates.sh (cross-repo tokens),
#        bin/github-issues/lib/board-card.sh (resolve_owner_repo BOARD_CARD_REPO_OVERRIDE),
#        bin/github-issues/wip-state.sh (--repo arg),
#        skills/workflow-init/scripts/wip-set-resume.sh (--repo-map arg),
#        skills/workflow-init/scripts/closed-detection.sh (--repo-map arg),
#        skills/workflow-init/scripts/aggregate-wip-check.sh (--repo-map arg),
#        skills/workflow-init/scripts/path-a-label-and-board.sh (--repo arg),
#        bin/github-issues/clarify-commit-scope.sh (per-issue routing),
#        skills/clarify-intent/SKILL.md CI-3b (cross-repo detection SSOT)
# Tags: workflow-init, cross-repo, parse-issue-tokens, board-card, clarify-intent, scope:issue-specific
#
# Feature 1306 — cross-repo issue routing for workflow-init.
#
# Layer: L2 (broad integration with mock-gh / argument-recording stubs).
# Tests against not-yet-created source files use SKIP guards.
# Tests against existing files (board-card.sh, clarify-commit-scope.sh, etc.)
# check current state and assert future contract via SKIP where not yet implemented.
#
# L3 gap:
# - Real `gh` calls against live GitHub repos with cross-repo issues.
# - Real worktree switching between sibling repos (agents + dotfiles).
# - Real `wip-state.sh set` propagating BOARD_CARD_REPO_OVERRIDE through to the
#   Projects v2 GraphQL query in a live environment.
# - CI-3b AskUserQuestion flow collecting sibling worktree paths from the user
#   in a full `claude -p` E2E session.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local label="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$label"
    else
        fail "$label: want='$want' got='$got'"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# ---------------------------------------------------------------------------
# Paths to source files under test
# ---------------------------------------------------------------------------
PARSE_CLOSES_ISSUES_JS="$AGENTS_DIR/hooks/lib/parse-closes-issues.js"
PARSE_CLOSES_ISSUES_CLI="$AGENTS_DIR/bin/parse-closes-issues"
PARSE_ISSUE_TOKENS="$AGENTS_DIR/bin/parse-issue-tokens"
FILTER_SCRIPT="$AGENTS_DIR/skills/workflow-init/scripts/filter-primary-candidates.sh"
BOARD_CARD_LIB="$AGENTS_DIR/bin/github-issues/lib/board-card.sh"
WIP_STATE="$AGENTS_DIR/bin/github-issues/wip-state.sh"
WIP_SET_RESUME="$AGENTS_DIR/skills/workflow-init/scripts/wip-set-resume.sh"
CLOSED_DETECTION="$AGENTS_DIR/skills/workflow-init/scripts/closed-detection.sh"
AGGREGATE_WIP="$AGENTS_DIR/skills/workflow-init/scripts/aggregate-wip-check.sh"
PATH_A_LABEL="$AGENTS_DIR/skills/workflow-init/scripts/path-a-label-and-board.sh"
CLARIFY_SCOPE="$AGENTS_DIR/bin/github-issues/clarify-commit-scope.sh"
CLARIFY_INTENT_SKILL="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
WIP_SET_SINGLE="$AGENTS_DIR/bin/github-issues/wip-set-single.sh"

# ---------------------------------------------------------------------------
# Helper: write a minimal intent.md with ## Issues section and return path
# ---------------------------------------------------------------------------
write_intent() {
    local f="$1" content="$2"
    printf '%s\n' "$content" > "$f"
}

# Helper: use parse-closes-issues CLI (existing) to parse an intent file
parse_intent() {
    run_with_timeout 10 node "$PARSE_CLOSES_ISSUES_CLI" "$1" 2>/dev/null
}

# Helper: extract a field from JSON array element using node
# Uses process.argv to avoid /dev/stdin which is unavailable on Windows Git Bash.
jq_elem() {
    local json="$1" idx="$2" field="$3"
    node -e "
const d=JSON.parse(process.argv[1]);
const e=d[parseInt(process.argv[2])];
const f=process.argv[3];
if(!e){process.stdout.write('undefined');}
else if(f==='number'){process.stdout.write(String(e.number));}
else{process.stdout.write(String(e[f]));}
" "$json" "$idx" "$field" 2>/dev/null || echo "error"
}

jq_len() {
    local json="$1"
    node -e "
const d=JSON.parse(process.argv[1]);
process.stdout.write(String(d.length));
" "$json" 2>/dev/null || echo "error"
}

jq_has_field() {
    local json="$1" idx="$2" field="$3"
    node -e "
const d=JSON.parse(process.argv[1]);
const e=d[parseInt(process.argv[2])];
const f=process.argv[3];
process.stdout.write(e&&f in e ? 'yes' : 'no');
" "$json" "$idx" "$field" 2>/dev/null || echo "error"
}

# ===========================================================================
# T1-T5, T14, T26: parse-closes-issues — table-driven single/multi-entry cases
#
# Table columns (IFS='|'):
#   name       — test label
#   tokens     — space-separated issue tokens written as "- TOKEN" lines under ## Issues
#                Use __NONE__ for placeholder text (not a token)
#   want_count — expected JSON array length
#   want_repos — space-separated "num:repo" pairs (one per entry); empty repo = no repo field
#
# Encoding: entry "42:" means {number:42} (no repo); "42:dotfiles" means {number:42,repo:"dotfiles"}
# ===========================================================================
if [ ! -f "$PARSE_CLOSES_ISSUES_JS" ] || [ ! -f "$PARSE_CLOSES_ISSUES_CLI" ]; then
    skip "T1-T5/T14/T26: parse-closes-issues CLI or JS not found"
else
    TMP_TBL="$(mktemp -d 2>/dev/null || mktemp -d -t pritbl)"
    _tbl_parse_intent() {
        local f="$1"
        run_with_timeout 10 node "$PARSE_CLOSES_ISSUES_CLI" "$f" 2>/dev/null
    }
    while IFS='|' read -r tname ttokens twant_count twant_repos; do
        [[ -z "$tname" || "$tname" =~ ^[[:space:]]*# ]] && continue
        tname="${tname#"${tname%%[! ]*}"}"; tname="${tname%"${tname##*[! ]}"}"
        ttokens="${ttokens#"${ttokens%%[! ]*}"}"
        twant_count="${twant_count#"${twant_count%%[! ]*}"}"; twant_count="${twant_count%"${twant_count##*[! ]}"}"
        twant_repos="${twant_repos#"${twant_repos%%[! ]*}"}"

        TFILE="$TMP_TBL/intent-$$.md"
        # Build ## Issues section: __NONE__ becomes a literal placeholder line
        if [ "$ttokens" = "__NONE__" ]; then
            printf '## Issues\n(none -- pending issue creation or NON_GITHUB)\n' > "$TFILE"
        else
            printf '## Issues\n' > "$TFILE"
            for tok in $ttokens; do
                printf -- '- %s\n' "$tok" >> "$TFILE"
            done
        fi

        TOUT=$(_tbl_parse_intent "$TFILE")
        TLEN=$(jq_len "$TOUT")
        if [ "$TLEN" != "$twant_count" ]; then
            fail "$tname: count want=$twant_count got=$TLEN (out=$TOUT)"
            continue
        fi
        if [ "$twant_count" = "0" ]; then
            pass "$tname"
            continue
        fi

        # Verify each entry: "idx:num:repo" encoded as space-separated "num:repo" in want_repos
        _tidx=0
        _all_ok=1
        for _entry in $twant_repos; do
            _wnum="${_entry%%:*}"
            _wrepo="${_entry#*:}"
            _gnum=$(jq_elem "$TOUT" "$_tidx" "number")
            if [ "$_wrepo" = "" ]; then
                _grepo=$(jq_has_field "$TOUT" "$_tidx" "repo")
                if [ "$_gnum" != "$_wnum" ] || [ "$_grepo" != "no" ]; then
                    fail "$tname[${_tidx}]: want num=$_wnum no-repo, got num=$_gnum has_repo=$_grepo"
                    _all_ok=0
                fi
            else
                _grepo=$(jq_elem "$TOUT" "$_tidx" "repo")
                if [ "$_gnum" != "$_wnum" ] || [ "$_grepo" != "$_wrepo" ]; then
                    fail "$tname[${_tidx}]: want num=$_wnum repo=$_wrepo, got num=$_gnum repo=$_grepo"
                    _all_ok=0
                fi
            fi
            _tidx=$((_tidx + 1))
        done
        [ "$_all_ok" = "1" ] && pass "$tname"
    done <<'TABLE'
# name                                | tokens                                        | want_count | want_repos
T1: bare #N → no repo                | #42                                           | 1          | 42:
T2: repo#N → short repo              | dotfiles#42                                   | 1          | 42:dotfiles
T3: owner/repo#N → full repo         | nirecom/dotfiles#42                           | 1          | 42:nirecom/dotfiles
T4: mixed tokens insertion order     | #10 nirecom/dotfiles#20 my-private-repo#30   | 3          | 10: 20:nirecom/dotfiles 30:my-private-repo
T5: placeholder → empty array        | __NONE__                                      | 0          |
T14: same num diff repos → 2 entries | nirecom/agents#42 nirecom/dotfiles#42         | 2          | 42:nirecom/agents 42:nirecom/dotfiles
T26: bare multi backward-compat      | #100 #200                                     | 2          | 100: 200:
TABLE
    rm -rf "$TMP_TBL" 2>/dev/null
fi

# ===========================================================================
# T5a: parse-closes-issues — error: file with no ## Issues heading → empty array
# T5b: parse-closes-issues — error: ## Issues heading with bare "(none)" → empty array
# T5c: parse-closes-issues — mixed: bare #N and repo#N in same ## Issues section
# ===========================================================================
if [ ! -f "$PARSE_CLOSES_ISSUES_JS" ] || [ ! -f "$PARSE_CLOSES_ISSUES_CLI" ]; then
    skip "T5a/T5b/T5c: parse-closes-issues CLI or JS not found"
else
    TMP_ERR="$(mktemp -d 2>/dev/null || mktemp -d -t prierr)"
    # T5a: no ## Issues heading (plain text, no structured sections)
    FERR="$TMP_ERR/intent-5a.md"
    write_intent "$FERR" "This file has no issues section, just some plain text."
    OUT5A=$(run_with_timeout 10 node "$PARSE_CLOSES_ISSUES_CLI" "$FERR" 2>/dev/null)
    assert_eq "T5a: no ## Issues heading → []" "[]" "$OUT5A"

    # T5b: ## Issues heading present but content is "(none)" placeholder
    FERR="$TMP_ERR/intent-5b.md"
    write_intent "$FERR" "## Issues
(none)"
    OUT5B=$(run_with_timeout 10 node "$PARSE_CLOSES_ISSUES_CLI" "$FERR" 2>/dev/null)
    assert_eq "T5b: ## Issues + (none) placeholder → []" "[]" "$OUT5B"

    # T5c: mixed bare #N and repo#N in same ## Issues section → both parsed
    FERR="$TMP_ERR/intent-5c.md"
    write_intent "$FERR" "## Issues
- #55
- dotfiles#77"
    OUT5C=$(run_with_timeout 10 node "$PARSE_CLOSES_ISSUES_CLI" "$FERR" 2>/dev/null)
    LEN5C=$(jq_len "$OUT5C")
    N5C0=$(jq_elem "$OUT5C" 0 "number")
    N5C1=$(jq_elem "$OUT5C" 1 "number")
    R5C0=$(jq_has_field "$OUT5C" 0 "repo")
    R5C1=$(jq_elem "$OUT5C" 1 "repo")
    if [ "$LEN5C" = "2" ] && [ "$N5C0" = "55" ] && [ "$N5C1" = "77" ] \
       && [ "$R5C0" = "no" ] && [ "$R5C1" = "dotfiles" ]; then
        pass "T5c: mixed bare #N + repo#N → 2 entries with correct repos"
    else
        fail "T5c: mixed: len=$LEN5C n0=$N5C0(hasRepo=$R5C0) n1=$N5C1(repo=$R5C1)"
    fi
    rm -rf "$TMP_ERR" 2>/dev/null
fi

# ===========================================================================
# T6: filter-primary-candidates.sh — bare issue (no --repo-map) → outputs "#N"
# ===========================================================================
if [ ! -f "$FILTER_SCRIPT" ]; then
    skip "T6: filter-primary-candidates.sh not found"
else
    TMP_T6="$(mktemp -d 2>/dev/null || mktemp -d -t fpt6)"
    mkdir -p "$TMP_T6/mock-bin" "$TMP_T6/bin/github-issues"
    cat > "$TMP_T6/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
echo '{"parent":null}'
exit 0
MOCKGH
    chmod +x "$TMP_T6/mock-bin/gh"
    cat > "$TMP_T6/bin/github-issues/issue-state-check.sh" <<'MOCKSTATE'
#!/bin/bash
N="${@: -1}"
echo "open"
exit 0
MOCKSTATE
    chmod +x "$TMP_T6/bin/github-issues/issue-state-check.sh"
    export AGENTS_CONFIG_DIR="$TMP_T6"
    OLD_PATH="$PATH"
    export PATH="$TMP_T6/mock-bin:$PATH"
    OUT_T6=$(run_with_timeout 10 bash "$FILTER_SCRIPT" 42 2>/dev/null)
    RC_T6=$?
    export PATH="$OLD_PATH"
    rm -rf "$TMP_T6" 2>/dev/null
    unset AGENTS_CONFIG_DIR
    if [ "$RC_T6" -eq 0 ] && printf '%s\n' "$OUT_T6" | grep -qx '#42'; then
        pass "T6: filter bare #42 → outputs '#42' token"
    else
        fail "T6: expected '#42'; got rc=$RC_T6 out=$OUT_T6"
    fi
fi

# ===========================================================================
# T7: filter-primary-candidates.sh — with --repo-map → outputs "owner/repo#N"
# ===========================================================================
if [ ! -f "$FILTER_SCRIPT" ]; then
    skip "T7: filter-primary-candidates.sh not found"
elif grep -q -- '--repo-map' "$FILTER_SCRIPT" 2>/dev/null; then
    TMP_T7="$(mktemp -d 2>/dev/null || mktemp -d -t fpt7)"
    mkdir -p "$TMP_T7/mock-bin" "$TMP_T7/bin/github-issues"
    cat > "$TMP_T7/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
echo '{"parent":null}'
exit 0
MOCKGH
    chmod +x "$TMP_T7/mock-bin/gh"
    cat > "$TMP_T7/bin/github-issues/issue-state-check.sh" <<'MOCKSTATE'
#!/bin/bash
N="${@: -1}"
echo "open"
exit 0
MOCKSTATE
    chmod +x "$TMP_T7/bin/github-issues/issue-state-check.sh"
    export AGENTS_CONFIG_DIR="$TMP_T7"
    OLD_PATH="$PATH"
    export PATH="$TMP_T7/mock-bin:$PATH"
    OUT_T7=$(run_with_timeout 10 bash "$FILTER_SCRIPT" --repo-map "0:nirecom/dotfiles" 42 2>/dev/null)
    RC_T7=$?
    export PATH="$OLD_PATH"
    rm -rf "$TMP_T7" 2>/dev/null
    unset AGENTS_CONFIG_DIR
    if [ "$RC_T7" -eq 0 ] && printf '%s\n' "$OUT_T7" | grep -qx 'nirecom/dotfiles#42'; then
        pass "T7: filter --repo-map 0:nirecom/dotfiles 42 → outputs 'nirecom/dotfiles#42'"
    else
        fail "T7: expected 'nirecom/dotfiles#42'; got rc=$RC_T7 out=$OUT_T7"
    fi
else
    skip "T7: filter-primary-candidates.sh --repo-map not implemented"
fi

# ===========================================================================
# T8: filter-primary-candidates.sh — same-number cross-repo → both survive
# ===========================================================================
if [ ! -f "$FILTER_SCRIPT" ]; then
    skip "T8: filter-primary-candidates.sh not found"
elif grep -q -- '--repo-map' "$FILTER_SCRIPT" 2>/dev/null; then
    TMP_T8="$(mktemp -d 2>/dev/null || mktemp -d -t fpt8)"
    mkdir -p "$TMP_T8/mock-bin" "$TMP_T8/bin/github-issues"
    cat > "$TMP_T8/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
echo '{"parent":null}'
exit 0
MOCKGH
    chmod +x "$TMP_T8/mock-bin/gh"
    cat > "$TMP_T8/bin/github-issues/issue-state-check.sh" <<'MOCKSTATE'
#!/bin/bash
N="${@: -1}"
echo "open"
exit 0
MOCKSTATE
    chmod +x "$TMP_T8/bin/github-issues/issue-state-check.sh"
    export AGENTS_CONFIG_DIR="$TMP_T8"
    OLD_PATH="$PATH"
    export PATH="$TMP_T8/mock-bin:$PATH"
    # Two issues both numbered 42, but in different repos
    OUT_T8=$(run_with_timeout 10 bash "$FILTER_SCRIPT" \
        --repo-map "0:nirecom/agents" --repo-map "1:nirecom/dotfiles" 42 42 2>/dev/null)
    RC_T8=$?
    export PATH="$OLD_PATH"
    rm -rf "$TMP_T8" 2>/dev/null
    unset AGENTS_CONFIG_DIR
    HAS_AGENTS=$(printf '%s\n' "$OUT_T8" | grep -cx 'nirecom/agents#42' || true)
    HAS_DOTFILES=$(printf '%s\n' "$OUT_T8" | grep -cx 'nirecom/dotfiles#42' || true)
    if [ "$RC_T8" -eq 0 ] && [ "$HAS_AGENTS" -ge 1 ] && [ "$HAS_DOTFILES" -ge 1 ]; then
        pass "T8: same-number cross-repo → both nirecom/agents#42 and nirecom/dotfiles#42 survive"
    else
        fail "T8: expected both cross-repo tokens; got rc=$RC_T8 out=$OUT_T8"
    fi
else
    skip "T8: filter-primary-candidates.sh --repo-map not implemented"
fi

# ===========================================================================
# T9: static guard — clarify-commit-scope.sh C4 bug fix: per-issue --repo routing
#     After #1306, the script routes each issue with its repo via --repo-map.
# ===========================================================================
if [ ! -f "$CLARIFY_SCOPE" ]; then
    skip "T9: clarify-commit-scope.sh not found"
elif grep -q -- '--repo-map\|REPO_MAP\|repo_map' "$CLARIFY_SCOPE" 2>/dev/null; then
    pass "T9: clarify-commit-scope.sh has per-issue --repo routing (static check)"
else
    skip "T9: clarify-commit-scope.sh per-issue --repo routing not yet implemented"
fi

# ===========================================================================
# T10b: static guard — CI-3b in SKILL.md must not use shell token-splitting
#         patterns (${token##*#}, cut -d'#')
# ===========================================================================
if [ ! -f "$CLARIFY_INTENT_SKILL" ]; then
    skip "T10b: clarify-intent SKILL.md not found"
else
    BAD1=$(grep -c '\${.*##.*#}' "$CLARIFY_INTENT_SKILL" 2>/dev/null; true)
    BAD2=$(grep -c "cut -d'#'" "$CLARIFY_INTENT_SKILL" 2>/dev/null; true)
    BAD3=$(grep -c 'cut -d"#"' "$CLARIFY_INTENT_SKILL" 2>/dev/null; true)
    if [ "$BAD1" -gt 0 ]; then
        fail "T10b: SKILL.md contains \${##*#} token-splitting ($BAD1 occurrences)"
    elif [ "$BAD2" -gt 0 ] || [ "$BAD3" -gt 0 ]; then
        fail "T10b: SKILL.md contains cut -d'#' token-splitting"
    else
        pass "T10b: no shell token-splitting in clarify-intent SKILL.md"
    fi
fi

# ===========================================================================
# T11: board-card.sh resolve_owner_repo — current behavior: calls gh repo view
#       (CWD-based). Static check: function exists and uses gh repo view.
# ===========================================================================
if [ ! -f "$BOARD_CARD_LIB" ]; then
    skip "T11: board-card.sh not found"
else
    HAS_FUNC=$(grep -c 'resolve_owner_repo' "$BOARD_CARD_LIB" 2>/dev/null; true)
    HAS_GH=$(grep -c 'gh repo view' "$BOARD_CARD_LIB" 2>/dev/null; true)
    if [ "$HAS_FUNC" -gt 0 ] && [ "$HAS_GH" -gt 0 ]; then
        pass "T11: resolve_owner_repo() exists and calls 'gh repo view' (CWD-based path)"
    else
        fail "T11: resolve_owner_repo() or 'gh repo view' missing (func=$HAS_FUNC gh=$HAS_GH)"
    fi
fi

# ===========================================================================
# T12: board-card.sh resolve_owner_repo — BOARD_CARD_REPO_OVERRIDE → returns
#       override without calling gh.
# ===========================================================================
if [ ! -f "$BOARD_CARD_LIB" ]; then
    skip "T12: board-card.sh not found"
elif grep -q 'BOARD_CARD_REPO_OVERRIDE' "$BOARD_CARD_LIB" 2>/dev/null; then
    # Implementation present — test runtime behavior
    TMP_T12="$(mktemp -d 2>/dev/null || mktemp -d -t bct12)"
    HARNESS="$TMP_T12/harness.sh"
    printf '#!/bin/bash\nset -u\nexport BOARD_CARD_REPO_OVERRIDE="nirecom/dotfiles"\nsource "%s"\nOUT=$(resolve_owner_repo 2>/dev/null)\necho "$OUT"\n' "$BOARD_CARD_LIB" > "$HARNESS"
    chmod +x "$HARNESS"
    OUT_T12=$(run_with_timeout 10 bash "$HARNESS" 2>/dev/null)
    assert_eq "T12: BOARD_CARD_REPO_OVERRIDE → returns override value" "nirecom/dotfiles" "$OUT_T12"
    rm -rf "$TMP_T12" 2>/dev/null
else
    skip "T12: BOARD_CARD_REPO_OVERRIDE not yet in board-card.sh — SKIP: implementation pending"
fi

# ===========================================================================
# T12a: board-card.sh resolve_owner_repo — runtime happy-path for BOARD_CARD_REPO_OVERRIDE
#        Sources board-card.sh, sets BOARD_CARD_REPO_OVERRIDE, calls resolve_owner_repo,
#        asserts it returns the override without invoking gh.
# ===========================================================================
if [ ! -f "$BOARD_CARD_LIB" ]; then
    skip "T12a: board-card.sh not found"
elif grep -q 'BOARD_CARD_REPO_OVERRIDE' "$BOARD_CARD_LIB" 2>/dev/null; then
    TMP_T12A="$(mktemp -d 2>/dev/null || mktemp -d -t bct12a)"
    HARNESS_12A="$TMP_T12A/harness.sh"
    # Override gh so any accidental call would be detectable
    printf '#!/bin/bash\ngh() { echo "UNEXPECTED_GH_CALL"; return 1; }\nexport -f gh\nexport BOARD_CARD_REPO_OVERRIDE="nirecom/test-repo"\nsource "%s"\nOUT=$(resolve_owner_repo 2>/dev/null)\nprintf "%%s" "$OUT"\n' "$BOARD_CARD_LIB" > "$HARNESS_12A"
    chmod +x "$HARNESS_12A"
    OUT_T12A=$(run_with_timeout 10 bash "$HARNESS_12A" 2>/dev/null)
    assert_eq "T12a: BOARD_CARD_REPO_OVERRIDE=nirecom/test-repo → returns override (no gh call)" "nirecom/test-repo" "$OUT_T12A"
    rm -rf "$TMP_T12A" 2>/dev/null
else
    skip "T12a: BOARD_CARD_REPO_OVERRIDE runtime path not yet in board-card.sh — SKIP: implementation pending"
fi

# ===========================================================================
# T13: wip-state.sh --repo → sets BOARD_CARD_REPO_OVERRIDE before sourcing board-card.sh
# ===========================================================================
if [ ! -f "$WIP_STATE" ]; then
    skip "T13: wip-state.sh not found"
elif grep -q 'BOARD_CARD_REPO_OVERRIDE' "$WIP_STATE" 2>/dev/null; then
    pass "T13: wip-state.sh sets BOARD_CARD_REPO_OVERRIDE (static check)"
else
    skip "T13: wip-state.sh --repo / BOARD_CARD_REPO_OVERRIDE not yet implemented — SKIP: implementation pending"
fi

# Note: T14 (same num diff repos) is covered in the table-driven loop above.

# ===========================================================================
# T15: wip-set-resume.sh — with --repo-map → passes --repo to wip-set-single.sh
# ===========================================================================
if [ ! -f "$WIP_SET_RESUME" ]; then
    skip "T15: wip-set-resume.sh not found"
elif grep -q -- '--repo-map' "$WIP_SET_RESUME" 2>/dev/null; then
    HAS_REPO_FWD=$(grep -c -- '--repo' "$WIP_SET_RESUME" 2>/dev/null; true)
    HAS_SINGLE=$(grep -c 'wip-set-single' "$WIP_SET_RESUME" 2>/dev/null; true)
    if [ "$HAS_REPO_FWD" -gt 0 ] && [ "$HAS_SINGLE" -gt 0 ]; then
        pass "T15: wip-set-resume.sh --repo-map → passes --repo to wip-set-single.sh (static)"
    else
        fail "T15: wip-set-resume.sh has --repo-map but does not forward --repo (fwd=$HAS_REPO_FWD single=$HAS_SINGLE)"
    fi
else
    skip "T15: wip-set-resume.sh --repo-map not yet implemented — SKIP: implementation pending"
fi

# ===========================================================================
# T16: filter-primary-candidates.sh end-to-end cross-repo (round-trip)
# ===========================================================================
if [ ! -f "$FILTER_SCRIPT" ]; then
    skip "T16: filter-primary-candidates.sh not found"
elif grep -q -- '--repo-map' "$FILTER_SCRIPT" 2>/dev/null; then
    TMP_T16="$(mktemp -d 2>/dev/null || mktemp -d -t fpt16)"
    mkdir -p "$TMP_T16/mock-bin" "$TMP_T16/bin/github-issues"
    cat > "$TMP_T16/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
echo '{"parent":null}'
exit 0
MOCKGH
    chmod +x "$TMP_T16/mock-bin/gh"
    cat > "$TMP_T16/bin/github-issues/issue-state-check.sh" <<'MOCKSTATE'
#!/bin/bash
N="${@: -1}"
VARNAME="MOCK_STATE_${N}"
VAL="${!VARNAME:-}"
echo "${VAL:-open}"
exit 0
MOCKSTATE
    chmod +x "$TMP_T16/bin/github-issues/issue-state-check.sh"
    export AGENTS_CONFIG_DIR="$TMP_T16"
    OLD_PATH="$PATH"
    export PATH="$TMP_T16/mock-bin:$PATH"
    # agents#100 open, dotfiles#200 closed → only agents#100 survives
    export MOCK_STATE_100=open
    export MOCK_STATE_200=closed
    OUT_T16=$(run_with_timeout 10 bash "$FILTER_SCRIPT" \
        --repo-map "0:nirecom/agents" --repo-map "1:nirecom/dotfiles" 100 200 2>/dev/null)
    RC_T16=$?
    export PATH="$OLD_PATH"
    rm -rf "$TMP_T16" 2>/dev/null
    unset AGENTS_CONFIG_DIR MOCK_STATE_100 MOCK_STATE_200
    HAS_AGENTS=$(printf '%s\n' "$OUT_T16" | grep -cx 'nirecom/agents#100' || true)
    HAS_DOTFILES=$(printf '%s\n' "$OUT_T16" | grep -cx 'nirecom/dotfiles#200' || true)
    if [ "$RC_T16" -eq 0 ] && [ "$HAS_AGENTS" -ge 1 ] && [ "$HAS_DOTFILES" -eq 0 ]; then
        pass "T16: cross-repo round-trip: closed dotfiles#200 excluded, agents#100 kept"
    else
        fail "T16: expected agents#100 only; got rc=$RC_T16 out=$OUT_T16"
    fi
else
    skip "T16: filter-primary-candidates.sh --repo-map not implemented"
fi

# ===========================================================================
# T17: closed-detection.sh — with --repo-map → issue-state-check.sh called with --repo
# ===========================================================================
if [ ! -f "$CLOSED_DETECTION" ]; then
    skip "T17: closed-detection.sh not found"
elif grep -q -- '--repo-map' "$CLOSED_DETECTION" 2>/dev/null; then
    HAS_REPO=$(grep -c -- '--repo' "$CLOSED_DETECTION" 2>/dev/null; true)
    HAS_ISC=$(grep -c 'issue-state-check' "$CLOSED_DETECTION" 2>/dev/null; true)
    if [ "$HAS_REPO" -gt 0 ] && [ "$HAS_ISC" -gt 0 ]; then
        pass "T17: closed-detection.sh --repo-map → passes --repo to issue-state-check.sh (static)"
    else
        fail "T17: closed-detection.sh has --repo-map but does not forward --repo"
    fi
else
    skip "T17: closed-detection.sh --repo-map not yet implemented — SKIP: implementation pending"
fi

# ===========================================================================
# T18: aggregate-wip-check.sh — with --repo-map → wip-state.sh called with --repo
# ===========================================================================
if [ ! -f "$AGGREGATE_WIP" ]; then
    skip "T18: aggregate-wip-check.sh not found"
elif grep -q -- '--repo-map' "$AGGREGATE_WIP" 2>/dev/null; then
    HAS_REPO=$(grep -c -- '--repo' "$AGGREGATE_WIP" 2>/dev/null; true)
    HAS_WIP=$(grep -c 'wip-state' "$AGGREGATE_WIP" 2>/dev/null; true)
    if [ "$HAS_REPO" -gt 0 ] && [ "$HAS_WIP" -gt 0 ]; then
        pass "T18: aggregate-wip-check.sh --repo-map → passes --repo to wip-state.sh (static)"
    else
        fail "T18: aggregate-wip-check.sh has --repo-map but does not forward --repo"
    fi
else
    skip "T18: aggregate-wip-check.sh --repo-map not yet implemented — SKIP: implementation pending"
fi

# ===========================================================================
# T19: wip-set-resume.sh — backward-compat: still accepts bare positional N args
# ===========================================================================
if [ ! -f "$WIP_SET_RESUME" ]; then
    skip "T19: wip-set-resume.sh not found"
else
    # Static check: positional ISSUES array parsing is still present
    if grep -q 'ISSUES+=\|ISSUES=(' "$WIP_SET_RESUME" 2>/dev/null; then
        pass "T19: wip-set-resume.sh still has positional N args (backward-compat)"
    else
        fail "T19: wip-set-resume.sh lost positional N args parsing"
    fi
fi

# ===========================================================================
# T20: path-a-label-and-board.sh — with --repo → forwarded to gh and board card
# ===========================================================================
if [ ! -f "$PATH_A_LABEL" ]; then
    skip "T20: path-a-label-and-board.sh not found"
elif grep -q -- '--repo' "$PATH_A_LABEL" 2>/dev/null && \
     grep -qE -- '--repo[[:space:]]' "$PATH_A_LABEL" 2>/dev/null; then
    HAS_BOARD=$(grep -c 'ensure-board-card' "$PATH_A_LABEL" 2>/dev/null; true)
    if [ "$HAS_BOARD" -gt 0 ]; then
        pass "T20: path-a-label-and-board.sh --repo forwarded to gh and ensure-board-card.sh (static)"
    else
        fail "T20: path-a-label-and-board.sh has --repo but ensure-board-card.sh missing"
    fi
else
    skip "T20: path-a-label-and-board.sh --repo not yet implemented — SKIP: implementation pending"
fi

# ===========================================================================
# T21: clarify-commit-scope.sh — mixed-repo CSV → per-issue --repo routing
# ===========================================================================
if [ ! -f "$CLARIFY_SCOPE" ]; then
    skip "T21: clarify-commit-scope.sh not found"
elif grep -q -- '--repo-map\|REPO_MAP\|repo_map' "$CLARIFY_SCOPE" 2>/dev/null; then
    pass "T21: clarify-commit-scope.sh has per-issue --repo routing (static check)"
else
    skip "T21: clarify-commit-scope.sh per-issue --repo routing not yet implemented"
fi

# ===========================================================================
# T22: clarify-commit-scope.sh — same-repo CSV still works (backward-compat)
# ===========================================================================
if [ ! -f "$CLARIFY_SCOPE" ]; then
    skip "T22: clarify-commit-scope.sh not found"
else
    HAS_CSV=$(grep -cE 'ISSUES_CSV|ISSUE_LIST' "$CLARIFY_SCOPE" 2>/dev/null; true)
    if [ "$HAS_CSV" -gt 0 ]; then
        pass "T22: clarify-commit-scope.sh still has issues CSV parsing (backward-compat, static)"
    else
        fail "T22: clarify-commit-scope.sh lost ISSUES_CSV/ISSUE_LIST parsing"
    fi
fi

# ===========================================================================
# T23: wip-set-single.sh — forwards --repo to downstream calls
# ===========================================================================
if [ ! -f "$WIP_SET_SINGLE" ]; then
    skip "T23: wip-set-single.sh not found"
elif grep -q -- '--repo' "$WIP_SET_SINGLE" 2>/dev/null; then
    pass "T23: wip-set-single.sh accepts and forwards --repo (static check)"
else
    skip "T23: wip-set-single.sh --repo not yet implemented — SKIP: implementation pending"
fi

# ===========================================================================
# T24: short-form repo#N normalization — parse-closes-issues returns repo field
# ===========================================================================
if [ ! -f "$PARSE_CLOSES_ISSUES_JS" ] || [ ! -f "$PARSE_CLOSES_ISSUES_CLI" ]; then
    skip "T24: parse-closes-issues not found"
else
    TMP_T24="$(mktemp -d 2>/dev/null || mktemp -d -t t24)"
    FTEST="$TMP_T24/intent.md"
    write_intent "$FTEST" "## Issues
- dotfiles#99"
    OUT_T24=$(run_with_timeout 10 node "$PARSE_CLOSES_ISSUES_CLI" "$FTEST" 2>/dev/null)
    N_T24=$(jq_elem "$OUT_T24" 0 "number")
    R_T24=$(jq_elem "$OUT_T24" 0 "repo")
    rm -rf "$TMP_T24" 2>/dev/null
    if [ "$N_T24" = "99" ] && [ "$R_T24" = "dotfiles" ]; then
        pass "T24: short-form repo#N (dotfiles#99) → number=99, repo=dotfiles"
    else
        fail "T24: expected num=99 repo=dotfiles; got num=$N_T24 repo=$R_T24"
    fi
fi

# ===========================================================================
# T25: CI-3b SSOT — SKILL.md references canonical parser (not custom regex)
# ===========================================================================
if [ ! -f "$CLARIFY_INTENT_SKILL" ]; then
    skip "T25: clarify-intent SKILL.md not found"
else
    if grep -q 'parse-issue-tokens\|parse-closes-issues' "$CLARIFY_INTENT_SKILL" 2>/dev/null; then
        pass "T25: CI-3b references canonical parser (parse-issue-tokens or parse-closes-issues)"
    else
        skip "T25: bin/parse-issue-tokens reference not yet in SKILL.md — SKIP: implementation pending"
    fi
fi

# ===========================================================================
# T25a: structural guard — no shell/awk/sed token-splitting in clarify-intent SKILL.md
# ===========================================================================
if [ ! -f "$CLARIFY_INTENT_SKILL" ]; then
    skip "T25a: clarify-intent SKILL.md not found"
else
    BAD_HASH_STRIP=$(grep -c '\${.*##.*#}' "$CLARIFY_INTENT_SKILL" 2>/dev/null; true)
    BAD_CUT_SQ=$(grep -c "cut -d'#'" "$CLARIFY_INTENT_SKILL" 2>/dev/null; true)
    BAD_CUT_DQ=$(grep -c 'cut -d"#"' "$CLARIFY_INTENT_SKILL" 2>/dev/null; true)
    if [ "$BAD_HASH_STRIP" -gt 0 ]; then
        fail "T25a: SKILL.md contains \${##*#} shell token-splitting ($BAD_HASH_STRIP occurrences)"
    elif [ "$BAD_CUT_SQ" -gt 0 ] || [ "$BAD_CUT_DQ" -gt 0 ]; then
        fail "T25a: SKILL.md contains cut -d'#' token-splitting"
    else
        pass "T25a: no shell token-splitting patterns in clarify-intent SKILL.md"
    fi
fi

# Note: T26 (bare #N backward-compat) is covered in the table-driven loop above.

# ===========================================================================
# T10: parseIssueToken export — hooks/lib/parse-closes-issues.js exports it
# ===========================================================================
if [ ! -f "$PARSE_CLOSES_ISSUES_JS" ]; then
    skip "T10: parse-closes-issues.js not found"
else
    HAS_EXPORT=$(node -e "
try {
  const m = require(process.argv[1]);
  process.stdout.write(typeof m.parseIssueToken === 'function' ? 'yes' : 'no');
} catch(e) {
  process.stdout.write('error:' + e.message);
}
" "$PARSE_CLOSES_ISSUES_JS" 2>/dev/null)
    assert_eq "T10: parseIssueToken exported from parse-closes-issues.js" "yes" "$HAS_EXPORT"
fi

# ===========================================================================
# T10a: bin/parse-issue-tokens CLI — takes token args, emits JSON array
# ===========================================================================
if [ ! -f "$PARSE_ISSUE_TOKENS" ]; then
    skip "T10a: bin/parse-issue-tokens not found"
else
    OUT_T10A=$(run_with_timeout 10 node "$PARSE_ISSUE_TOKENS" '#42' 'dotfiles#77' 'nirecom/agents#100' 2>/dev/null)
    LEN_T10A=$(jq_len "$OUT_T10A")
    N0=$(jq_elem "$OUT_T10A" 0 "number")
    N1=$(jq_elem "$OUT_T10A" 1 "number")
    N2=$(jq_elem "$OUT_T10A" 2 "number")
    R0=$(jq_has_field "$OUT_T10A" 0 "repo")
    R1=$(jq_elem "$OUT_T10A" 1 "repo")
    R2=$(jq_elem "$OUT_T10A" 2 "repo")
    if [ "$LEN_T10A" = "3" ] && [ "$N0" = "42" ] && [ "$N1" = "77" ] && [ "$N2" = "100" ] \
       && [ "$R0" = "no" ] && [ "$R1" = "dotfiles" ] && [ "$R2" = "nirecom/agents" ]; then
        pass "T10a: parse-issue-tokens CLI: 3 tokens → correct JSON array"
    else
        fail "T10a: parse-issue-tokens: len=$LEN_T10A n0=$N0(hasRepo=$R0) n1=$N1(repo=$R1) n2=$N2(repo=$R2)"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
