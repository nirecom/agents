# tests/feature-2134-bash-guard/cases-allow-rule.sh
# Tests: hooks/lib/settings-allow-match.js, hooks/bash-guard/exemptions.js, hooks/bash-guard/judge.js
# Tags: hook, bash-guard, settings-allow, exemptions, glob, scope:issue-specific, pwsh-not-required, TL2
# R1-R5: the one command-scoped exemption. Sourced by the dispatcher.

# WHY A COMMAND-SCOPED CARVE-OUT (codex round 1, C2). The user already granted a command by
# writing it into settings.json permissions.allow; denying it for its shape would overrule an
# explicit grant. A `Bash(...)` rule is matched against the WHOLE command string, so a grant of
# `git status*` does NOT cover `cd /x && git status` -- R2 is that boundary. And because the
# rule blesses the command rather than one operator, this exemption alone is command-scoped:
# it clears every hit, unlike the hit-scoped xargs carve-out in cases-xargs-pipe.sh.

BG_ALLOW_HOME="$TMPROOT/home-allow"
mkdir -p "$BG_ALLOW_HOME/.claude"
BG_ALLOW_SETTINGS="$BG_ALLOW_HOME/.claude/settings.json"

# The generated-path-rule row below (R1/generated-path-rule) must exercise a rule spelling this
# repo's own generator produced -- not a hand-typed guess at what it produces. install/lib/
# settings-allow-rules.js is the SSOT for that spelling (CPR-SSOT); calling pathRules() here
# means a future template change in that module is caught by THIS assertion, not silently
# tolerated by a fixture that still types out yesterday's format.
BG_GEN_RULES_JSON="$(run_with_timeout 30 node -e '
  const { pathRules } = require(process.argv[1]);
  const rules = pathRules(process.argv[2], "node", "bin/workflow/next-step");
  process.stdout.write(JSON.stringify(rules));
' "$(node_path "$AGENTS_DIR/install/lib/settings-allow-rules.js")" "$(node_path "$AGENTS_DIR")" 2>/dev/null)"
# A silent "[]" fallback here would make generated-path-rule/generated-control-no-match pass
# vacuously against an empty ruleset when pathRules() itself is broken -- a real generator
# drift must surface as a hard failure, not degrade the fixture quietly (review finding #4).
[ -n "$BG_GEN_RULES_JSON" ] || { echo "FATAL: pathRules() generator failed to produce rules" >&2; exit 1; }

BG_ALLOW_SETTINGS_JS="$AGENTS_DIR/install/lib/settings-allow-rules.js"
run_with_timeout 30 node -e '
  const fs = require("fs");
  const generated = JSON.parse(process.argv[1]);
  const out = {
    permissions: {
      allow: [
        "Bash(git status*)",
        "Bash(git -C * status*)",
        "Bash(git push --force-with-lease*)",
        "Bash(ls * | head -*)",
        ...generated,
      ],
      deny: [],
    },
  };
  fs.writeFileSync(process.argv[2], JSON.stringify(out, null, 2) + "\n");
' "$BG_GEN_RULES_JSON" "$(node_path "$BG_ALLOW_SETTINGS")"

