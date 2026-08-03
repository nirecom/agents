#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-6: PROGRAM TEXT DELIVERED ON AN INTERPRETER'S STDIN.
#
# Round-5 closed here-string bodies by routing them to the SHELL scanner, which
# is the right grammar only when the reader IS a shell. Every language
# interpreter that also executes a program read from stdin stayed open, so the
# byte-identical body that blocked via `-e` sailed through via `<<<`:
#
#     node -e  "require('fs').unlinkSync('<marker>')"   -> BLOCK   (round 5)
#     node <<< "require('fs').unlinkSync('<marker>')"   -> APPROVE (round 5 hole)
#
# The fix keys routing on the RECEIVING COMMAND'S INTERPRETER IDENTITY rather
# than on the delivery syntax (CPR-4: fix the class, not the member), so the
# cases below are organised by ROUTE, and each route is asserted for BOTH
# interpreter kinds and for both protected families (marker + token, CPR-5):
#
#   R6-8  here-string  -> body known    -> judged in the interpreter's language
#   R6-9  heredoc      -> body known    -> same, incl. quoted delimiter and the
#                                          unterminated form (no body extractable
#                                          -> fail closed, as HIGH-2 does)
#   R6-10 pipe         -> body OPAQUE   -> fail closed on a protected MENTION
#   R6-11 `<(...)`     -> body OPAQUE   -> same
#         `< FILE`     -> the file is EXECUTED -> judged as a path
#
# DELIBERATE ASYMMETRY (do not "fix" these into symmetry):
#   * an opaque route is judged by MENTION, not parsed, so `printf '<read-only
#     body>' | node` BLOCKS while the same body via `-e` is APPROVED. Over-block
#     is the sanctioned direction for "cannot analyse" (CPR-5 with HIGH-2).
#   * a heredoc feeding a SHELL or a non-interpreter is NOT shell-recursed:
#     recursing all heredocs as shell text would fail-close on ordinary prose,
#     which 9-nr3/9-nr4 pin as ALLOW.
#
# #1709 READ symmetry is the non-negotiable counterweight and is asserted on all
# three body routes (`-e`, `<<<`, heredoc): a guard that blocks reading a marker
# breaks the workflow it is meant to protect.
#
# TABLE FORMAT: name|want|payload (payload LAST, so it may contain `|`).
# @DIR@ -> sandbox workflow dir, @MK@ -> marker basename, @TOK@ -> token
# basename, @NL@ -> a real newline (heredocs need multi-line command text).

# _r6_json_esc: json_esc plus newline escaping - a raw newline inside a JSON
# string is invalid JSON, and every heredoc case below carries one.
_r6_json_esc() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}
# _r6_mk_input <command> <cwd>
_r6_mk_input() {
    printf '{"tool_name":"Bash","session_id":"wsid","cwd":"%s","tool_input":{"command":"%s"}}' \
        "$(_r6_json_esc "$2")" "$(_r6_json_esc "$1")"
}

# _r6_expand <text> - the SSOT for what @DIR@/@MK@/@TOK@/@NL@ mean. Later rounds
# add placeholders of their own and then delegate here (see ./cases-round9-brace-ansi.sh
# and ./cases-round10-brace-span.sh), so a spelling is defined in exactly one place.
_r6_expand() {
    local t="$1"
    t="${t//@DIR@/$WFDIR}"
    t="${t//@MK@/$SID.workflow-off}"
    t="${t//@TOK@/$SID.off-clearance}"
    t="${t//@NL@/$'\n'}"
    printf '%s' "$t"
}

# _run_r6_table <section-label>  (reads the table on stdin)
_run_r6_table() {
    local section="$1" name want payload
    while IFS='|' read -r name want payload; do
        case "$name" in ''|\#*) continue ;; esac
        name="${name%"${name##*[![:space:]]}"}"
        want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
        payload="${payload#"${payload%%[![:space:]]*}"}"
        payload="$(_r6_expand "$payload")"
        assert_verdict "$section $name" "$want" \
            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r6_mk_input "$payload" "$LINKED_WT")")"
    done
}

# run_R6_here_strings - R6-8: `<<<` into a LANGUAGE interpreter.
# CTRL-1..3 are the round-5 controls repeated verbatim: the identity-based
# routing must not have loosened the shell route or the plain redirect while
# broadening the language route.
run_R6_here_strings() {
    _run_r6_table "R6" <<'TABLE'
CTRL-1 shell herestring|block|sh <<< "echo x > @DIR@/@MK@"
CTRL-2 sh -c relative|block|sh -c 'echo {} > @MK@'
CTRL-3 plain redirect|block|echo x > @DIR@/@MK@
8-a node|block|node <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-b python3|block|python3 <<< "import os; os.remove('@DIR@/@MK@')"
8-c perl|block|perl <<< "unlink('@DIR@/@MK@')"
8-d ruby|block|ruby <<< "File.delete('@DIR@/@MK@')"
8-e deno|block|deno <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-f bun|block|bun <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-g pwsh|block|pwsh <<< "Remove-Item '@DIR@/@MK@'"
8-h explicit - operand|block|node - <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-i flag but no program|block|node -u <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-j python3 - operand|block|python3 - <<< "import os; os.remove('@DIR@/@MK@')"
8-k token family|block|node <<< "require('fs').unlinkSync('@DIR@/@TOK@')"
8-l uppercase .exe|block|NODE.EXE <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-m absolute path|block|/usr/bin/node <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-n env wrapper|block|env node <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-o exec wrapper|block|exec node <<< "require('fs').unlinkSync('@DIR@/@MK@')"
8-nr1 benign body|approve|node <<< "console.log(1)"
8-nr2 benign -e|approve|node -e "console.log(1)"
8-nr3 read via -e|approve|node -e "console.log(require('fs').readFileSync('@DIR@/@MK@','utf8'))"
8-nr4 read via <<<|approve|node <<< "console.log(require('fs').readFileSync('@DIR@/@MK@','utf8'))"
TABLE
}

