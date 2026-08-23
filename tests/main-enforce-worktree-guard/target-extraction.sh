# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, bin, supervisor, scope:common
# Sourced by tests/main-enforce-worktree-guard.sh
# Origin: tests/fix-bash-rm-target-extraction.sh (all cases),
#         tests/feature-supervisor-bin-tool-allow.sh (all cases),
#         tests/fix-enforce-worktree-bundle-a.sh (extraction security cases;
#         its EXCLUDE/session-scope cases are in exclude-and-session-scope.sh).
# Cases: R1-R7, R_Q*, R_LONG, R_EMPTY, R_DD, R_TRAVERSAL, T1-T4, SECURITY:*.
# One axis: which write targets a Bash command string yields, and whether every
# extracted target falls outside session scope (allow) or any one lands in (block).

TE_MAIN_WT="$(main_worktree_dir)"
TE_MAIN_WT_NODE="$(to_node_path "$TE_MAIN_WT")"
TE_NON_REPO_BASE="$TMPDIR_BASE/rm-target-$$"

# $1=label $2=allow|block $3=command string. CWD is the real main worktree, so
# relative targets resolve in-repo — R7 and R_Q_REL depend on that.
te_run_case() {
    local label="$1" expect="$2" cmd="$3"
    local out; out="$(run_bash_guard "$cmd" "$TE_MAIN_WT" ENFORCE_WORKTREE=on)"
    if [ "$expect" = "allow" ]; then
        if guard_allows "$out"; then pass "$label"; else fail "$label (out=$out)"; fi
    else
        if guard_blocks "$out"; then pass "$label"; else fail "$label (out=$out)"; fi
    fi
}

if [ -z "$TE_MAIN_WT" ] || [ ! -d "$TE_MAIN_WT" ]; then
    fail "target-extraction: cannot resolve main worktree path"
else
    te_run_case "R1: rm of non-repo absolute path → allow" \
        allow "rm ${TE_NON_REPO_BASE}/scratch.md"
    te_run_case "R2: rm of in-repo absolute path → blocked" \
        block "rm ${TE_MAIN_WT_NODE}/README.md"
    te_run_case "R3: rm -rf on non-repo path → allow" \
        allow "rm -rf ${TE_NON_REPO_BASE}/sub"
    te_run_case "R4: multiple non-repo targets → allow" \
        allow "rm ${TE_NON_REPO_BASE}/a ${TE_NON_REPO_BASE}/b"
    te_run_case "R5: mixed non-repo + in-repo → blocked" \
        block "rm ${TE_NON_REPO_BASE}/a ${TE_MAIN_WT_NODE}/README.md"
    te_run_case "R6: unresolvable token → blocked" \
        block 'rm $SOMEVAR/foo'
    te_run_case "R7: relative in-repo path → blocked" \
        block "rm README.md"
    te_run_case "R_Q: quoted in-repo path with spaces → blocked" \
        block "rm \"${TE_MAIN_WT_NODE}/path with spaces/file\""
    te_run_case "R_Q2: double-quoted non-repo path with space → allow" \
        allow "rm \"${TE_NON_REPO_BASE}/quoted file.md\""
    te_run_case "R_Q3: single-quoted non-repo path → allow" \
        allow "rm '/tmp/claude-rm-test-single/path.md'"
    te_run_case "R_Q4: flag + double-quoted non-repo path with space → allow" \
        allow "rm -rf \"${TE_NON_REPO_BASE}/sub dir\""
    te_run_case "R_Q5: mixed unquoted + quoted non-repo targets → allow" \
        allow "rm ${TE_NON_REPO_BASE}/a \"${TE_NON_REPO_BASE}/b c\""
    te_run_case "R_Q_SEMI: rm \"a;b.md\" → blocked (outer regex truncates at ;)" \
        block 'rm "a;b.md"'
    te_run_case "R_Q_BSLASH: rm \"foo\\\"bar.md\" → blocked (backslash escape not handled)" \
        block 'rm "foo\"bar.md"'
    te_run_case "R_Q_single_in_repo: single-quoted in-repo path with spaces → blocked" \
        block "rm '${TE_MAIN_WT_NODE}/path with spaces/file'"
    te_run_case "R_LONG: rm --recursive --force non-repo path → allow" \
        allow "rm --recursive --force ${TE_NON_REPO_BASE}/sub"
    te_run_case "R_EMPTY: rm -rf with no positionals → blocked" \
        block "rm -rf"
    te_run_case "R_DD: rm -- README.md → blocked" \
        block "rm -- README.md"
    te_run_case "R_Q6: multiple double-quoted non-repo targets → allow" \
        allow "rm \"${TE_NON_REPO_BASE}/a\" \"${TE_NON_REPO_BASE}/b c\""
    te_run_case "R_Q7: mixed double-quoted with in-repo target → blocked" \
        block "rm \"${TE_NON_REPO_BASE}/a\" \"${TE_MAIN_WT_NODE}/README.md\""
    te_run_case "R_Q_REL: rm \"README.md\" (double-quoted relative in-repo) → blocked" \
        block 'rm "README.md"'
    # CWD is the main worktree, so "../<repo-name>/README.md" resolves back in-repo.
    te_repo_name="$(basename "${TE_MAIN_WT_NODE}")"
    te_run_case "R_TRAVERSAL: rm \"../<repo>/README.md\" traversal → blocked" \
        block "rm \"../${te_repo_name}/README.md\""
fi

