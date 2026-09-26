# Part C (gates) — agents-repo gates driven against the REAL checkers (C1a-C1e).
# Sourced by tests/hooks/feature-1834-precommit-lib-split.sh; shares its helpers/globals.

echo ""
echo "=== Part C: agents-repo gates (real checkers) ==="

# C1a: session-id SSOT gate VIOLATION — a direct process.env.CLAUDE_SESSION_ID read
# in an in-scope tracked file must block with the session-id diagnostic.
case_begin "C1a-session-id-violation" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1a"; mk_agents_fixture "$R"
printf 'const x = process.env.CLAUDE_SESSION_ID;\n' > "$R/hooks/leak.js"
git -C "$R" add -- hooks/leak.js >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 1 ]; then
    fail "C1a: session-id gate" "want rc 1, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif ! printf '%s' "$GOUT" | grep -qF "$SID_MSG"; then
    fail "C1a: session-id gate" "output lacks the session-id block message [$SID_MSG]"
else
    pass "C1a: a direct session-id env read blocks the commit with the session-id diagnostic"
fi
case_end

# C1b: migration-block gate VIOLATION — a temporary block whose description lacks the
# arrow/`migration` keyword must block with the migration diagnostic (session-id clean,
# so the migration gate is actually reached).
case_begin "C1b-migration-violation" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1b"; mk_agents_fixture "$R"
printf '%s\n' '# --- BEGIN temporary: just a description ---' 'x=1' '# --- END temporary: ---' > "$R/foo.sh"
git -C "$R" add -- foo.sh >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 1 ]; then
    fail "C1b: migration gate" "want rc 1, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif ! printf '%s' "$GOUT" | grep -qF "$MIG_MSG"; then
    fail "C1b: migration gate" "output lacks the migration block message [$MIG_MSG]"
else
    pass "C1b: a malformed migration block blocks the commit with the migration diagnostic"
fi
case_end

# C1c: session-id gate CLEAN — a file with no direct read must not be blocked
# (CPR-ORTH non-targeted verdict: no false-positive over-blocking).
case_begin "C1c-session-id-clean" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1c"; mk_agents_fixture "$R"
printf 'const x = 1;\n' > "$R/hooks/ok.js"
git -C "$R" add -- hooks/ok.js >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 0 ]; then
    fail "C1c: session-id clean" "want rc 0, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$SID_MSG"; then
    fail "C1c: session-id clean" "session-id block message [$SID_MSG] fired on sanctioned input"
else
    pass "C1c: a file with no direct session-id read is not blocked (no over-blocking)"
fi
case_end

# C1d: migration gate CLEAN — a file with no temporary block must not be blocked.
case_begin "C1d-migration-clean" "hooks/lib/precommit-agents-repo-gates.sh"
R="$TMPBASE/c1d"; mk_agents_fixture "$R"
printf 'plain content, no temporary block\n' > "$R/foo.sh"
git -C "$R" add -- foo.sh >/dev/null 2>&1
run_agents_gates "$R" "$R"
if [ "$GRC" -ne 0 ]; then
    fail "C1d: migration clean" "want rc 0, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$MIG_MSG"; then
    fail "C1d: migration clean" "migration block message [$MIG_MSG] fired on sanctioned input"
else
    pass "C1d: a file with no migration block is not blocked (no over-blocking)"
fi
case_end

# C1e: NON-agents repo no-op — a repo whose common-dir does NOT match AGENTS_CONFIG_DIR
# must have ALL gates skipped even with content that WOULD trip a gate. The whole
# function shares this guard, so the on-demand gate's no-op is transitively covered
# here (and directly in cc-pre-commit-on-demand-rules.sh W6); one case suffices.
case_begin "C1e-non-agents-repo-noop" "hooks/lib/precommit-agents-repo-gates.sh"
CFG="$TMPBASE/c1e-cfg"; mk_agents_fixture "$CFG"
OTHER="$TMPBASE/c1e-other"; init_repo_bare "$OTHER"
printf 'init\n' > "$OTHER/README.md"
git -C "$OTHER" add README.md >/dev/null 2>&1
git -C "$OTHER" commit -q -m initial >/dev/null 2>&1
printf 'const x = process.env.CLAUDE_SESSION_ID;\n' > "$OTHER/leak.js"
git -C "$OTHER" add -- leak.js >/dev/null 2>&1
run_agents_gates "$OTHER" "$CFG"
if [ "$GRC" -ne 0 ]; then
    fail "C1e: non-agents no-op" "want rc 0, got $GRC — out: $(printf '%s' "$GOUT" | tr '\n' ' ')"
elif printf '%s' "$GOUT" | grep -qF "$SID_MSG"; then
    fail "C1e: non-agents no-op" "a gate fired in a repo whose common-dir does not match AGENTS_CONFIG_DIR"
else
    pass "C1e: gates are skipped in a non-agents repo even with gate-tripping content"
fi
case_end
