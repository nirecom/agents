# shellcheck shell=bash
# Tests: settings.json, .env.example, bin/review-env-example
# Tags: codegraph, wiring, static, permissions, env-flag, TL2, pwsh-not-required, scope:issue-specific
# W8 — settings.json permission granularity (ST-10). The assertion is about the
# COMPLETE set of CodeGraph-prefixed entries in permissions.allow, not about any one
# entry: rejecting only the wildcard would still accept a second, broader codegraph
# permission slipped in beside the reviewed one, or the same entry listed twice.
# Parsed as JSON so the claim is about permissions.allow and not about a string that
# happens to appear somewhere in the file.

echo "=== W8: settings.json permissions.allow granularity ==="

SETTINGS="$AGENTS_DIR/settings.json"
READ_ALLOW='const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const a=(s.permissions&&s.permissions.allow)||[];console.log(a.join("\n"));'
if ! command -v node >/dev/null 2>&1; then
    fail "W8-00: node is not on PATH" "settings.json must be read as JSON, not as text; this environment cannot run the check"
elif [ ! -f "$SETTINGS" ]; then
    fail "W8-00: settings.json is absent" "cannot read permissions.allow"
else
    ALLOW="$(bash "$AGENTS_DIR/bin/run-with-timeout.sh" 120 node -e "$READ_ALLOW" "$(nodepath "$SETTINGS")" 2>"$TMPDIR_LOCAL/w8.err" || true)"
    if [ -s "$TMPDIR_LOCAL/w8.err" ]; then
        fail "W8-00: could not parse settings.json" "$(head -1 "$TMPDIR_LOCAL/w8.err")"
    fi
    CG_ALLOW="$(printf '%s\n' "$ALLOW" | grep -F -e 'mcp__codegraph' || true)"
    CG_COUNT="$(printf '%s' "$CG_ALLOW" | grep -c . || true)"
    CG_SET="$(trim "$(printf '%s' "$CG_ALLOW" | tr '\n' ' ')")"
    assert_eq "W8-01: permissions.allow holds exactly one CodeGraph-prefixed entry" "1" "${CG_COUNT:-0}"
    assert_eq "W8-02: the complete CodeGraph-prefixed entry set is the one reviewed tool" \
        "mcp__codegraph__codegraph_explore" "${CG_SET:-<none>}"
    if printf '%s\n' "$CG_ALLOW" | grep -qF -e 'mcp__codegraph__*'; then
        fail "W8-03: permissions.allow holds the wildcard mcp__codegraph__*" \
             "the allowlist must match the tools: lines exactly (ST-10); a wildcard pre-approves tools nobody reviewed"
    else
        pass "W8-03: permissions.allow does not hold the wildcard mcp__codegraph__*"
    fi
fi

# W9 — the .env.example block. W1-01 only proves the variable is there. A block that
# trips a HARD finding blocks the workflow at commit time, and a second CODEGRAPH
# assignment makes the last one silently win over the documented default.
echo "=== W9: .env.example CodeGraph block, uniqueness and env-example rules ==="

ENV_EX="$AGENTS_DIR/.env.example"
REVIEWER="$AGENTS_DIR/bin/review-env-example"
CG_START="$(first_line_of "$ENV_EX" '# --- CodeGraph ---')"
CG_END="$(first_line_of "$ENV_EX" 'CODEGRAPH=off')"
if [ ! -f "$REVIEWER" ]; then
    fail "W9-01: bin/review-env-example is missing" "cannot verify the new block against the env-example rules"
elif [ -z "$CG_START" ] || [ -z "$CG_END" ]; then
    fail "W9-01: .env.example has no '# --- CodeGraph ---' section ending at a CODEGRAPH=off line" \
         "header=${CG_START:-<none>} assignment=${CG_END:-<none>}"
else
    RV_OUT="$(cd "$AGENTS_DIR" && bash "$AGENTS_DIR/bin/run-with-timeout.sh" 120 bash "$REVIEWER" --all 2>&1 || true)"
    BLOCK_HARD="$(printf '%s\n' "$RV_OUT" \
        | grep '^HARD:' \
        | grep -E '(^|/)\.env\.example:[0-9]+:' \
        | awk -v s="$CG_START" -v e="$CG_END" -F: '{ n = $3 + 0; if (n >= s && n <= e) print }' || true)"
    if [ -z "$BLOCK_HARD" ]; then
        pass "W9-01: no HARD env-example finding inside the CodeGraph block (lines $CG_START-$CG_END)"
    else
        fail "W9-01: bin/review-env-example reports HARD finding(s) inside the CodeGraph block" \
             "$(printf '%s' "$BLOCK_HARD" | tr '\n' ' ')"
    fi
fi

# W11 — the credential guards must be wired to the tool ST-10 pre-approved. Allowing
# mcp__codegraph__codegraph_explore without listing it in both PreToolUse matchers
# leaves a pre-approved tool that can name .env or ~/.ssh/id_rsa and never reach a
# guard (#2150 review). Parsed as JSON so the claim is about the matcher a hook is
# actually registered under, not about a string elsewhere in the file.
echo "=== W11: both credential guards match the CodeGraph explore tool ==="

READ_MATCHERS='const fs=require("fs");const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const want=process.argv[2];const out=[];for(const g of ((s.hooks&&s.hooks.PreToolUse)||[])){for(const h of (g.hooks||[])){if(String(h.command||"").includes(want))out.push(String(g.matcher||""));}}console.log(out.join("\n"));'
for guard in block-dotenv.js block-credentials.js; do
    if [ ! -f "$SETTINGS" ]; then
        fail "W11/$guard: settings.json is absent" "cannot read hooks.PreToolUse"
        continue
    fi
    MATCHERS="$(bash "$AGENTS_DIR/bin/run-with-timeout.sh" 120 node -e "$READ_MATCHERS" "$(nodepath "$SETTINGS")" "$guard" 2>/dev/null || true)"
    HITS="$(printf '%s' "$MATCHERS" | grep -c . || true)"
    assert_eq "W11/$guard: registered under exactly one PreToolUse matcher" "1" "${HITS:-0}"
    if printf '%s' "$MATCHERS" | grep -qF 'mcp__codegraph__codegraph_explore'; then
        pass "W11/$guard: its matcher lists mcp__codegraph__codegraph_explore"
    else
        fail "W11/$guard: its PreToolUse matcher does not list mcp__codegraph__codegraph_explore" \
             "matcher=$(printf '%s' "$MATCHERS" | tr '\n' ' ')"
    fi
done

assert_count_re "W9-02" ".env.example" '^[[:space:]]*CODEGRAPH=' 1 \
    "a duplicate assignment makes the last one win silently, so the documented default and the effective default diverge"
assert_count "W9-03" ".env.example" "# --- CodeGraph ---" 1 \
    "a duplicated section header means the block was applied twice and W9-01's line range no longer covers the second copy"
