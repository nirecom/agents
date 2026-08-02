#!/usr/bin/env bash
# Part of tests/fix-1780-round12-parser-unit-tables.sh (rules/coding/file-split.md).
# Sections I and D - the interpreter / nested-body side:
#   I  hooks/block-off-clearance-write/interpreter-scan.js
#   D  hooks/block-off-clearance-write/nested-bodies.js
# Sourced by the parent, which owns run_table(), _expand() and the counters.

# ===========================================================================
# Section I — interpreter-scan.js. Identity ("is this word an interpreter, and of
# which kind?") and proof ("does this argv word show the program is on argv, so
# stdin carries data?").
#
# The two alternations point in OPPOSITE directions and must never be merged:
# INTERPRETER_RE is an EXTRACTION alternation (over-matching = read more text =
# safe), INLINE_PROGRAM_FLAG_RE is a PERMISSION predicate (over-matching = clear
# more = unsafe). Sections I and D are where that split is observable.
#
# PAIRING:
#   I-re-node vs I-re-script      a `-c`/`-e`-family FLAG is what makes the shape
#   I-re-nodex vs I-re-node       word boundary: `nodex` is not `node`
#   I-re-echoe                    `echo -e` carries the flag but no interpreter
#   I-re-pwshCo / I-re-case       pwsh accepts every unambiguous prefix of
#                                 `-Command`, in any casing, and so must this
#   I-bf-awk / I-bf-php vs I-bf-node   the body-FIRST family needs no flag at all
#                                 (`awk 'BEGIN{print > "<marker>"}'`), which is
#                                 exactly why it is a second regex
#   I-kind-* / I-pwsh-*           identity is path-insensitive, `.exe`-tolerant
#                                 and case-folded (Windows executable lookup)
#   I-flag-* vs I-flag-p/I-flag-E `-p` / `-E` are LOOKALIKES — round-7: a flag
#                                 that merely resembles a program flag is not proof
#   I-proof-pwsh vs I-proof-nonpwsh  round-8 fix A: `-Command` is proof for pwsh
#                                 and meaningless for node, so proof is kind-SCOPED
#   I-ro-read vs I-ro-write       #1709: an anchored, provably side-effect-free
#                                 read shape is approved; everything else is a
#                                 write until proven otherwise
# ===========================================================================
run_I_interpreter_scan() {
run_table I <<'TABLE'
I-re-node     | true  | interpre | node -e "x"
I-re-py       | true  | interpre | python3 -c 'x'
I-re-pwsh     | true  | interpre | pwsh -Command "x"
I-re-pwshCo   | true  | interpre | pwsh -Co "x"
I-re-case     | true  | interpre | PWSH -COMMAND "x"
I-re-script   | false | interpre | node script.js
I-re-nodex    | false | interpre | nodex -e "x"
I-re-echoe    | false | interpre | echo -e "x"
I-bf-awk      | true  | bodyfirst | awk 'BEGIN{print}'
I-bf-php      | true  | bodyfirst | php -r 'x'
I-bf-node     | false | bodyfirst | node -e "x"
I-look-awk    | true  | lookslike | awk 'BEGIN{print}'
I-look-node   | true  | lookslike | node -e "x"
I-look-echo   | false | lookslike | echo hello
I-kind-node   | language | kind | node
I-kind-path   | language | kind | /usr/bin/python3
I-kind-case   | language | kind | NODE
I-kind-bash   | shell    | kind | bash
I-kind-sh     | shell    | kind | sh
I-kind-awk    | -        | kind | awk
I-pwsh-yes    | true  | pwshword | pwsh
I-pwsh-exe    | true  | pwshword | powershell.exe
I-pwsh-no     | false | pwshword | node
I-flag-e      | true  | inlineflag | -e
I-flag-c      | true  | inlineflag | -c
I-flag-eval   | true  | inlineflag | --eval
I-flag-cmd    | true  | inlineflag | -Command
I-flag-p      | false | inlineflag | -p
I-flag-E      | false | inlineflag | -E
I-proof-pwsh    | true  | proof | -Command pwsh
I-proof-nonpwsh | false | proof | -Command node
I-proof-e       | true  | proof | -e node
I-proof-c       | true  | proof | -c sh
I-ro-read     | true  | roshape | console.log(require('fs').readFileSync('/wf/s1@MK@','utf8'))
I-ro-write    | false | roshape | require('fs').writeFileSync('/wf/s1@MK@','x')
I-hits-write  | true  | hits | node -e "require('fs').writeFileSync('/wf/s1@MK@','x')"
I-hits-clean  | false | hits | node -e "console.log(1)"
TABLE
}

# ===========================================================================
# Section D — nested-bodies.js. The routes by which COMMAND TEXT reaches a shell
# without being written as a command: `eval`, here-strings, heredocs, pipelines.
#
# PAIRING:
#   D-eval-yes / D-eval-wrap vs D-eval-no   `eval` is found through the command
#       wrappers (command/builtin/exec/nohup/time) and only there
#   D-hs-raw vs D-hs-val   the SAME here-string in both spellings. Raw keeps the
#       outer quotes (the shell scanner re-tokenizes it); the value is quote-
#       stripped (the only form the anchored read-only shapes can match). Feeding
#       the raw form to those shapes would fail-closed block `node <<< "…"` while
#       its `-e` sibling is approved — the #1709 asymmetry.
#   D-stdin-bare vs D-stdin-flag   `node` reading stdin is a PROGRAM route;
#       `node -e '…'` proves the program is on argv, so stdin is data
#   D-stdin-script                 accepted over-block: a bare file operand cannot
#       be proven without flag-arity knowledge, so it stays a program route
#   D-routes-heredoc vs D-routes-assign   the same heredoc with and without a
#       leading `VAR=1` — the row that ASSIGN_WORD_RE is keyed on (Section M)
#   D-routes-pipe                  an upstream pipeline into a bare interpreter is
#       OPAQUE (o=1): it cannot be analysed, so it is not cleared
# ===========================================================================
run_D_nested_bodies() {
run_table D <<'TABLE'
D-eval-yes    | rm /wf/s1@MK@   | evalbody | eval rm /wf/s1@MK@
D-eval-wrap   | rm /wf/s1@MK@   | evalbody | command eval rm /wf/s1@MK@
D-eval-no     | -               | evalbody | echo hi
D-hs-raw      | 'rm /wf/s1@MK@' | herestr | sh <<< 'rm /wf/s1@MK@'
D-hs-val      | rm /wf/s1@MK@   | hereval | sh <<< 'rm /wf/s1@MK@'
D-hs-none     | -               | herestr | echo hi
D-nested-eval | rm /wf/s1@MK@   | nestedtexts | eval rm /wf/s1@MK@
D-nested-hs   | 'rm /wf/s1@MK@' | nestedtexts | sh <<< 'rm /wf/s1@MK@'
D-nested-none | -               | nestedtexts | echo hi
D-stdin-bare   | language | stdinkind | node
D-stdin-shell  | shell    | stdinkind | sh
D-stdin-flag   | -        | stdinkind | node -e "x"
D-stdin-script | language | stdinkind | node script.js
D-stdin-cat    | -        | stdinkind | cat
D-routes-heredoc | b=1,f=0,o=0 | routes | node <<EOF\nx\nEOF\n
D-routes-assign  | b=1,f=0,o=0 | routes | FOO=1 node <<EOF\nx\nEOF\n
D-routes-pipe    | b=0,f=0,o=1 | routes | cat /wf/s1@MK@ | node
D-routes-none    | b=0,f=0,o=0 | routes | echo hi
TABLE
}
