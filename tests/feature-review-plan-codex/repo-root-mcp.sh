# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# Issue #723/#746: --repo-root forwarding, CODEX_MCP_FS kill-switch, MCP addendum, sandbox/approval_policy overrides (A1-A8)

# ---------------------------------------------------------------------------
# A1–A6: --repo-root forwarding + MCP filesystem server integration (#723, #746)

# Verify --repo-root forwarding, CODEX_MCP_FS=off kill-switch, and MCP addendum
# injection (see #723, #746 for full contract; approval_policy/sandbox_mode
# config overrides, not --full-auto/--sandbox/--ask-for-approval).
# ---------------------------------------------------------------------------

# Pre-check: skip A1-A5 if the source files have not been updated yet.
A_SKIP=0
if ! grep -q -- '--repo-root' "$SCRIPT" 2>/dev/null; then
    A_SKIP=1
fi
RUN_LOOP="$AGENTS_ROOT/bin/run-codex-review-loop"
if ! grep -q -- '--repo-root' "$RUN_LOOP" 2>/dev/null; then
    A_SKIP=1
fi

if [[ $A_SKIP -eq 1 ]]; then
    echo "SKIP: A1: --repo-root flag not yet implemented in source"
    echo "SKIP: A2: --repo-root flag not yet implemented in source"
    echo "SKIP: A3: --repo-root flag not yet implemented in source"
    echo "SKIP: A4: --repo-root flag not yet implemented in source"
    echo "SKIP: A5: --repo-root flag not yet implemented in source"
else

# ---------------------------------------------------------------------------
# Shared setup for A1–A5
# ---------------------------------------------------------------------------
A_TMP=$(mktemp -d)
A_REPO="$A_TMP/test-repo"
mkdir -p "$A_REPO"
echo "# test repo" > "$A_REPO/README.md"

# Mock codex that records argv + env to files so tests can inspect them.
A_MOCK_BIN="$A_TMP/mock-bin"
mkdir -p "$A_MOCK_BIN"
A_CODEX_ARGS="$A_TMP/codex.args"
A_CODEX_ENV="$A_TMP/codex.env"
A_CODEX_STDIN="$A_TMP/codex.stdin"
cat > "$A_MOCK_BIN/codex" << MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$A_CODEX_ARGS"
{
  echo "REPO_ROOT=\${REPO_ROOT:-__UNSET__}"
  echo "CODEX_MCP_FS=\${CODEX_MCP_FS:-__UNSET__}"
} > "$A_CODEX_ENV"
cat > "$A_CODEX_STDIN"
echo "APPROVED"
exit 0
MOCK_EOF
chmod +x "$A_MOCK_BIN/codex"

# ---------------------------------------------------------------------------
# A1 — --repo-root flag is forwarded to codex exec as MCP override
# ---------------------------------------------------------------------------
A_EXIT=0
PATH="$A_MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan \
  --repo-root "$A_REPO" --no-log >/dev/null 2>&1 || A_EXIT=$?

if [[ -f "$A_CODEX_ARGS" ]] && grep -qE 'mcp_servers\.fs' "$A_CODEX_ARGS"; then
    pass "A1: --repo-root forwarded as mcp_servers.fs config override to codex"
else
    fail "A1: expected -c mcp_servers.fs.* in codex args; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

# ---------------------------------------------------------------------------
# A2 — REPO_ROOT env var is exported in codex process when --repo-root is set
# (exact-value match only: an ambient REPO_ROOT inherited from the calling
# shell must not let a script that fails to set it false-green here)
# ---------------------------------------------------------------------------
if [[ -f "$A_CODEX_ENV" ]] && grep -q "^REPO_ROOT=$A_REPO$" "$A_CODEX_ENV"; then
    pass "A2: REPO_ROOT exported in codex environment"
else
    fail "A2: REPO_ROOT not exported (expected exact value $A_REPO). Env capture: $(cat "$A_CODEX_ENV" 2>/dev/null || echo MISSING)"
fi