# T1-T4 run against a synthetic main checkout, not the real worktree: the point
# is the redirect target's location relative to THAT repo. AGENTS_CONFIG_DIR is
# pointed at an empty fake so the command text is all the hook has to go on.
te_fake_acd() {
    local d="$TMPDIR_BASE/fake-acd-$1-$$"
    mkdir -p "$d/bin"
    echo "$d"
}

# T1: target /tmp/sup-output.jsonl is outside every session repo → universal
# target-allow fires even though CWD is a main checkout.
te_repo="$(setup_main_checkout "sup-rc-main")"
te_out="$(run_bash_guard \
    'bash "$AGENTS_CONFIG_DIR/bin/supervisor-review-codex" --generate > /tmp/sup-output.jsonl' \
    "$te_repo" ENFORCE_WORKTREE=on "AGENTS_CONFIG_DIR=$(te_fake_acd t1)")"
if guard_decision "$te_out"; then
    pass "T1: bash supervisor-review-codex --generate >/tmp/out.jsonl from main worktree: allow"
else
    fail "T1: bash supervisor-review-codex --generate >/tmp/out.jsonl should allow (target outside session), got: $te_out"
fi

# T2: node invocation with no redirect — no write target is visible to the hook,
# so it classifies as read-only and passes through.
te_repo="$(setup_main_checkout "sup-wa-main")"
te_out="$(run_bash_guard \
    'node "$AGENTS_CONFIG_DIR/bin/supervisor-write-alert" --severity error --detail "test finding" --session-id abc123' \
    "$te_repo" ENFORCE_WORKTREE=on "AGENTS_CONFIG_DIR=$(te_fake_acd t2)")"
if guard_decision "$te_out"; then
    pass "T2: node supervisor-write-alert from main worktree: allow (no write targets)"
else
    fail "T2: node supervisor-write-alert should allow (read-only from hook perspective), got: $te_out"
fi

# T3: same command as T1 with the redirect aimed inside the repo → must block.
# Without this, T1 could pass because the hook stopped inspecting supervisor bins.
te_repo="$(setup_main_checkout "sup-rc-block")"
te_out="$(run_bash_guard \
    "bash \"\$AGENTS_CONFIG_DIR/bin/supervisor-review-codex\" --generate > $te_repo/output.jsonl" \
    "$te_repo" ENFORCE_WORKTREE=on "AGENTS_CONFIG_DIR=$(te_fake_acd t3)")"
if guard_decision "$te_out"; then
    fail "T3: bash supervisor-review-codex writing into repo should block (main worktree), got allow: $te_out"
else
    pass "T3: bash supervisor-review-codex writing into repo from main worktree: block (regression guard)"
fi

# T4: no redirect at all → no write target → allow.
te_repo="$(setup_main_checkout "sup-rc-noredirect")"
te_out="$(run_bash_guard \
    'bash "$AGENTS_CONFIG_DIR/bin/supervisor-review-codex" --list' \
    "$te_repo" ENFORCE_WORKTREE=on "AGENTS_CONFIG_DIR=$(te_fake_acd t4)")"
if guard_decision "$te_out"; then
    pass "T4: bash supervisor-review-codex --list (no redirect) from main worktree: allow"
else
    fail "T4: bash supervisor-review-codex --list should allow (no write target), got: $te_out"
fi

# A staged filename can carry a `;` the same way a command string can. Extraction
# must treat it as one literal name: it does not match the EXCLUDE glob, so the
# commit blocks — and the point of the case is that it blocks without crashing.
te_repo="$(setup_main_checkout "SEC-staged")"
echo "data" > "$te_repo/trick;name.md"
git -C "$te_repo" add "trick;name.md"
te_out="$(run_bash_guard "git commit -m x" "$te_repo" \
    ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=*.local")"
assert_decision block "$te_out" \
    "SECURITY: staged tricky-name without exclude match blocks (no crash)" \
    "SECURITY: staged tricky-name without exclude match should block"

# Extraction must cover EVERY segment of a compound command. Scoring only the
# first segment would allow these two: the leading redirect is out of session
# scope, but the trailing `rm` deletes an in-session file.
te_in="$(setup_main_checkout "SEC-comp-semi")"
te_non="$(setup_main_checkout "SEC-comp-semi-ns")"
te_out="$(run_bash_guard "echo x > $te_non/README.md; rm $te_in/README.md" \
    "$te_in" ENFORCE_WORKTREE=on)"
assert_decision block "$te_out" \
    "SECURITY: compound ';' cmd with non-session redirect blocks" \
    "SECURITY: compound ';' cmd should block to prevent rm side-effect"

te_in="$(setup_main_checkout "SEC-comp-and")"
te_non="$(setup_main_checkout "SEC-comp-and-ns")"
te_out="$(run_bash_guard "echo x > $te_non/README.md && rm $te_in/README.md" \
    "$te_in" ENFORCE_WORKTREE=on)"
assert_decision block "$te_out" \
    "SECURITY: compound '&&' cmd with non-session redirect blocks" \
    "SECURITY: compound '&&' cmd should block to prevent rm side-effect"

# The pair to the two above: the compound fix must not have swept up the plain
# single-segment redirect, which is still an out-of-scope write.
te_in="$(setup_main_checkout "SEC-comp-simple")"
te_non="$(setup_main_checkout "SEC-comp-simple-ns")"
te_out="$(run_bash_guard "echo x > $te_non/README.md" "$te_in" ENFORCE_WORKTREE=on)"
assert_decision allow "$te_out" \
    "SECURITY: simple redirect to non-session still allows" \
    "SECURITY: simple redirect should still allow after compound fix"

# Completion marker (dispatcher FRAG2) — must remain the last line.
frag_done "target-extraction.sh"
