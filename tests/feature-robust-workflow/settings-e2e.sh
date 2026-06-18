# ---------------------------------------------------------------------------
# settings.json — hook registration structure
# ---------------------------------------------------------------------------

echo ""
echo "=== settings.json: hook registration structure ==="

# SR1: hooks.PostToolUse exists
# Pass SETTINGS via argv (not embedded in -e string) so MSYS2 translates the path on Windows.
if node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); process.exit(s.hooks && s.hooks.PostToolUse ? 0 : 1);" -- "$SETTINGS" 2>/dev/null; then
    pass "SR1. hooks.PostToolUse exists"
else
    fail "SR1. hooks.PostToolUse missing — workflow-mark.js will never be called"
fi

# SR2: hooks.PostToolUse[0].matcher === "Bash"
if node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); const pt=s.hooks&&s.hooks.PostToolUse; process.exit(pt&&pt[0]&&pt[0].matcher==='Bash' ? 0 : 1);" -- "$SETTINGS" 2>/dev/null; then
    pass "SR2. hooks.PostToolUse[0].matcher === \"Bash\""
else
    fail "SR2. hooks.PostToolUse[0].matcher is not \"Bash\""
fi

# SR3: hooks.PostToolUse[0].hooks[0].command references workflow-mark.js
if node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); const pt=s.hooks&&s.hooks.PostToolUse; const cmd=pt&&pt[0]&&pt[0].hooks&&pt[0].hooks[0]&&pt[0].hooks[0].command||''; process.exit(cmd.includes('workflow-mark.js') ? 0 : 1);" -- "$SETTINGS" 2>/dev/null; then
    pass "SR3. hooks.PostToolUse command references workflow-mark.js"
else
    fail "SR3. hooks.PostToolUse command does not reference workflow-mark.js"
fi

# SR4: permissions.PostToolUse must NOT exist (placement guard)
if node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); process.exit(s.permissions&&s.permissions.PostToolUse ? 1 : 0);" -- "$SETTINGS" 2>/dev/null; then
    pass "SR4. permissions.PostToolUse absent (not misplaced)"
else
    fail "SR4. permissions.PostToolUse present — PostToolUse is misplaced inside permissions"
fi

# ---------------------------------------------------------------------------
# E2E: PostToolUse hook real invocation (requires RUN_E2E=on (.env))
# ---------------------------------------------------------------------------

echo ""
echo "=== E2E: PostToolUse hook real invocation ==="

if ! "$DOTFILES_DIR/bin/get-config-var" --is-off RUN_E2E off; then
    E1_SESSION_ID="e1e1e1e1-0000-0000-0000-000000000001"
    E1_REPO="$TMPDIR_BASE/e2e-e1-repo"

    # Setup: fresh git repo (no remote → isPrivateRepo() returns false)
    mkdir -p "$E1_REPO/.claude"
    git -C "$E1_REPO" init -q
    git -C "$E1_REPO" config user.email "test@example.com"
    git -C "$E1_REPO" config user.name "Test"

    # Write minimal settings.json: only PostToolUse hook, no disableBypassPermissionsMode
    # (disableBypassPermissionsMode:disable would neutralize --dangerously-skip-permissions)
    cat > "$E1_REPO/.claude/settings.json" << SETTINGS_EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node \"$DOTFILES_DIR/claude-global/hooks/workflow-mark.js\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

    E1_STATE_FILE="$WORKFLOW_DIR/$E1_SESSION_ID.json"

    # Run claude -p with a prompt that emits the workflow marker.
    # DOTFILES_DIR is exported so the hook command (node "$DOTFILES_DIR/...") resolves correctly.
    # --setting-sources project: only load <cwd>/.claude/settings.json (has PostToolUse hook).
    # --dangerously-skip-permissions: allows the echo command without interactive prompt.
    E1_OUTPUT=$(
        cd "$E1_REPO" &&
        unset CLAUDECODE &&
        DOTFILES_DIR="$DOTFILES_DIR" run_with_timeout \
        claude -p \
            'Run exactly this Bash command and nothing else: echo "<<WORKFLOW_MARK_STEP_research_complete>>"' \
            --session-id "$E1_SESSION_ID" \
            --setting-sources project \
            --dangerously-skip-permissions \
            --output-format text \
        2>&1
    )
    E1_EXIT=$?

    if [ -f "$E1_STATE_FILE" ]; then
        # Check that steps.research.status === "complete"
        E1_STATUS=$(node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
process.stdout.write((s.steps && s.steps.research && s.steps.research.status) || '');
" -- "$E1_STATE_FILE" 2>/dev/null)
        if [ "$E1_STATUS" = "complete" ]; then
            pass "E1. claude -p PostToolUse hook fires → research=complete in state file"
        else
            fail "E1. claude -p PostToolUse hook fired but research.status=\"$E1_STATUS\" (expected \"complete\"). State: $(node -e "process.stdout.write(require('fs').readFileSync(process.argv[1],'utf8'));" -- "$E1_STATE_FILE" 2>/dev/null)"
        fi
    else
        fail "E1. claude -p PostToolUse hook did not create state file $E1_STATE_FILE. claude exit=$E1_EXIT output: $E1_OUTPUT"
    fi
else
    echo "SKIP: E1. claude -p E2E (set RUN_E2E=on in .env to enable)"
fi