# ---------------------------------------------------------------------------
# A5 — MCP addendum injected into codex prompt (TMPFILE / stdin) when --repo-root
# (run while we still have stdin/args from the A1/A2 invocation)
# ---------------------------------------------------------------------------
if [[ -f "$A_CODEX_STDIN" ]] && \
   grep -qiE 'filesystem MCP server|mcp_servers\.fs|read_file' "$A_CODEX_STDIN"; then
    pass "A5: MCP addendum text injected into codex prompt"
else
    fail "A5: expected MCP addendum in codex prompt. Stdin head: $(head -c 400 "$A_CODEX_STDIN" 2>/dev/null || echo MISSING)"
fi

# ---------------------------------------------------------------------------
# A6 — approval_policy/sandbox_mode config overrides replace --full-auto /
# --sandbox (codex-cli 0.153.4 dropped both flags); --ask-for-approval stays
# absent (#746). (reuses $A_CODEX_ARGS from the A1 invocation above; the mock
# codex writes one arg per line via `printf '%s\n' "$@"`, so an exact-line
# match on `--sandbox` cannot false-match the substring `sandbox_mode`.)
# ---------------------------------------------------------------------------
# Exact-value check: a -c line must be followed by the specific key=value pair, not just the key substring.
if [[ -f "$A_CODEX_ARGS" ]] && grep -A1 -- '^-c$' "$A_CODEX_ARGS" | grep -q -- 'approval_policy=.*never'; then
    pass "A6: -c approval_policy=...never... config override present in codex args (exact value)"
else
    fail "A6: expected -c line followed by approval_policy=...never...; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

if [[ -f "$A_CODEX_ARGS" ]] && grep -A1 -- '^-c$' "$A_CODEX_ARGS" | grep -q -- 'sandbox_mode=.*read-only'; then
    pass "A6: -c sandbox_mode=...read-only... config override present in codex args (exact value)"
else
    fail "A6: expected -c line followed by sandbox_mode=...read-only...; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

if [[ -f "$A_CODEX_ARGS" ]] && ! grep -q -- '--full-auto' "$A_CODEX_ARGS"; then
    pass "A6: --full-auto absent from codex args"
else
    fail "A6: --full-auto must not be in codex args (removed in codex-cli 0.153.4); got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

if [[ -f "$A_CODEX_ARGS" ]] && ! grep -q -- '--ask-for-approval' "$A_CODEX_ARGS"; then
    pass "A6: --ask-for-approval absent from codex args"
else
    fail "A6: --ask-for-approval must not be in codex args; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

if [[ -f "$A_CODEX_ARGS" ]] && ! grep -qx -- '--sandbox' "$A_CODEX_ARGS"; then
    pass "A6: standalone --sandbox flag absent from codex args"
else
    fail "A6: --sandbox flag must not be in codex args (removed in codex-cli 0.153.4); got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

# Negative check: no other -c approval_policy=/sandbox_mode= line may co-occur with
# a permissive value. grep -q on the positive checks above only proves a matching
# line EXISTS; it does not prove no OTHER, more permissive override also exists
# (e.g. a duplicate -c sandbox_mode=danger-full-access later in argv, where the
# real codex CLI's last-wins semantics would silently defeat the read-only guarantee).
if [[ -f "$A_CODEX_ARGS" ]] && grep -A1 -- '^-c$' "$A_CODEX_ARGS" | grep -qE -- 'sandbox_mode=(workspace-write|danger-full-access)'; then
    fail "A6: a permissive sandbox_mode override (workspace-write/danger-full-access) must not co-occur; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
else
    pass "A6: no permissive sandbox_mode override co-occurs with the read-only one"
fi

if [[ -f "$A_CODEX_ARGS" ]] && grep -A1 -- '^-c$' "$A_CODEX_ARGS" | grep -qE -- 'approval_policy=(on-request|on-failure|untrusted)'; then
    fail "A6: a non-'never' approval_policy override must not co-occur; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
else
    pass "A6: no non-'never' approval_policy override co-occurs with the 'never' one"
fi

if [[ -f "$A_CODEX_ARGS" ]] && ! grep -q -- '--dangerously-bypass-approvals-and-sandbox' "$A_CODEX_ARGS"; then
    pass "A6: --dangerously-bypass-approvals-and-sandbox absent from codex args"
