"use strict";
// Equivalence corpus (#2134 Step 1). The single owner of parse()'s input set.
// Read by probe.js / expected.json / snapshot.sh / shape-contract.sh / consumer-contract.sh.
// Step 2 is designed to swap out only the internal parser without changing the public contract,
// so the fact that the contract hasn't moved can only be shown mechanically via a snapshot diff
// over this fixed input set.

// id is immutable (it's the expected.json key and what deliberate-diffs.js refers to). Rewriting
// an existing id's cmd is forbidden -- that would mean "a different case claiming the same id" --
// add a new id for a new shape instead.
// Shape: { id, label, cmd, opts? } / cmd is exactly parse()'s first argument (non-strings are
// deliberately included too).

module.exports = [
  // --- A: degenerate input -------------------------------------------------------
  { id: "a01-single", label: "single command", cmd: "git status" },
  { id: "a02-empty-string", label: "empty string", cmd: "" },
  { id: "a03-whitespace-only", label: "whitespace only", cmd: "   " },
  { id: "a04-non-string-null", label: "non-string: null", cmd: null },
  { id: "a05-non-string-number", label: "non-string: number", cmd: 42 },
  { id: "a06-non-string-object", label: "non-string: object", cmd: { rawText: "git status" } },

  // --- B: separators (including leading/trailing forms) -------------------------------------
  { id: "b01-and", label: "&& separator", cmd: "git merge && git push" },
  { id: "b02-or", label: "|| separator", cmd: "a || b" },
  { id: "b03-semicolon", label: "; separator", cmd: "git stash; git pull" },
  { id: "b04-pipe", label: "| separator", cmd: "cmd | tee file" },
  { id: "b05-trailing-amp", label: "trailing & (1 segment / 1 separator)", cmd: "git pull &" },
  { id: "b06-leading-amp", label: "leading & (pwsh call operator shape)", cmd: "& git.exe status" },
  { id: "b07-leading-semicolon", label: "leading ;", cmd: "; rm -rf /" },
  { id: "b08-trailing-and", label: "trailing &&", cmd: "git pull &&" },
  { id: "b09-multi-separator", label: "&& and ; in one line", cmd: "a && b; c" },

  // --- C: grouping and process substitution --------------------------------------
  { id: "c01-subshell", label: "subshell ( ... )", cmd: "(cd x && ls)" },
  { id: "c02-procsub-in", label: "process substitution <(...)", cmd: "git stash <(cat /etc/passwd)" },
  { id: "c03-procsub-out", label: "process substitution >(...)", cmd: "tee >(cat) < in.txt" },
  { id: "c04-brace-group", label: "brace group { ...; }", cmd: "{ echo a; echo b; }" },

  // --- D: all redirect forms ------------------------------------------------
  { id: "d01-out", label: "> redirect", cmd: "echo hi > out.txt" },
  { id: "d02-append", label: ">> redirect", cmd: "echo hi >> out.txt" },
  { id: "d03-stderr", label: "2> redirect", cmd: "make 2> err.log" },
  { id: "d04-amp-out", label: "&> redirect", cmd: "git merge &> /tmp/log" },
  { id: "d05-clobber", label: ">| redirect", cmd: "echo x >| out.txt" },
  { id: "d06-fd-dup-2to1", label: "2>&1 fd-dup (must not split)", cmd: "git merge 2>&1" },
  { id: "d07-fd-dup-1to2", label: "1>&2 fd-dup", cmd: "git merge 1>&2" },
  { id: "d08-fd-close", label: "2>&- fd close", cmd: "git merge 2>&-" },
  { id: "d09-in", label: "< redirect", cmd: "sort < in.txt" },
  { id: "d10-herestring", label: "<<< here-string", cmd: "grep x <<< \"abc\"" },
  { id: "d11-attached-target", label: "attached redirect target >~/x", cmd: "echo hi >~/x" },
  { id: "d12-quoted-target", label: "quoted redirect target", cmd: "echo hi > \"my file.txt\"" },
  { id: "d13-multi-redirect", label: "fd-dups plus file redirect", cmd: "git status 2>&1 1>&2 >/dev/null" },
  { id: "d14-adjacent-fd-dups", label: "adjacent fd-dups", cmd: "git merge main 2>&1 1>&2" },

  // --- E: quoting --------------------------------------------------------
  { id: "e01-single-quote", label: "single-quoted argument", cmd: "git commit -m 'hello world'" },
  { id: "e02-double-quote", label: "double-quoted argument", cmd: "git commit -m \"hello world\"" },
  { id: "e03-ansic", label: "ANSI-C quoting $'...'", cmd: "printf $'line\\n'" },
  { id: "e04-ansic-escaped-quote", label: "ANSI-C with escaped single quote", cmd: "$'it\\'s fine'" },
  { id: "e05-unclosed-sq", label: "unclosed ' (parseFailure pin)", cmd: "git merge 'unclosed" },
  { id: "e06-unclosed-dq", label: "unclosed \" (parseFailure pin)", cmd: "git merge \"unclosed" },
  { id: "e07-unclosed-ansic", label: "unclosed $'... (parseFailure pin)", cmd: "$'unclosed string" },

  // --- F: escaped/quoted separators ---------------------------------
  { id: "f01-escaped-and", label: "backslash-escaped &&", cmd: "echo a \\&\\& b" },
  { id: "f02-sq-and", label: "&& inside single quotes", cmd: "echo 'a && b'" },
  { id: "f03-dq-and", label: "&& inside double quotes", cmd: "echo \"a && b\"" },
  { id: "f04-find-exec", label: "find -exec ... \\;", cmd: "find . -name '*.tmp' -exec rm {} \\;" },
  { id: "f05-sq-substitution", label: "$(...) inside single quotes is literal", cmd: "git commit -m '$(text)'" },
  { id: "f06-sq-procsub", label: "<(...) inside single quotes is literal", cmd: "git commit -m '<(text)'" },

  // --- G: heredoc ---------------------------------------------------------
  { id: "g01-cat-eof", label: "cat <<'EOF'", cmd: "cat <<'EOF'\nbody\nEOF" },
  { id: "g02-python", label: "python3 <<'PY'", cmd: "python3 <<'PY'\nprint(1)\nPY" },
  { id: "g03-node", label: "node <<'JS'", cmd: "node <<'JS'\nconsole.log(1)\nJS" },
  { id: "g04-gh-body-file", label: "gh --body-file - <<'EOF'", cmd: "gh issue create --title x --body-file - <<'EOF'\nbody line\nEOF" },
  { id: "g05-body-operators", label: "heredoc body carrying ' > ; &&", cmd: "cat <<'EOF'\na && b; c > d 'e'\nEOF" },
  { id: "g06-dash-tag", label: "<<-TAG (tab-stripping form)", cmd: "cat <<-EOT\n\tbody\nEOT" },
  { id: "g07-punctuated-tag", label: "tag containing . and -", cmd: "cat <<'MY-TAG.v1'\nbody\nMY-TAG.v1" },
  { id: "g08-unquoted-tag", label: "unquoted heredoc tag", cmd: "cat <<EOF\nbody\nEOF" },
  { id: "g09-heredoc-to-file", label: "redirect plus heredoc on one line", cmd: "cat > out.txt <<'EOF'\nx\nEOF" },
  { id: "g10-opener-only", label: "heredoc opener with no body", cmd: "cat <<'EOF'" },

  // --- H: command substitution ----------------------------------------------------
  { id: "h01-assign-subst", label: "VAR=$(echo x) && echo $VAR", cmd: "VAR=$(echo x) && echo $VAR" },
  { id: "h02-nested-subst", label: "nested $( $(...) )", cmd: "echo $( echo $(date) )" },
  { id: "h03-backtick", label: "backtick substitution", cmd: "echo `date`" },
  { id: "h04-dq-pwd", label: "$(pwd) inside double quotes", cmd: "echo \"$(pwd)/x\"" },
  { id: "h05-bare-subst", label: "bare $(subshell) argument", cmd: "cmd $(subshell)" },
  { id: "h06-arith", label: "arithmetic expansion", cmd: "echo $((1+2))" },
  { id: "h07-param", label: "parameter expansion", cmd: "echo ${HOME}" },

  // --- I: env prefixes and control syntax ------------------------------------
  { id: "i01-env-prefix", label: "A=1 B=2 bash x.sh", cmd: "A=1 B=2 bash x.sh" },
  { id: "i02-env-prefix-quoted", label: "env prefix keeps raw spelling", cmd: "A=1 bash \"tests/x.sh\"" },
  { id: "i03-for-loop", label: "for/do/done", cmd: "for f in x; do bash tests/x.sh; done" },
  { id: "i04-for-loop-env", label: "for/do/done with env prefix", cmd: "for f in x; do A=1 bash tests/x.sh; done" },
  { id: "i05-while", label: "while/do/done", cmd: "while A=1 node tests/y.js; do echo hi; done" },
  { id: "i06-if", label: "if/then/fi", cmd: "if [ -f x ]; then echo y; fi" },

  // --- J: sentinels and newlines ------------------------------------------------
  { id: "j01-sentinel-dq", label: "double-quoted sentinel is not a heredoc", cmd: "echo \"<<WORKFLOW_MARK_STEP_x>>\"" },
  { id: "j02-newline-separated", label: "newline-separated commands (must NOT reach separators)", cmd: "ls\nrm -rf x" },
  { id: "j03-newline-interpreter", label: "newline before an interpreter", cmd: "git stash\nrm -rf /" },

  // --- K: opts.preserveSubstitutionSpans ---------------------------------
  { id: "k01-preserve-spans-on", label: "preserveSubstitutionSpans: true", cmd: "echo $(cat /tmp/tok) > out", opts: { preserveSubstitutionSpans: true } },
  { id: "k02-preserve-spans-off", label: "same command, option OFF (pair for k01)", cmd: "echo $(cat /tmp/tok) > out" },
  { id: "k03-preserve-spans-backtick", label: "preserveSubstitutionSpans over a backtick span", cmd: "echo `cat f` > o", opts: { preserveSubstitutionSpans: true } },
  { id: "k04-preserve-spans-chain", label: "preserveSubstitutionSpans across a && chain", cmd: "VAR=$(echo x) && echo $VAR", opts: { preserveSubstitutionSpans: true } },

  // --- L: shapes existing tests actually depend on --------------------------------
  // Source: tests/feature-1293-canary2-ir.sh, tests/unit-command-ir.sh,
  //       tests/fix-1780-round11-substitution-additivity.sh
  { id: "l01-clean-command", label: "clean command (no separators)", cmd: "git merge" },
  { id: "l02-pipe-tee", label: "pipe into tee", cmd: "git merge | tee log.txt" },
  { id: "l03-bash-c", label: "bash -c with a quoted script", cmd: "bash -c 'git stash'" },
  { id: "l04-chained-bash", label: "interpreter after &&", cmd: "git pull && bash -c script.sh" },
  { id: "l05-chained-python", label: "python3 after &&", cmd: "git pull && python3 script.py" },
  { id: "l06-xargs-pipe", label: "xargs pipeline (bash-guard exemption shape)", cmd: "find . -name '*.tmp' | xargs rm" },
  { id: "l07-xargs-pipe-redirect", label: "xargs pipeline plus redirect", cmd: "find . -name '*.tmp' | xargs rm > out.log" },
  { id: "l08-allow-rule-form", label: "allow-rule form: && lives inside single quotes", cmd: "bash -c 'cd \"$AGENTS_CONFIG_DIR\" && bash \"$AGENTS_CONFIG_DIR/bin/confirm-off\" FLAG on'" },
  { id: "l09-plain-text", label: "plain text, no shell metacharacters", cmd: "normal text" },
  { id: "l10-tee-write", label: "tee write target", cmd: "echo x | tee /tmp/out" },
];
