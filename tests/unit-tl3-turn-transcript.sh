#!/usr/bin/env bash
# Tests: tests/lib/tl3-turn-transcript.js
# Tags: tl3-support, transcript-parsing, json, classifier, table-driven, scope:common, pwsh-not-required
# tests/lib/tl3-turn-transcript.js is the evidence reader behind the RUN_TL3-gated hook
# seam tests, which SKIP in an ordinary run — so its own logic would otherwise ship
# unverified. This file exercises it against saved fixture transcripts covering every
# shape a `claude -p` turn can leave: the stream `.jsonl`, the single result object of
# `--output-format json`, a truncated file, and both tool_result content spellings.

set -uo pipefail

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PROBE="$AGENTS_DIR/tests/lib/tl3-turn-transcript.js"
command -v node >/dev/null 2>&1 || exit 77
[ -f "$PROBE" ] || { echo "SKIP: tests/lib/tl3-turn-transcript.js not found" >&2; exit 77; }

PASS=0
FAIL=0
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

# Fixture isolation per rules/test/fixture-isolation.md.
TMP_RAW="$(mktemp -d)"
trap 'rm -rf "$TMP_RAW"' EXIT
to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
TMP="$(to_node_path "$TMP_RAW")"
export TMPDIR="$TMP" TEMP="$TMP"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

MARK="Capture-then-display rejected"
w() { printf '%s\n' "$2" >> "$TMP_RAW/$1"; }

# --- fixtures: one file per transcript shape ---------------------------------
w blocked.jsonl '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"OUTPUT=$(bash ./captured.sh); echo \"$OUTPUT\""}}]}}'
w blocked.jsonl '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":true,"content":"Capture-then-display rejected: OUTPUT is assigned a command substitution."}]}}'
w blocked.jsonl '{"type":"result","subtype":"success","is_error":false,"result":"The command was refused."}'

w blocks.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_9","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w blocks.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_9","is_error":true,"content":[{"type":"text","text":"Capture-then-display rejected: X is assigned."}]}]}}'

w allowed.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_2","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w allowed.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_2","is_error":false,"content":"value"}]}}'

w other.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_3","name":"Bash","input":{"command":"bash ./control.sh"}}]}}'
w other.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_3","is_error":false,"content":"value"}]}}'

w notool.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_4","name":"BashOutput","input":{"command":"bash ./captured.sh"}}]}}'
w notool.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_4","is_error":false,"content":"value"}]}}'

w array.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_5","name":"runCommands","input":{"commands":["ls","bash ./captured.sh"]}}]}}'
w array.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_5","is_error":true,"content":"Capture-then-display rejected: X is assigned."}]}}'

w runterm.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_h","name":"runInTerminal","input":{"command":"bash ./captured.sh"}}]}}'
w runterm.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_h","is_error":true,"content":"Capture-then-display rejected: X is assigned."}]}}'

w unlinked.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_6","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'

w truncated.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_7","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w truncated.jsonl '{"type":"user","message":{"content":[{"type":"tool_res'

# The four ways a Bash attempt can come back as an error. Only the first two are the
# permission system refusing; the rest are an unrelated failure that must not be read
# as "the allow-only hook declined".
w permasked.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_a","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w permasked.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_a","is_error":true,"content":"Claude requested permissions to use Bash, but you have not granted it yet."}]}}'

w permrejected.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_b","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w permrejected.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_b","is_error":true,"content":"The user doesn'"'"'t want to proceed with this tool use. The tool use was rejected."}]}}'

w crashed.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_c","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w crashed.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_c","is_error":true,"content":"bash: line 1: zsh: command not found\nExit code 127"}]}}'

w otherguard.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_d","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w otherguard.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_d","is_error":true,"content":"Blocked by hooks/block-credentials.js: credential access denied."}]}}'

# The two false-positive shapes the classifier must reject: the OS message a script
# prints on a mode bit, and a SUCCESSFUL result whose output merely quotes the
# permission system's wording.
w osperm.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_f","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w osperm.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_f","is_error":true,"content":"bash: ./captured.sh: Permission denied"}]}}'

