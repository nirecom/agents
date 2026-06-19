# Fixture helpers for tests/feature-973-review-e2e-coverage.sh.
# Sourced by the dispatcher; reads AGENTS_ROOT / SCRIPT / TMPDIR_BASE /
# EMPTY_HOOKS_DIR / EMPTY_EXCLUDES / fail / pass / run_with_timeout from scope.

# Canonical Hook Audit table fixture. Mirrors the shape of rules/test/claude-e2e.md
# closely enough for the parser, including the two newest siblings
# (stop-askuserquestion-required.js, stop-enforce-worktree-on-warn.js) so the
# fixture stays representative of the real rules file.
write_hook_audit_md() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
# Claude Code E2E Testing

Stub fixture for review-e2e-coverage tests.

## Hook Audit (in scope for #943)

| Hook | Current L2 | Priority | Rationale |
|---|---|---|---|
| `hooks/workflow-mark.js` | partial (`tests/feature-robust-workflow/settings-e2e.sh` — RUN_E2E-gated) | **P1 — extract** | E2E exists but is gated by RUN_E2E. |
| `hooks/stop-confirm-plan-guard.js` | none | **P1 — add** | Stop-hook sentinel-order validation. |
| `hooks/stop-final-report-guard.js` | extensive | **P2 — add E2E** | L2 cannot exercise real Stop-event path. |
| `hooks/session-start.js` | partial | **P2 — add E2E** | env-file write covered at L2. |
| `hooks/stop-askuserquestion-required.js` | none | **P2 — add E2E** | Stop-hook AskUserQuestion validation. |
| `hooks/subagent-start.js` | none | **P3 — add** | Sub-agent context injection. |
| `hooks/post-compact.js` | none | **P3 — add** | PostCompact event not reproducible at L2. |
| `hooks/stop-enforce-worktree-on-warn.js` | none | **P3 — add** | Worktree enforcement warning path. |
| `hooks/supervisor-guard.js` | L2-only | **OUT — defer** | No observable user-facing signal under claude -p. |
EOF
}

write_hook_audit_md_broken_header() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
# Claude Code E2E Testing

## Hook Audit (in scope for #943)

| HookName | L2-Status | PriorityClassification | Notes |
|---|---|---|---|
| `hooks/workflow-mark.js` | partial | **P1 — extract** | E2E exists. |
EOF
}

write_hook_audit_md_missing_heading() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
# Claude Code E2E Testing

No Hook Audit section here.
EOF
}

write_hook_stub() {
    local repo="$1" name="$2"
    mkdir -p "$repo/hooks"
    cat > "$repo/hooks/$name" <<EOF
// Stub hook for $name
module.exports = function() {};
EOF
}

write_e2e_test_for_hook() {
    local path="$1" hook_stem="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
#!/bin/bash
# Tests: hooks/${hook_stem}.js
# Tags: scope:issue-specific, e2e
[ -x "\$AGENTS_DIR/bin/get-config-var" ] || exit 77
"\$AGENTS_DIR/bin/get-config-var" --is-off RUN_E2E off && exit 77
command -v claude >/dev/null 2>&1 || exit 77
unset CLAUDECODE
# Reference: hooks/${hook_stem}.js
claude -p --output-format json --session-id 00000000-0000-0000-0000-000000000000 "test"
EOF
}

# Fresh isolated git repo with the real review-e2e-coverage script copied in.
make_repo() {
    local repo
    repo=$(mktemp -d -p "$TMPDIR_BASE")
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.excludesFile "$EMPTY_EXCLUDES"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" checkout -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    mkdir -p "$repo/bin" "$repo/hooks" "$repo/tests" "$repo/rules/test"
    cp "$SCRIPT" "$repo/bin/review-e2e-coverage"
    chmod +x "$repo/bin/review-e2e-coverage" || true
    write_hook_audit_md "$repo/rules/test/claude-e2e.md"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

run_script() {
    local repo="$1"; shift
    (cd "$repo" && run_with_timeout bash "$repo/bin/review-e2e-coverage" "$@" 2>&1)
}
