# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, newline-injection, scope:issue-specific
# JS chunk 3/4: fixtures for bash-write-targets.js changes — Y* covers codex HIGH-1 isNewlineInjectedWriteIR; T* covers includeCmdSubstBody boundary.
JS_FIXTURES_REGRESSION="$(cat <<'JSEOF'
// `inner` rides inside a SINGLE-quoted eval argument, so the newline survives
// the outer DQ/span passes and only the inner re-parse can see it.
function evalNl(inner) { return "eval 'echo hi" + NL + inner + "'"; }

Object.assign(FIX, {
  // Section 10c — HIGH-1. An inner body is itself a command string, so an
  // unquoted newline separates commands there exactly as at top level. Before
  // the fix the recursion never asked.
  Y1: evalNl('rm -rf docs'),                        // top level
  Y2: 'echo "$(' + evalNl('rm -rf docs') + ')"',    // wrapped in a substitution
  Y3: evalNl('echo bye'),                           // NEGATIVE: read-only twin
  Y4: 'echo "$(' + evalNl('echo bye') + ')"',       // NEGATIVE: wrapped twin
  // Dispatcher-cleared-ctx counterpart: the SAME inner-newline shape carrying
  // only the sanctioned truncated `cat` opener. Y6 is the non-dispatch control
  // proving the clearance — not the shape — is what makes Y5 read.
  Y5: DISPATCH + nlInjSubst("cat <<'EOF2'"),
  Y6: EVIL     + nlInjSubst("cat <<'EOF2'"),

  // Section 10d — the option must not touch the TOP-LEVEL split. Its
  // substitution-interior half reuses M3/M4/M6 above (CPR-SSOT).
  T4: "cat <<'EOF'" + NL + 'body' + NL + 'EOF' + NL + 'rm -rf x',
  T5: 'echo x' + NL + 'rm -rf docs',
  T6: 'echo x' + NL + 'echo y',
  T7: "cat <<'EOF'" + NL + 'body' + NL + 'EOF' + NL + 'echo done',
});

// Section 10e — UNQUOTED expanding-frame newline injection. The IR parser does
// not keep a newline-crossing `$(` opener as one token, so no substitution
// fragment survives for isCommandSubstWriteIR to recurse into: the raw
// (inclusive) newline split is the ONLY detector for these shapes. Wrapping the
// payload in ever-deeper unquoted substitutions must not change that, so U4* is
// generated rather than hand-written (CPR-UNV: the whole depth domain, not one
// observed case).
function nestSubst(depth) {
  let s = 'echo hi' + NL + 'rm -rf docs';
  for (let i = 0; i < depth; i++) s = 'echo $(' + s + ')';
  return s;
}

Object.assign(FIX, {
  U1: nestSubst(1),                                   // unquoted command substitution
  U2: '(echo hi' + NL + 'rm -rf docs)',               // bare subshell
  U3: 'diff <(echo hi' + NL + 'rm -rf docs) /dev/null', // process substitution
  U4b: nestSubst(2),
  U4c: nestSubst(3),
  U4d: nestSubst(4),
  U4e: nestSubst(5),
  U4f: nestSubst(6),
  // Redirect write injected inside an unquoted substitution.
  U5: 'echo $(echo hi' + NL + 'echo x ' + GT + ' /tmp/pwn)',
  // Frame-interior line carrying BOTH a dangling here-doc opener (its delimiter
  // never terminates on that line — a split artifact, body already removed by
  // stripHeredocBody) AND a real redirect write. The opener is not trailing, so
  // isSplitArtifactHeredocLine cannot skip the line and the write is judged.
  U6: "echo $(cat <<'EOF' " + GT + ' /tmp/pwn' + NL + 'hi' + NL + 'EOF' + NL + ')',
  // NEGATIVE twins: identical frames, read-only injected line.
  U7: 'echo $(echo hi' + NL + 'echo bye)',
  U8: '(echo hi' + NL + 'echo bye)',
});
JSEOF
)"