# run_R6_heredocs - R6-9: `<<WORD` into a LANGUAGE interpreter.
run_R6_heredocs() {
    _run_r6_table "R6" <<'TABLE'
9-a node|block|node <<EOF@NL@require('fs').unlinkSync('@DIR@/@MK@')@NL@EOF
9-b python3|block|python3 <<EOF@NL@import os; os.remove('@DIR@/@MK@')@NL@EOF
9-c quoted delimiter|block|node <<'EOF'@NL@require('fs').unlinkSync('@DIR@/@MK@')@NL@EOF
9-d relative body|block|cd @DIR@ && node <<EOF@NL@require('fs').unlinkSync('@MK@')@NL@EOF
9-e unterminated|block|node <<EOF@NL@require('fs').unlinkSync('@DIR@/@MK@')
9-f token family|block|node <<EOF@NL@require('fs').unlinkSync('@DIR@/@TOK@')@NL@EOF
9-g deno|block|deno <<EOF@NL@require('fs').unlinkSync('@DIR@/@MK@')@NL@EOF
9-h pwsh|block|pwsh <<EOF@NL@Remove-Item '@DIR@/@MK@'@NL@EOF
9-i node.exe|block|node.exe <<EOF@NL@require('fs').unlinkSync('@DIR@/@MK@')@NL@EOF
9-nr1 read via heredoc|approve|node <<EOF@NL@console.log(require('fs').readFileSync('@DIR@/@MK@','utf8'))@NL@EOF
9-nr2 benign body|approve|node <<EOF@NL@console.log(1)@NL@EOF
9-nr3 prose names marker|approve|cat <<EOF >> docs/history.md@NL@- removed the stale @MK@ marker@NL@EOF
9-nr4 prose names token|approve|cat <<EOF >> docs/history.md@NL@- the @TOK@ token is minted by the shim@NL@EOF
9-nr5 data heredoc|approve|jq -r '.a' <<EOF@NL@{"a":1}@NL@EOF
TABLE
}

# run_R6_opaque_routes - R6-10 / R6-11: pipe, process substitution, `< FILE`.
# 10-h is the documented over-block: the same body via `-e` is 8-nr3/approve.
run_R6_opaque_routes() {
    _run_r6_table "R6" <<'TABLE'
10-a printf into node|block|printf '%s' "require('fs').unlinkSync('@DIR@/@MK@')" | node
10-b echo into python3|block|echo "import os; os.remove('@DIR@/@MK@')" | python3
10-c cat marker into node|block|cat @DIR@/@MK@ | node
10-d explicit - operand|block|printf '%s' "require('fs').unlinkSync('@DIR@/@MK@')" | node -
10-e printf into perl|block|printf '%s' "unlink('@DIR@/@MK@')" | perl
10-f whole pipeline walked|block|cat @DIR@/@MK@ | tr -d x | node
10-g token family|block|printf '%s' "require('fs').unlinkSync('@DIR@/@TOK@')" | node
10-h read body, opaque route|block|printf '%s' "console.log(require('fs').readFileSync('@DIR@/@MK@','utf8'))" | node
10-i relative after cd|block|cd @DIR@ && printf '%s' "require('fs').unlinkSync('@MK@')" | node
11-a process substitution|block|node <(printf '%s' "require('fs').unlinkSync('@DIR@/@MK@')")
11-b process substitution token|block|node <(printf '%s' "require('fs').unlinkSync('@DIR@/@TOK@')")
11-c stdin file executed|block|node < @DIR@/@MK@
11-d stdin file token|block|node < @DIR@/@TOK@
10-nr1 benign pipe|approve|printf hi | node
10-nr2 ordinary pipeline|approve|git log | head
10-nr3 read pipeline|approve|grep foo bar | cat
10-nr4 json pipeline|approve|cat data.json | jq -r '.items[].name' | sort
10-nr5 benign python3 pipe|approve|printf 'print(1)' | python3
10-nr6 marker as DATA|approve|cat @DIR@/@MK@ | python3 -c "print(1)"
11-nr1 plain stdin read|approve|cat < @DIR@/@MK@
11-nr2 plain read|approve|cat @DIR@/@MK@
TABLE
}
