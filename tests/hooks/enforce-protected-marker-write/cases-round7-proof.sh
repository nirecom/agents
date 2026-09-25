#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-7: WHO PROVES THE PROGRAM IS ON ARGV?
#
# Round-6 routed stdin bodies by the receiving command's interpreter identity,
# but decided "argv already carries the program" from argv SHAPE - the first
# non-flag word was read as the program operand. A flag's own VALUE is a
# non-flag word, so one shifted token cleared a byte-identical body:
#
#     node <<< '<program>'              -> BLOCK
#     node --title x <<< '<program>'    -> ALLOW   (`x` mistaken for the program)
#
# Knowing that `--title` consumes a value needs a per-interpreter, per-version
# flag-arity table - the enumeration-lag failure mode CPR-UNV rejects. So round 7
# moves the burden of proof onto the ALLOW side: the stdin body is PROGRAM text
# unless argv carries an inline-program flag (`-c`/`-e`/`--eval`/`-Command`
# family) THAT HAS A BODY. A bodyless `-e` proves nothing - the program then
# genuinely arrives on stdin. The same rule governs every route (here-string,
# heredoc, pipe upstream, `< FILE`), so this section walks the routes for one
# attack shape rather than re-walking every shape per route.
#
# ACCEPTED OVER-BLOCK (12-j/12-k): a bare file operand is no longer proof, so
# `node script.js <<< '<text naming a marker>'` blocks. Feeding marker-naming
# DATA to a script through a here-string is rare; the everyday data-on-stdin
# shapes stay clear via 12-nr1..12-nr6.
#
# Table format and placeholders: see ./cases-round6-stdin.sh.

# run_R7_program_proof - flag VALUES and bare operands are not proof.
run_R7_program_proof() {
    _run_r6_table "R7" <<'TABLE'
12-a flag value node|block|node --title x <<< "require('fs').unlinkSync('@DIR@/@MK@')"
12-b flag value openssl|block|node --openssl-config f <<< "require('fs').unlinkSync('@DIR@/@MK@')"
12-c flag value max-old-space|block|node --max-old-space-size 512 <<< "require('fs').unlinkSync('@DIR@/@MK@')"
12-d flag value python3 -X|block|python3 -X importtime <<< "import os; os.remove('@DIR@/@MK@')"
12-e flag value perl -I|block|perl -I lib <<< "unlink('@DIR@/@MK@')"
12-f flag value via pipe|block|printf '%s' "require('fs').unlinkSync('@DIR@/@MK@')" | node --title x
12-g flag value via heredoc|block|node --title x <<EOF@NL@require('fs').unlinkSync('@DIR@/@MK@')@NL@EOF
12-h flag value via < FILE|block|node --title x < @DIR@/@MK@
12-i flag value token family|block|node --title x <<< "require('fs').unlinkSync('@DIR@/@TOK@')"
12-j bare file operand|block|node script.js <<< "require('fs').unlinkSync('@DIR@/@MK@')"
12-k bare file operand py|block|python3 app.py <<< "import os; os.remove('@DIR@/@MK@')"
12-l bodyless -e herestring|block|node -e <<< "require('fs').unlinkSync('@DIR@/@MK@')"
12-m bodyless -e pipe|block|printf '%s' "require('fs').unlinkSync('@DIR@/@MK@')" | node -e
12-n empty -e body heredoc|block|node -e '' <<EOF@NL@require('fs').unlinkSync('@DIR@/@MK@')@NL@EOF
12-nr1 -c proves, stdin is data|approve|cat @DIR@/@MK@ | python3 -c "print(1)"
12-nr2 -e proves, < FILE is data|approve|node -e "console.log(1)" < @DIR@/@MK@
12-nr3 -e proves, herestring data|approve|node -e "console.log(1)" <<< "hello"
12-nr4 attached --eval= proves|approve|node --eval="console.log(1)" <<< "hello"
12-nr5 clustered -uc proves|approve|python3 -uc "print(1)" < @DIR@/@MK@
12-nr6 -Command proves|approve|pwsh -Command "Write-Output 1" < @DIR@/@MK@
12-nr7 benign pipe|approve|printf hi | node
12-nr8 ordinary pipeline|approve|git log | head
12-nr9 benign herestring|approve|node <<< "console.log(1)"
12-nr10 read via -e|approve|node -e "console.log(require('fs').readFileSync('@DIR@/@MK@','utf8'))"
12-nr11 read via <<<|approve|node <<< "console.log(require('fs').readFileSync('@DIR@/@MK@','utf8'))"
12-nr12 read via heredoc|approve|node <<EOF@NL@console.log(require('fs').readFileSync('@DIR@/@MK@','utf8'))@NL@EOF
TABLE
}

# run_R7_flag_lookalikes - `-E` / `-p` / `-P` / `--print` must NOT count as
# proof: each is an inline-program flag in ONE language and an ordinary option
# in another (`perl -E` runs code, `python3 -E` = ignore-environment, `bash -p`
# = privileged), so accepting them as universal proof re-opens the bypass.
#
# KNOWN RED (source bug, reported not worked around): 13-a and 13-b fail today,
# together with the R6-ID `proof family` assertions. INLINE_PROGRAM_FLAG_RE is
# built from FLAG_ALTS, which contains pwsh's progressive `-EncodedCommand`
# prefix chain - whose minimal member is `-E`, case-insensitively. So `-E` IS
# accepted as proof, contradicting the source comment that lists it as
# deliberately excluded, and `printf '<program>' | python3 -E -` clears its own
# pipe route. Only the pipe route is exposed (the here-string and `< FILE`
# spellings still block via the round-5 unconditional here-string scan and the
# path classifier), and `python3 -E -` is a genuinely executable command.
# These cases must stay as written: they are the regression test for the fix.
#
# 13-nr1/13-nr2 pin the round-FIVE rule they are easily confused with: a
# here-string that SPELLS a protected path is scanned unconditionally whoever
# reads it, which is why `node -e '<benign>' <<< '<marker path>'` blocks even
# though `-e` proves the program. `jq`/`wc` block identically - that is not a
# round-7 effect and must not be read as one.
run_R7_flag_lookalikes() {
    _run_r6_table "R7" <<'TABLE'
13-a -E via pipe (see note)|block|printf '%s' "import os; os.remove('@DIR@/@MK@')" | python3 -E -
13-b -E via pipe token|block|printf '%s' "import os; os.remove('@DIR@/@TOK@')" | python3 -E -
13-c -E via herestring|block|python3 -E x <<< "import os; os.remove('@DIR@/@MK@')"
13-d -E via < FILE|block|node -E x < @DIR@/@MK@
13-e -p is not proof|block|node -p x <<< "require('fs').unlinkSync('@DIR@/@MK@')"
13-f -P is not proof|block|node -P x <<< "require('fs').unlinkSync('@DIR@/@MK@')"
13-g --print is not proof|block|node --print x <<< "require('fs').unlinkSync('@DIR@/@MK@')"
13-nr1 round-5 rule, not round-7|block|node -e "console.log(1)" <<< "@DIR@/@MK@"
13-nr2 same rule, no interpreter|block|jq -r . <<< "@DIR@/@MK@"
TABLE
}
