#!/usr/bin/env bash
# Part of tests/enforce-system-ops-classifier.sh (rules/coding/file-split.md).
# Section P - payload shape and malformed stdin, including the runCommands
# join-separator behaviour pair.

# ===========================================================================
# Section P - payload shape and malformed stdin. A PreToolUse hook that throws
# is read by the tool layer as "no objection", so every degenerate shape must
# terminate cleanly at rc 0 (ALLOW) rather than at rc 1 (crash). RC1 and ALLOW
# are distinct tokens here precisely so a crash cannot masquerade as a pass.
# ===========================================================================
run_P_payload() {
while IFS='|' read -r name want json; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    json="$(printf '%s' "$json" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    json="$(expand_placeholders "$json")"
    assert_eq "P $name" "$want" "$(run_json "$json")"
done <<'TABLE'
payload-empty-stdin        | ALLOW |
payload-not-json           | ALLOW | not json at all
payload-json-null          | ALLOW | null
payload-json-array         | ALLOW | []
payload-json-number        | ALLOW | 42
payload-truncated-json     | ALLOW | {"tool_name":"Bash","tool_input":
payload-no-tool-name       | ALLOW | {"tool_input":{"command":"winget install jq"}}
payload-unknown-tool       | ALLOW | {"tool_name":"Edit","tool_input":{"command":"winget install jq"}}
payload-tool-input-null    | ALLOW | {"tool_name":"Bash","tool_input":null}
payload-tool-input-missing | ALLOW | {"tool_name":"Bash"}
payload-tool-input-string  | ALLOW | {"tool_name":"Bash","tool_input":"winget install jq"}
payload-command-null       | ALLOW | {"tool_name":"Bash","tool_input":{"command":null}}
payload-command-number     | ALLOW | {"tool_name":"Bash","tool_input":{"command":123}}
payload-command-empty      | ALLOW | {"tool_name":"Bash","tool_input":{"command":""}}
payload-tool-name-number   | ALLOW | {"tool_name":42,"tool_input":{"command":"winget install jq"}}
payload-runcmds-empty-arr  | ALLOW | {"tool_name":"runCommands","tool_input":{"commands":[]}}
payload-runcmds-clean      | ALLOW | {"tool_name":"runCommands","tool_input":{"commands":["ls","pwd"]}}
payload-runcmds-blocked    | BLOCK | {"tool_name":"runCommands","tool_input":{"commands":["ls","winget install jq"]}}
payload-runcmds-null-elem  | BLOCK | {"tool_name":"runCommands","tool_input":{"commands":[null,"winget install jq"]}}
payload-runcmds-nonarray   | BLOCK | {"tool_name":"runCommands","tool_input":{"commands":"winget install jq"}}
payload-runinterminal      | BLOCK | {"tool_name":"runInTerminal","tool_input":{"command":"apt install jq"}}
payload-command-array      | BLOCK | {"tool_name":"Bash","tool_input":{"command":["winget install jq"]}}
TABLE

# Whitespace-only stdin cannot survive the table's field trimming, so it is
# asserted directly: `!input.trim()` is its own early exit in the source.
assert_eq "P payload-whitespace-stdin" "ALLOW" "$(run_json '
	 ')"

# The runCommands join separator is "\n" (hooks/lib/tool-command-text.js), which
# makes commands[1] its own statement. Pinned as a behaviour pair: the newline
# must ANCHOR a fresh command position (block), and an ordinary second element
# must not be glued into a false positive.
assert_eq "P payload-runcmds-newline-anchors" "BLOCK" \
    "$(run_json '{"tool_name":"runCommands","tool_input":{"commands":["echo hi","systemctl stop nginx"]}}')"
assert_eq "P payload-runcmds-no-false-glue" "ALLOW" \
    "$(run_json '{"tool_name":"runCommands","tool_input":{"commands":["echo systemctl","status nginx"]}}')"
}
