#!/usr/bin/env bash
# tests/fix-1780-round12-parser-unit-tables/cases-interpreter.sh
# Tests: hooks/block-clearance-token-write/interpreter-scan.js, hooks/block-clearance-token-write/nested-bodies.js, hooks/lib/command-ir.js
# Tags: off-clearance, clearance-token, interpreter, interpreter-identity, stdin-program, stdin-route, heredoc, here-string, eval, language-scope, parser, regex, table-driven, classifier, unit, scope:common, pwsh-not-required, TL1, dup-group-keep:distinct-layer
# Part of tests/fix-1780-round12-parser-unit-tables.sh (rules/coding/file-split.md).
# Sections I (interpreter-scan.js) and D (nested-bodies.js), sourced by the parent,
# which owns run_table(), _expand() and the counters.
# Section I covers interpreter identity and inline-program proof: INTERPRETER_RE
# extracts (over-matching is safe), INLINE_PROGRAM_FLAG_RE permits (over-matching
# clears more, so it is unsafe) — the two must never be merged.
# Per-row pairing rationale for both sections: PAIRING.md.
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
I-ro-read     | true  | roshape | node console.log(require('fs').readFileSync('/wf/s1@MK@','utf8'))
I-ro-write    | false | roshape | node require('fs').writeFileSync('/wf/s1@MK@','x')
I-ro-ruby     | false | roshape | ruby console.log(require('fs').readFileSync('/wf/s1@MK@','utf8'))
I-ro-unknown  | false | roshape | zzz console.log(require('fs').readFileSync('/wf/s1@MK@','utf8'))
I-deliv-plain   | node   | deliver | node
I-deliv-path    | python3 | deliver | /usr/bin/PYTHON3.EXE
I-deliv-flagval | ruby   | deliver | ruby -I python3
I-deliv-runner  | python | deliver | uv run python
I-deliv-wrapper | node   | deliver | command node
I-deliv-assign  | node   | deliver | A=1 node
I-deliv-optarg  | -      | deliver | uvx --from python3 ruby
I-deliv-chain   | node   | deliver | cd /x && node
I-deliv-none    | -      | deliver | ls -la
I-hits-write  | true  | hits | node -e "require('fs').writeFileSync('/wf/s1@MK@','x')"
I-hits-clean  | false | hits | node -e "console.log(1)"
I-hits-spoof  | true  | hits | ruby -I python3 -e 'open("|touch /wf/s1@MK@")'
I-hits-runner | false | hits | uv run python -c "print(open('/wf/s1@MK@').read())"
# EOF-GUARD, must stay last: run_table feeds the table through $(cat), which strips
# the trailing newline, so `while read` never sees the final line — a real row here
# would silently assert nothing. Same guard closes every run_table table.
TABLE
}

# Section D — the routes by which COMMAND TEXT reaches a shell without being
# written as a command: `eval`, here-strings, heredocs, pipelines.
# Per-row pairing rationale: PAIRING.md (section D).
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
# The `routes` rows above count buckets; these assert the `lang` FIELD VALUE that
# bash-scan/scan.js forwards to interpreterBodyHitsProtected as the delivering
# interpreter's identity (#1821). A dropped or wrong tag re-scopes the read-only
# shapes silently, and no hook-level row can catch it for a HEREDOC body: every
# recognized read-only shape has parentheses, which command-ir treats as segment
# separators, so the scan fails closed before the language classifier is reached
# (measured in tests/enforce-clearance-token-write/interpreter-language-scope-cases.sh,
# SR-hd5/SR-hd6). This table is therefore the only layer where the tag is visible.
D-lang-hd-node   | node    | routelangs | node <<EOF\nx\nEOF\n
D-lang-hd-ruby   | ruby    | routelangs | ruby <<EOF\nx\nEOF\n
D-lang-hd-path   | /usr/bin/node | routelangs | /usr/bin/node <<EOF\nx\nEOF\n
D-lang-hd-assign | node    | routelangs | FOO=1 node <<EOF\nx\nEOF\n
D-lang-hd-wrap   | ruby    | routelangs | command ruby <<EOF\nx\nEOF\n
D-lang-hd-shell  | -       | routelangs | sh <<EOF\nx\nEOF\n
D-lang-hd-cat    | -       | routelangs | cat <<EOF\nx\nEOF\n
D-lang-hd-argv   | -       | routelangs | node -e "y" <<EOF\nx\nEOF\n
D-lang-hs-node   | node    | routelangs | node <<< 'x'
D-lang-hs-ruby   | ruby    | routelangs | ruby <<< 'x'
D-lang-hs-shell  | -       | routelangs | sh <<< 'x'
# EOF-GUARD, must stay last (see Section I).
TABLE
}