r1_allow_rules() {
    local name cmd want got
    while IFS='~' read -r name cmd want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(PROBE_HOME="$BG_ALLOW_HOME" verdict_of "$cmd")"
        assert_eq "R1/$name: verdict under the fixture permissions.allow" "$want" "$got"
    done <<'TABLE'
granted-dashC   ~ git -C $(pwd) status                ~ allow
chain-not-whole ~ cd /x && git status                 ~ deny
granted-push    ~ git push --force-with-lease | cat    ~ allow
granted-pipe    ~ ls foo | head -5                    ~ allow
granted-short   ~ git status --short > out.txt         ~ allow
ungranted-redir ~ echo hi > out.txt                   ~ deny
TABLE

    # granted-dashC/granted-push/granted-short each carry a real forbidden literal (cmd-subst,
    # pipe, redirect-out) that ONLY the matching allow-rule exempts -- disabling that rule would
    # flip the row to deny, unlike a literal-free command that reads allow either way.

    # generated-path-rule: driven by pathRules()'s ACTUAL output (above), with `&& true` appended
    # so the row proves the wildcard exempts a real literal, not a bare spelling with nothing to
    # deny. generated-control-no-match shares the rule's shape but names a non-listed script,
    # checked via allow-match (not the overall verdict, which would read allow either way).
    name="generated-path-rule"; ROWS=$((ROWS + 1))
    got="$(PROBE_HOME="$BG_ALLOW_HOME" verdict_of "node $(node_path "$AGENTS_DIR")/bin/workflow/next-step --list && true")"
    assert_eq "R1/$name: a real generator-produced rule's wildcard exempts an appended forbidden literal" "allow" "$got"

    name="generated-control-no-match"; ROWS=$((ROWS + 1))
    got="$(probe allow-match "node $(node_path "$AGENTS_DIR")/bin/workflow/next-step-fake --list" '' '' "$BG_ALLOW_SETTINGS")"
    assert_eq "R1/$name: a lookalike script the generator never listed does not match the generated rule" "false" "$got"
}

r1_allow_rules

# R2: the injection point. isAllowRuleMatch(text, {settingsPath}) must read the file it is
# handed, so the matcher is testable without a fixture HOME -- and so #2119's deployed-settings
# SSOT stays the single reader of the real path.
assert_eq "R2: an explicit settingsPath is honoured (granted pipe matches)" \
    "true" "$(probe allow-match 'ls foo | head -5' '' '' "$BG_ALLOW_SETTINGS")"
assert_eq "R2: a command outside every rule does not match" \
    "false" "$(probe allow-match 'echo hi > out.txt' '' '' "$BG_ALLOW_SETTINGS")"

# R3: `*` is positional, not a licence. `git statusfoo && ls` shares a prefix with the granted
# rule but the whole-string match still fails, so the chain is denied.
assert_eq "R3: a prefix lookalike does not inherit the grant" \
    "false" "$(probe allow-match 'git statusfoo && ls' '' '' "$BG_ALLOW_SETTINGS")"

# R4: unreadable settings fail to the WIDER side. This guard is presentational, so a rule file
# it cannot parse must silence it, never make it deny a command the user may well have granted.
BG_BAD_SETTINGS="$TMPROOT/bad-settings.json"
printf '%s' '{"permissions": {"allow": [' > "$BG_BAD_SETTINGS"
assert_eq "R4: corrupt settings.json fails open (match=true), never fails closed" \
    "true" "$(probe allow-match 'git status && ls' '' '' "$BG_BAD_SETTINGS")"
assert_eq "R4b: an absent settings.json fails open the same way" \
    "true" "$(probe allow-match 'git status && ls' '' '' "$TMPROOT/no-such-settings.json")"

# R5: the exemption is command-scoped -- one matching rule clears ALL hits on the line, not
# just the one operator the rule happens to contain. `ls foo | head -5 > out.txt` carries TWO
# hits (pipe and redirect-out); a hit-scoped exemption would clear only the pipe it names,
# leaving redirect-out to survive, so this proves the scope is the whole command.
assert_eq "R5: a matching rule clears every hit on the command" \
    "" "$(PROBE_HOME="$BG_ALLOW_HOME" probe hit-ids 'ls foo | head -5 > out.txt')"

# SKIPPED: rules that use Claude Code's non-glob prefix forms (`Bash(git:*)`).
# Because: #2119 settled the deployed-settings reader as the SSOT for rule syntax; duplicating
#          its dialect table here would be the copy CPR-SSOT forbids.
# L3 gap: a real ~/.claude/settings.json whose allow list has drifted from the repo copy --
#          only a live host shows that divergence.