w quotedperm.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_g","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w quotedperm.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_g","is_error":false,"content":"Claude requested permissions to use Bash"}]}}'

w timedout.jsonl '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_e","name":"Bash","input":{"command":"bash ./captured.sh"}}]}}'
w timedout.jsonl '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_e","is_error":true,"content":"Command timed out after 2m 0.0s"}]}}'

w resultonly.json '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
w errored.json '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}'
w arraydoc.json '[{"type":"assistant","is_error":false},{"type":"result","is_error":true}]'
w garbage.txt 'this is not json at all'
: > "$TMP_RAW/empty.json"

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
probe() {
    local f="$1"
    node "$PROBE" --probe --needle "captured.sh" --marker "$MARK" "$TMP/$f" 2>&1
}

# --- P: the probe's three answers, one fixture per shape ----------------------
# `attempted` and `marker` are the two halves the TL3 assertions rest on: an absent
# side effect proves the guard fired only when the command was ATTEMPTED and the
# refusal carries the guard's OWN wording. Each is pinned in both directions.
echo "--- P: attempted / result_error / marker ---"
out="$(probe blocked.jsonl)"
assert_eq "P-1-blocked-attempted"    "true" "$(field "$out" attempted)"
assert_eq "P-1-blocked-result-error" "true" "$(field "$out" result_error)"
assert_eq "P-1-blocked-marker"       "true" "$(field "$out" marker)"

# Same verdict when the tool_result payload is a content-BLOCK array rather than a
# plain string — the two spellings must not disagree.
out="$(probe blocks.jsonl)"
assert_eq "P-2-content-blocks-marker"    "true" "$(field "$out" marker)"
assert_eq "P-2-content-blocks-attempted" "true" "$(field "$out" attempted)"

# The both-direction control for the marker: the command WAS attempted and DID run,
# so a probe that answered "blocked" for everything would fail here.
out="$(probe allowed.jsonl)"
assert_eq "P-3-allowed-attempted"    "true"  "$(field "$out" attempted)"
assert_eq "P-3-allowed-result-error" "false" "$(field "$out" result_error)"
assert_eq "P-3-allowed-marker"       "false" "$(field "$out" marker)"

# A DIFFERENT command in the same shape is not the targeted attempt. Without this row
# `attempted` could be satisfied by any Bash call at all.
out="$(probe other.jsonl)"
assert_eq "P-4-other-command-not-attempted" "false" "$(field "$out" attempted)"
assert_eq "P-4-other-command-uses-seen"     "1"     "$(field "$out" uses)"

# Tool names are matched exactly: `BashOutput` reads a background stream and is not a
# command invocation, so a substring test would count it as an attempt.
out="$(probe notool.jsonl)"
assert_eq "P-5-bashoutput-not-an-attempt" "false" "$(field "$out" attempted)"

# The array-carrying tool shape (`commands[]`) is a real dispatch path, so its payload
# must be searched too — and the targeted command sits behind a benign first element.
out="$(probe array.jsonl)"
assert_eq "P-6-runcommands-array-attempted" "true" "$(field "$out" attempted)"
assert_eq "P-6-runcommands-array-marker"    "true" "$(field "$out" marker)"

# The third member of COMMAND_TOOLS. Its own row, so dropping or mistyping the name in
# the set fails here rather than silently narrowing what counts as a command attempt —
# `BashOutput` above is the negative half of the same pair.
out="$(probe runterm.jsonl)"
assert_eq "P-6b-runinterminal-attempted" "true" "$(field "$out" attempted)"
assert_eq "P-6b-runinterminal-marker"    "true" "$(field "$out" marker)"

# An attempt with no result block is UNOBSERVED, not successful: reporting `false` here
# would let a truncated transcript read as "the command ran".
out="$(probe unlinked.jsonl)"
assert_eq "P-7-unlinked-attempted"    "true"    "$(field "$out" attempted)"
assert_eq "P-7-unlinked-result-error" "unknown" "$(field "$out" result_error)"
assert_eq "P-7-unlinked-marker"       "unknown" "$(field "$out" marker)"

