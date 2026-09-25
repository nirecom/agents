# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, dispatch-provenance, scope:issue-specific
# JS chunk 1/4 of the single node evaluator: module loading, shared constants, base fixture table (Sections 4-10b).
# Concatenation order: JS_FIXTURES_CORE + JS_FIXTURES_EXT + JS_FIXTURES_REGRESSION + JS_PREDICATES (one lexical scope).
JS_FIXTURES_CORE="$(cat <<'JSEOF'
"use strict";
const A = process.env.AGENTS_NODE_DIR;
const { parse } = require(A + "/hooks/lib/command-ir");
const T = require(A + "/hooks/lib/bash-write-targets");
const NL = "\n";
const BS = String.fromCharCode(92);
const GT = ">";

const DISPATCH = 'bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-dispatch.sh"';
const EVIL     = 'bash /tmp/evil.sh';
const TRAV     = 'bash "../../bin/github-issues/issue-create-dispatch.sh"';
const OSTMP    = 'bash "/tmp/bin/github-issues/issue-create-dispatch.sh"';
// `--body "$(cat <<'EOF' ... EOF )"` — the real /issue-create dispatch shape.
const HDBODY = ' -- --title "T" --body "$(cat <<' + "'EOF'" + NL + 'body line' + NL + 'EOF' + NL + ')" --label severity:high && echo ""';
const TAIL_REOPEN = ' --verdict reopen --target 1599' + HDBODY;
const TAIL_SUBOF  = ' --verdict sub-of --parent 1249' + HDBODY;
const TRUNC_SUBST = ' --title "$(cat <<' + "'EOF'" + ')"';
// Section 10 shape: a COMPLETE quoted `cat` here-doc opens the `$( ... )` body,
// and the payload rides a newline-injected line AFTER the EOF terminator but
// still INSIDE the command substitution. `inj` is that injected line.
function nlInjSubst(inj) {
  return ' --body "$(cat <<' + "'EOF'" + NL + 'hi' + NL + 'EOF' + NL + inj + NL + ')"';
}

