#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-5 sections: the SHELL-SYNTAX holes that let a protected write reach the
# filesystem while hooks/block-off-clearance-write/bash-scan.js saw nothing.
#
# Every case below was ALLOW before the round-5 fix and must now BLOCK. Each is
# paired with a CPR-5 sanctioned counterpart that must stay ALLOW - a scanner
# that blocks `2>&1` or `awk '{print $1}' data.txt` is a different, equally real
# defect, and every one of these holes is closed by a broadening change whose
# natural failure mode is over-blocking.
#
#   R5-1 (HIGH-1)  `>|` / `>&` were absent from the redirect-operator alternation,
#                  so the parser never saw a redirect: the write target degenerated
#                  into the NEXT segment's cmd0 and was classified as a command
#                  name. Fixed in hooks/lib/command-parser.js (operators added) AND
#                  bash-scan.js (cmd0 is now itself a protected-name candidate, so
#                  the degenerate parse is caught from both ends).
#   R5-2 (HIGH-2)  a trailing `#'` is a legal bash comment but leaves the tokenizer
#                  with an unbalanced quote -> parseFailure -> the old scan simply
#                  ABANDONED. Parse failure is now fail-CLOSED whenever the raw
#                  text mentions a protected name (unparsedVerdict()).
#   R5-3 (HIGH-3)  `eval` takes no `-c`-style flag, so the interpreter gate never
#                  fired on it. The body is now recursed back through the whole
#                  scan (hooks/block-off-clearance-write/nested-bodies.js), and
#                  `command`/`builtin`/`exec` wrappers cannot launder it.
#   R5-4 (MED-4)   backtick command substitution was not scanned even though
#                  `$( )` already was - an orthogonality hole (CPR-5).
#   R5-5 (MED-5)   here-string bodies (`sh <<< "..."`, `xargs -I{} sh -c ... <<<`)
#                  are command text for the reader that executes them.
#   R5-6 (MED-6)   BODY-FIRST interpreters (awk & family, tclsh, php, lua, Rscript,
#                  osascript, expect, env, xargs) take their program as a bare
#                  argument, so the `-c`/`-e`-keyed gate missed all of them.
#   R5-7 (codex H) `less` sat in a categorical read-only allowlist that returned
#                  BEFORE looking at argv - but `less -o/-O/--log-file` CREATES the
#                  named file. The allowlist entry is now conditional on those.
#
# TABLE FORMAT: name|want|payload. `want` is the strict verdict token from the
# suite's classify() (approve|block|...), never "not-block": a crash, a timeout or
# empty stdout must never score as an allow on a security scanner.
# The payload is the LAST field, so a payload may itself contain `|` (`>|`, pipes).
# @DIR@ -> the sandbox workflow dir, @MK@ -> a marker basename, @TOK@ -> a token
# basename; both are derived from the suite's SSOT-introspected fixtures.

# _run_r5_table <section-label>  (reads the table on stdin)
_run_r5_table() {
    local section="$1" name want payload
    while IFS='|' read -r name want payload; do
        case "$name" in ''|\#*) continue ;; esac
        name="${name%"${name##*[![:space:]]}"}"
        want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
        payload="${payload#"${payload%%[![:space:]]*}"}"
        payload="${payload//@DIR@/$WFDIR}"
        payload="${payload//@MK@/$SID.workflow-off}"
        payload="${payload//@TOK@/$SID.off-clearance}"
        assert_verdict "$section $name" "$want" \
            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(mk_bash_input "$payload" "$LINKED_WT")")"
    done
}

# run_R5_shell_syntax - R5-1 .. R5-4 (parser-level holes)
run_R5_shell_syntax() {
    _run_r5_table "R5" <<'TABLE'
CTRL-1|block|echo x > @DIR@/@MK@
CTRL-2|block|sh -c 'echo {} > @MK@'
1-a|block|echo x >| @DIR@/@MK@
1-b|block|echo x >& @DIR@/@MK@
1-c|block|echo x >| @DIR@/@TOK@
1-d|block|echo x >& @DIR@/@TOK@
1-e|block|echo x 2>| @DIR@/@MK@
1-nr1|approve|ls @DIR@ 2>&1
1-nr2|approve|echo hi >&1
1-nr3|approve|echo hi >&-
1-nr4|approve|cat foo 3>&2
1-nr5|approve|echo hi > /dev/null
1-nr6|approve|make build > /tmp/build.log 2>&1
2-a|block|echo x > @DIR@/@MK@ #'
2-b|block|echo x > @DIR@/@TOK@ #'
2-nr1|approve|echo hi > /tmp/out.txt #'
2-nr2|approve|grep -n "it's" README.md #'
3-a|block|cd @DIR@ && eval 'echo {} > @MK@'
3-b|block|cd @DIR@ && command eval 'echo {} > @MK@'
3-c|block|eval "echo x > @DIR@/@TOK@"
3-nr1|approve|eval 'echo hello'
3-nr2|approve|eval "$(direnv hook bash)"
4-a|block|echo x > `printf @MK@`
4-b|block|cp /tmp/f `printf @DIR@/@MK@`
4-c|block|tee `echo @MK@` </tmp/f
4-d|block|echo x > $(printf @MK@)
4-nr1|approve|echo `date` > /tmp/log.txt
4-nr2|approve|cp /tmp/f `printf /tmp/dest.txt`
TABLE
}

# run_R5_nested_bodies - R5-5 / R5-6 (text that BECOMES a command line)
run_R5_nested_bodies() {
    _run_r5_table "R5" <<'TABLE'
5-a|block|sh <<< "echo {} > @DIR@/@MK@"
5-b|block|xargs -I{} sh -c 'echo x > {}' <<< @MK@
5-nr1|approve|sh <<< "echo hello"
5-nr2|approve|xargs -I{} echo {} <<< hello
6-a|block|awk 'BEGIN{print "{}" > "@DIR@/@MK@"}'
6-b|block|gawk 'BEGIN{print "x" > "@DIR@/@TOK@"}'
6-c|block|php -r 'file_put_contents("@DIR@/@MK@","x");'
6-d|block|lua -e 'io.open("@DIR@/@MK@","w")'
6-e|block|Rscript -e 'writeLines("x","@DIR@/@MK@")'
6-f|block|osascript -e 'do shell script "touch @DIR@/@MK@"'
6-g|block|tclsh forge.tcl @DIR@/@MK@
6-h|block|env -S 'sh -c "echo x > @DIR@/@MK@"'
6-nr1|approve|awk '{print $1}' data.txt
6-nr2|approve|env FOO=1 make build
6-nr3|approve|xargs rm < list.txt
6-nr4|approve|node -e "console.log(process.env.HOME)"
6-nr5|approve|pwsh -Command 'Get-Content $env:HOMEPATH'
TABLE
}

# run_R5_readonly_allowlist - R5-7 (`less` is read-only ONLY without -o/-O/--log-file)
run_R5_readonly_allowlist() {
    _run_r5_table "R5" <<'TABLE'
7-a|block|less -o @DIR@/@MK@
7-b|block|less -O @DIR@/@MK@
7-c|block|less --log-file=@DIR@/@MK@
7-d|block|less -o @DIR@/@TOK@
7-nr1|approve|less @DIR@/@MK@
7-nr2|approve|cat @DIR@/@MK@
7-nr3|approve|grep -n x @DIR@/@TOK@
7-nr4|approve|less -N @DIR@/@MK@
7-nr5|approve|less -o /tmp/session.log
TABLE
}