# A partial final line is dropped, and the intact records before it still count.
out="$(probe truncated.jsonl)"
assert_eq "P-8-truncated-keeps-earlier-records" "true" "$(field "$out" attempted)"
assert_eq "P-8-truncated-records-count"         "1"    "$(field "$out" records)"

# `--output-format json` alone carries no tool blocks: the probe must say so plainly
# rather than inventing evidence, which is why the TL3 files also pass the session
# `.jsonl`.
out="$(probe resultonly.json)"
assert_eq "P-9-result-only-records"   "1"     "$(field "$out" records)"
assert_eq "P-9-result-only-uses"      "0"     "$(field "$out" uses)"
assert_eq "P-9-result-only-attempted" "false" "$(field "$out" attempted)"

out="$(probe garbage.txt)"
assert_eq "P-10-garbage-no-records" "0" "$(field "$out" records)"
out="$(probe empty.json)"
assert_eq "P-11-empty-no-records"   "0" "$(field "$out" records)"
out="$(node "$PROBE" --probe --needle "captured.sh" --marker "$MARK" "$TMP/absent.jsonl" 2>&1)"
assert_eq "P-12-missing-file-no-records" "0" "$(field "$out" records)"

# Evidence from BOTH files is merged: the tool blocks live in the `.jsonl`, the result
# record in the `--output-format json` output, and the TL3 files pass both.
out="$(node "$PROBE" --probe --needle "captured.sh" --marker "$MARK" "$TMP/resultonly.json" "$TMP/blocked.jsonl" 2>&1)"
assert_eq "P-13-multi-file-attempted" "true" "$(field "$out" attempted)"
assert_eq "P-13-multi-file-marker"    "true" "$(field "$out" marker)"

# --- D: permission_denial, the attributing key for an allow-only hook ---------
# TL3-hook-scratchpad-auto-approve.sh rests "the hook did NOT allow this" on this key.
# `result_error` cannot carry that claim: rows D-3..D-6 are all error results produced
# by something other than the permission system, and each must answer `false`. D-1/D-2
# are the positive direction, D-7 the allowed control, D-8 the unobserved case.
echo ""
echo "--- D: permission_denial ---"
out="$(probe permasked.jsonl)"
assert_eq "D-1-permission-prompt-unanswered" "true" "$(field "$out" permission_denial)"
assert_eq "D-1-permission-prompt-errored"    "true" "$(field "$out" result_error)"

out="$(probe permrejected.jsonl)"
assert_eq "D-2-tool-use-rejected" "true" "$(field "$out" permission_denial)"

out="$(probe crashed.jsonl)"
assert_eq "D-3-crash-errored"            "true"  "$(field "$out" result_error)"
assert_eq "D-3-crash-not-a-denial"       "false" "$(field "$out" permission_denial)"

# The sharpest negative: another guard's deny, error result and the word "denied" in
# its text, must still not be attributed to the permission system.
out="$(probe otherguard.jsonl)"
assert_eq "D-4-other-guard-errored"      "true"  "$(field "$out" result_error)"
assert_eq "D-4-other-guard-not-a-denial" "false" "$(field "$out" permission_denial)"
assert_eq "D-4-other-guard-not-marked"   "false" "$(field "$out" marker)"

out="$(probe timedout.jsonl)"
assert_eq "D-5-timeout-errored"      "true"  "$(field "$out" result_error)"
assert_eq "D-5-timeout-not-a-denial" "false" "$(field "$out" permission_denial)"

# The capture guard's own wording is a hook deny, not a permission refusal — the two
# attributions must stay separable, since sibling TL3 files assert one of each.
out="$(probe blocked.jsonl)"
assert_eq "D-6-hook-deny-not-a-permission-denial" "false" "$(field "$out" permission_denial)"