const FIX = {
  // Section 4 — isNewlineInjectedWriteIR
  N2a: DISPATCH + TAIL_REOPEN,
  N2b: DISPATCH + TAIL_SUBOF,
  N2c: DISPATCH + ' --verdict sub-of --parent 1249 -- --title "T"'
       + ' --body "$(cat <<' + "'X'" + NL + 'b1' + NL + 'X' + NL + ')"'
       + ' --note "$(cat <<' + "'Y'" + NL + 'b2' + NL + 'Y' + NL + ')" && echo ""',
  N2d: DISPATCH + ' --title x' + NL + 'rm -rf /tmp/pwn',
  N2e: DISPATCH + ' --title x' + NL + 'echo x ' + GT + ' README.md',
  N2f: DISPATCH + ' --title x' + NL + 'bash <<' + "'EOF'" + NL + 'rm -rf /tmp/pwn' + NL + 'EOF',
  N2g: DISPATCH + ' --title x' + NL + 'cat <<' + "'EOF'" + ' | bash' + NL + 'rm -rf /tmp/pwn' + NL + 'EOF',
  N2h: DISPATCH + ' --title x' + NL + 'cat <<EOF' + NL + '$(rm -rf /tmp/pwn)' + NL + 'EOF',
  N2i: DISPATCH + ' --verdict reopen --target 1599' + HDBODY.replace('--title "T"', '--title "$(rm -rf /tmp/pwn)"'),
  N2j: DISPATCH + ' --title x' + NL + 'git commit -m x',
  N2k: EVIL  + TAIL_REOPEN,
  N2l: TRAV  + TAIL_REOPEN,
  N2m: OSTMP + TAIL_REOPEN,

  // Section 5 — isCommandSubstWriteIR / isExoticExecWriteIR
  C2a: DISPATCH + TRUNC_SUBST,
  C2b: DISPATCH + ' --title "$(rm -rf /tmp/pwn)"',
  C2c: EVIL + TRUNC_SUBST,
  X2a: DISPATCH + ' --title x && eval "cat <<' + "'EOF'" + '"',
  X2b: EVIL     + ' --title x && eval "cat <<' + "'EOF'" + '"',
  X2c: DISPATCH + ' --title x && eval ' + "'rm -rf /tmp/pwn'",
  X2d: DISPATCH + ' --title x && echo f | xargs rm',

  // Section 6 — provenance layer 1 / layer 2
  P4: 'echo hi && ls -la',
  P5: DISPATCH + ' --title x && echo ""',
  P6: 'gh issue create --title x --body y',
  P7: DISPATCH + ' --title x && rm -rf /tmp/pwn',
  P8: DISPATCH + ' --title x && echo y ' + GT + ' /tmp/o',
  P9: DISPATCH + ' --title x && git commit -m x',
  K1: DISPATCH + ' --title x && echo ok',
  K2: 'gh issue create --title x',
  K3: 'echo hi',
  K4: TRAV + ' --title x',
  K5: OSTMP + ' --title x',
  K6: 'gh issue view 1',
  H1: 'cat <<' + "'EOF'",
  H3: 'cat <<' + "'EOF'" + ' | bash',
  H4: 'cat <<EOF',
  H5: 'bash <<' + "'EOF'",
  H7: 'cat <<' + "'A'" + ' <<B',
  // H9 is the VERBATIM fragment the real dispatch produces after
  // stripHeredocBody + stripDqPreservingCmdSubst (measured, see file header).
  H9: 'bash "" --verdict sub-of --parent 1249 -- --title "" --body ""  cat <<' + "'EOF'",

  // Section 7 — gh argv resolution (must not be "first two non-flag tokens")
  G1a: 'gh --repo owner/repo issue create --title x',
  G1b: 'gh -R owner/repo issue create --title x',
  G1c: 'gh --repo=owner/repo issue create --title x',
  G1d: 'gh --repo owner/repo pr create --title x',
  G1e: 'gh --repo owner/repo issue view 1',
  G2a: 'env FOO=1 gh issue create --title x',
  G2b: 'FOO=1 gh issue create --title x',
  G2c: 'env FOO=1 gh issue comment 1 --body x',
  G2d: 'FOO=1 gh issue comment 1 --body x',

  // Section 8 — consumer level
  S8b: 'echo hi && eval "cat <<' + "'EOF'" + '"',
  S8c: 'echo hi && echo "$(cat <<' + "'EOF'" + ')"',
  S8i: 'echo hi ' + GT + ' /tmp/o.txt',
  S8j: DISPATCH + TRUNC_SUBST + ' && echo ok',
  S8l: 'rm -rf /tmp/pwn',
  S8m: DISPATCH + ' --title x' + NL + 'rm -rf /tmp/pwn',
  S8n: 'git status',

  // Section 9 — mirrors of the existing N1a-N1e cases
  Q1: 'echo clean' + NL + 'rm /tmp/testfile',
  Q2: 'node bin/supervisor-report ' + BS + NL + '  --detail ' + BS + NL + "  bash -c 'git status'",
  Q3: 'git status' + NL + 'git log --oneline -5',
  Q4: 'git status' + NL + 'rm /tmp/test-1425-file',
  Q5: 'gh issue create --body "line1' + NL + 'rm -rf /' + NL + 'line3"',

  // Section 10 — newline-injected line inside a $( ... ) whose body opens with a
  // quoted `cat` here-doc. Found by security scan as a fail-open shape; the
  // source fix added isExoticExecWriteIR to innerCommandIsWrite's OR-chain.
  W1: DISPATCH + nlInjSubst("eval 'rm -rf docs'"),
  W2: DISPATCH + nlInjSubst('find . -name x -exec rm -rf docs {} ;'),
  W3: DISPATCH + nlInjSubst('echo docs | xargs rm -rf'),
  W4: DISPATCH + nlInjSubst('rm -rf docs'),
  W5: DISPATCH + nlInjSubst('just prose here'),
  W6: 'gh issue comment 1 --body ' + nlInjSubst("eval 'rm -rf docs'").replace(' --body ', ''),

  // Section 10b — innerCommandIsWrite reaching isExoticExecWriteIR directly:
  // the exotic exec sits inside a plain (non-heredoc) command substitution.
  E1: 'echo "$(eval ' + "'rm -rf docs'" + ')"',
  E2: 'echo "$(echo docs | xargs rm -rf)"',
  E3: 'echo "$(find . -name x -exec rm -rf docs {} ;)"',
  E4: DISPATCH + ' --title "$(eval ' + "'rm -rf docs'" + ')"',
  E5: 'echo "$(cat /tmp/f)"',
};
JSEOF
)"