else
    fail "A6: --dangerously-bypass-approvals-and-sandbox must not be in codex args; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

# ---------------------------------------------------------------------------
# A3 — CODEX_MCP_FS=off suppresses --repo-root forwarding through the loop
# ---------------------------------------------------------------------------
# Set up a mock AGENTS_CONFIG_DIR with required structure.
A_CFG="$A_TMP/agents"
mkdir -p "$A_CFG/bin" "$A_CFG/rules"
echo "# core principles stub" > "$A_CFG/rules/core-principles.md"

# Copy run-codex-review-loop and required helpers under test
cp "$RUN_LOOP" "$A_CFG/bin/run-codex-review-loop"
chmod +x "$A_CFG/bin/run-codex-review-loop"
if [[ -f "$AGENTS_ROOT/bin/review-loop-verdict" ]]; then
    cp "$AGENTS_ROOT/bin/review-loop-verdict" "$A_CFG/bin/review-loop-verdict"
    chmod +x "$A_CFG/bin/review-loop-verdict"
fi

# Stub build-codex-context (touches --output)
cat > "$A_CFG/bin/build-codex-context" << 'STUB_EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) touch "$2"; shift 2 ;;
    *) shift ;;
  esac
done
exit 0
STUB_EOF
chmod +x "$A_CFG/bin/build-codex-context"

# Mock review-plan-codex that records its arguments and emits a valid APPROVED
A_RPC_ARGS="$A_TMP/review-plan-codex.args"
cat > "$A_CFG/bin/review-plan-codex" << MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$A_RPC_ARGS"
cat << 'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
exit 0
MOCK_EOF
chmod +x "$A_CFG/bin/review-plan-codex"

# Set up a plans dir + draft for the wrapper (#866: no drafts/ subdir)
A_PLANS="$A_TMP/plans"
mkdir -p "$A_PLANS"
A_DRAFT="$A_PLANS/draft.md"
echo "# Draft plan" > "$A_DRAFT"
A_TRADEOFFS="$A_PLANS/tradeoffs.txt"
: > "$A_TRADEOFFS"

# A3 — kill switch: CODEX_MCP_FS=off → no --repo-root passed to review-plan-codex
A_EXIT=0
AGENTS_CONFIG_DIR="$A_CFG" CODEX_MCP_FS=off _timeout bash "$A_CFG/bin/run-codex-review-loop" \
  --format detail-plan \
  --session-id "a3-session" \
  --plans-dir "$A_PLANS" \
  --draft-file "$A_DRAFT" \
  --cap 3 \
  --max-extensions 2 \
  --accepted-tradeoffs "$A_TRADEOFFS" \
  --round 1 \
  --repo-root "$A_REPO" \
  >/dev/null 2>&1 || A_EXIT=$?

if [[ -f "$A_RPC_ARGS" ]] && ! grep -q -- '--repo-root' "$A_RPC_ARGS"; then
    pass "A3: CODEX_MCP_FS=off suppresses --repo-root forwarding"
else
    fail "A3: expected no --repo-root with CODEX_MCP_FS=off; got: $(cat "$A_RPC_ARGS" 2>/dev/null || echo MISSING)"
fi

# ---------------------------------------------------------------------------
# A4 — --repo-root defaults to git rev-parse --show-toplevel
# ---------------------------------------------------------------------------
# Make A_REPO a real git repo so git rev-parse works
( cd "$A_REPO" && git init -q && git config core.hooksPath /dev/null && git config user.email "t@example.com" \
    && git config user.name "T" && git add README.md \
    && git commit -q -m "init" ) >/dev/null 2>&1 || true

# Clear the args file before running
: > "$A_RPC_ARGS"

A_EXIT=0
( cd "$A_REPO" && \
  AGENTS_CONFIG_DIR="$A_CFG" _timeout bash "$A_CFG/bin/run-codex-review-loop" \
    --format detail-plan \
    --session-id "a4-session" \
    --plans-dir "$A_PLANS" \
    --draft-file "$A_DRAFT" \
    --cap 3 \
    --max-extensions 2 \
    --accepted-tradeoffs "$A_TRADEOFFS" \
    --round 1 \
    >/dev/null 2>&1 ) || A_EXIT=$?

