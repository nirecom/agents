#!/usr/bin/env bash
# tests/feature-2223-local-env-overlay/allow-dump-guard.sh
# Tests: hooks/lib/dotenv-check.js, hooks/block-dotenv.js, bin/env-effective-kv
# Tags: scope:issue-specific, TL2, load-env, local-env, security, trust-boundary, pwsh-not-required
# Case file for tests/feature-2223-local-env-overlay.sh — sourced from it, never
# run standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# --allow-dump prints every key AND value of the resolved map, so a direct
# Bash-tool call to it is the same access class the .env read guard refuses.
# TL3 gap: the real PreToolUse dispatch is not exercised — the hook is invoked
# directly, as tests/main-block-dotenv.sh does.
ALLOW_DUMP_GUARD_CASES_LOADED=1

DUMP_HOOK="$AGENTS_DIR/hooks/block-dotenv.js"
DUMP_TOOL="$AGENTS_DIR/bin/env-effective-kv"

# hook_verdict <command> — "block", "approve", or "unparsable".
hook_verdict() {
    local out
    out="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')" \
        | run_with_timeout 20 node "$DUMP_HOOK" 2>/dev/null)"
    case "$out" in
        *'"block"'*)   printf 'block' ;;
        *'"approve"'*) printf 'approve' ;;
        *)             printf 'unparsable' ;;
    esac
}

# ---------------------------------------------------------------------------
# Table — every spelling the guard must refuse, and every neighbour it must not.
# The blocked rows are the whole point; the approved rows are what keeps the
# guard from swallowing the sanctioned --key path or an unrelated tool.
# Columns: name | want | command
# ---------------------------------------------------------------------------
while IFS='|' read -r name want cmd; do
    name="$(trim "$name")"
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    want="$(trim "$want")"; cmd="$(trim "$cmd")"
    assert_eq "T2223AD-$name" "$want" "$(hook_verdict "$cmd")"
done <<'TABLE'
bash-script-form        | block   | bash bin/env-effective-kv --allow-dump
bare-name               | block   | env-effective-kv --allow-dump
relative-dot-slash      | block   | ./bin/env-effective-kv --allow-dump
absolute-path           | block   | /opt/agents/bin/env-effective-kv --allow-dump
windows-backslash-path  | block   | C:\agents\bin\env-effective-kv --allow-dump
flag-before-selector    | block   | bin/env-effective-kv --allow-dump --global-only
with-repo-root          | block   | bin/env-effective-kv --repo-root /tmp/x --allow-dump
shell-dash-c            | block   | bash -c "bin/env-effective-kv --allow-dump"
shell-sh-dash-c         | block   | sh -c 'bin/env-effective-kv --allow-dump'
shell-combined-lc       | block   | bash -lc "bin/env-effective-kv --allow-dump"
command-substitution    | block   | echo "$(bin/env-effective-kv --allow-dump)"
backtick-substitution   | block   | echo `bin/env-effective-kv --allow-dump`
after-separator         | block   | cd /tmp && bin/env-effective-kv --allow-dump
key-only-sanctioned     | approve | bin/env-effective-kv --repo-root /tmp/x --key PROJECT_NFR
key-only-global         | approve | bash bin/env-effective-kv --global-only --key CODE_LANG
decoy-lookalike-suffix  | approve | bin/env-effective-kv-lookalike --allow-dump
decoy-lookalike-prefix  | approve | bin/wrap-env-effective-kv --allow-dump
decoy-other-tool        | approve | some-other-tool --allow-dump
decoy-flag-alone        | approve | echo --allow-dump
decoy-substring-basename| approve | bin/env-effective-kvx --allow-dump
running-this-suite      | approve | bash tests/feature-2223-local-env-overlay.sh
TABLE

# A pipeline is a segment boundary, so the dumping half has to be found on its
# own. Kept out of the table because its own separator is the table separator.
assert_eq "T2223AD-piped-to-a-decoder" "block" \
    "$(hook_verdict "bin/env-effective-kv --allow-dump | tr -d x")"

# The guard is a Bash-tool door, not a change to the CLI: a script that runs the
# tool itself still dumps. Without this the table above would also pass if the
# tool had simply been broken.
DUMP_CFG="$TMP_ROOT/allow-dump-cfg"
mkdir -p "$DUMP_CFG"
printf 'CODE_LANG=english\nDUMPCANARY2223=canary-value-2223\n' > "$DUMP_CFG/.env"
DUMP_OUT="$TMP_ROOT/allow-dump-out.txt"
AGENTS_CONFIG_DIR="$(to_node_path "$DUMP_CFG")" run_with_timeout 20 \
    bash "$DUMP_TOOL" --global-only --allow-dump 2>/dev/null | tr '\0' '\n' > "$DUMP_OUT"
if grep -qF 'canary-value-2223' "$DUMP_OUT" 2>/dev/null; then
    pass "T2223AD-cli-still-dumps-when-run-by-a-script"
else
    fail "T2223AD-cli-still-dumps-when-run-by-a-script — canary absent from the dump"
fi

# The nested form the #2223 suites themselves use: the hook only ever sees the
# literal outer command string, so an invocation inside a test script is unseen.
assert_eq "T2223AD-nested-invocation-not-seen-by-hook" "approve" \
    "$(hook_verdict "bash $AGENTS_DIR/tests/feature-2223-local-env-overlay.sh")"