out="$(probe allowed.jsonl)"
assert_eq "D-7-allowed-not-a-denial" "false" "$(field "$out" permission_denial)"
out="$(probe unlinked.jsonl)"
assert_eq "D-8-unlinked-denial-unknown" "unknown" "$(field "$out" permission_denial)"

# The OS's own "Permission denied" is an execution failure, not the permission system,
# and a SUCCESSFUL result that merely quotes the refusal wording is not a refusal —
# the classifier requires the error flag as well as the wording.
out="$(probe osperm.jsonl)"
assert_eq "D-9-os-permission-denied-errored"      "true"  "$(field "$out" result_error)"
assert_eq "D-9-os-permission-denied-not-a-denial" "false" "$(field "$out" permission_denial)"

out="$(probe quotedperm.jsonl)"
assert_eq "D-10-quoted-wording-succeeded"    "false" "$(field "$out" result_error)"
assert_eq "D-10-quoted-wording-not-a-denial" "false" "$(field "$out" permission_denial)"

# --- D-ALT: one row per alternative, in isolation -----------------------------
# PERMISSION_DENIAL_PATTERNS is a list of independent alternatives, so a fixture that
# trips two of them at once leaves the others unverified: deleting or mistyping one
# would still pass. Each row below matches EXACTLY ONE alternative, so removing that
# alternative flips exactly that row. The same one-branch-one-row rule goes a level
# deeper for alternative 2, whose four inner spellings each get their own P2 row.
# N* are the near-miss wordings the list must not claim. Per parser-regex-tests.md.
echo ""
echo "--- D-ALT: each alternative in isolation ---"
classify() {
    node -e 'process.stdout.write(String(require(process.argv[1]).isPermissionDenialText(process.argv[2])))' "$PROBE" "$1" 2>&1
}
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    assert_eq "$name" "$want" "$(classify "$input")"
done <<'TABLE'
D-ALT-P1-requested-permissions  | Claude requested permissions to use Bash. | true
D-ALT-P2-not-been-granted       | The Bash permission for this session has not been granted. | true
D-ALT-P2-not-granted-bare       | The Bash tool permission was not granted. | true
D-ALT-P2-was-denied             | Permission to run that tool was denied by the user. | true
D-ALT-P2-is-required            | Additional permission is required to run this tool. | true
D-ALT-P3-tool-use-rejected      | The tool use was rejected. | true
D-ALT-P4-wont-proceed           | The user does not want to proceed with this tool use. | true
D-ALT-P5-requires-approval      | Running that command requires approval first. | true
D-ALT-N1-os-permission-denied   | bash: ./captured.sh: Permission denied | false
D-ALT-N2-guard-deny             | Capture-then-display rejected: OUTPUT is assigned. | false
D-ALT-N3-command-not-found      | bash: line 1: zsh: command not found | false
D-ALT-N4-timeout                | Command timed out after 2m 0.0s | false
D-ALT-N5-granted                | Permission granted for this tool use. | false
D-ALT-N6-empty                  |  | false
TABLE

# --- E: --is-error, the mode the TL3 files already relied on ------------------
# Behaviour is unchanged from the inline reader it replaces: the final record's flag,
# and "unreadable" whenever the document does not parse.
echo ""
echo "--- E: --is-error ---"
iserr() { node "$PROBE" --is-error "$TMP/$1" 2>&1; }
assert_eq "E-1-false"        "false"      "$(iserr resultonly.json)"
assert_eq "E-2-true"         "true"       "$(iserr errored.json)"
assert_eq "E-3-array-last"   "true"       "$(iserr arraydoc.json)"
assert_eq "E-4-garbage"      "unreadable" "$(iserr garbage.txt)"
assert_eq "E-5-empty"        "unreadable" "$(iserr empty.json)"
assert_eq "E-6-missing-file" "unreadable" "$(iserr absent.json)"

echo ""
echo "==================================================="
echo "unit-tl3-turn-transcript: PASS=$PASS FAIL=$FAIL"
echo "==================================================="
exit "$FAIL"