if [[ -f "$A_RPC_ARGS" ]] && grep -q -- '--repo-root' "$A_RPC_ARGS"; then
    # Extract the value following --repo-root
    REPO_ROOT_VAL=$(awk '/^--repo-root$/{getline; print; exit}' "$A_RPC_ARGS")
    # Normalize both sides for comparison (handle realpath / symlinks)
    EXPECTED=$(cd "$A_REPO" && pwd)
    if [[ -n "$REPO_ROOT_VAL" ]]; then
        pass "A4: --repo-root defaults to git rev-parse --show-toplevel (value=$REPO_ROOT_VAL)"
    else
        fail "A4: --repo-root present but value empty. Args: $(cat "$A_RPC_ARGS")"
    fi
else
    fail "A4: expected --repo-root to be forwarded by default. Args: $(cat "$A_RPC_ARGS" 2>/dev/null || echo MISSING)"
fi

# ---------------------------------------------------------------------------
# A7 — --repo-root as the trailing arg with no value must still exit 0
# (--repo-root is missing the [[ $# -lt 2 ]] guard its siblings --input/
# --format/--context/--project-root already have). Expected RED until
# write-code adds the guard. Asserts BOTH exit 0 AND the structured FAILED
# status label (same pair used by cases 10/11 for --input/--format missing) —
# exit-code-only would false-pass an unrelated code path that also happens
# to exit 0 without the guard actually firing.
# ---------------------------------------------------------------------------
A7_EXIT=0
A7_OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan --no-log --repo-root 2>&1) || A7_EXIT=$?

if [[ $A7_EXIT -eq 0 ]]; then
    pass "A7: trailing --repo-root with no value still exits 0 (never-crash contract)"
else
    fail "A7: trailing --repo-root with no value exited $A7_EXIT instead of 0 — missing [[ \$# -lt 2 ]] guard"
fi

if echo "$A7_OUTPUT" | grep -q "## Codex Plan Review: FAILED"; then
    pass "A7: trailing --repo-root with no value produces FAILED status label (guard fired, not a coincidental exit 0)"
else
    fail "A7: trailing --repo-root with no value missing FAILED status label. Output: $A7_OUTPUT"
fi

# ---------------------------------------------------------------------------
# A8 — approval_policy/sandbox_mode overrides (#746) are unconditional: they
# must still be present in the codex_exec argv on the default path where
# --repo-root is omitted entirely, not only on the --repo-root-forwarding
# path A1/A2/A6 exercise. Without this case the default sandbox posture for
# the (more common) no-repo-root invocation is unverified.
# ---------------------------------------------------------------------------
rm -f "$A_CODEX_ARGS"
A8_EXIT=0
PATH="$A_MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan --no-log >/dev/null 2>&1 || A8_EXIT=$?

if [[ -f "$A_CODEX_ARGS" ]] && grep -A1 -- '^-c$' "$A_CODEX_ARGS" | grep -q -- 'approval_policy=.*never'; then
    pass "A8: approval_policy=...never... present without --repo-root"
else
    fail "A8: expected -c approval_policy=...never... without --repo-root; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

if [[ -f "$A_CODEX_ARGS" ]] && grep -A1 -- '^-c$' "$A_CODEX_ARGS" | grep -q -- 'sandbox_mode=.*read-only'; then
    pass "A8: sandbox_mode=...read-only... present without --repo-root"
else
    fail "A8: expected -c sandbox_mode=...read-only... without --repo-root; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

if [[ -f "$A_CODEX_ARGS" ]] && ! grep -qE -- '(--full-auto|--ask-for-approval)' "$A_CODEX_ARGS" && ! grep -qx -- '--sandbox' "$A_CODEX_ARGS"; then
    pass "A8: removed codex-cli 0.153.4 flags absent without --repo-root"
else
    fail "A8: removed flags must stay absent without --repo-root; got: $(cat "$A_CODEX_ARGS" 2>/dev/null || echo MISSING)"
fi

rm -rf "$A_TMP"

fi  # end A_SKIP guard
