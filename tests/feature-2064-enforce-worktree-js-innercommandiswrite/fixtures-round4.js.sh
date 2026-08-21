# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, newline-injection, scope:issue-specific
# JS chunk 3b/5: round-4 security-scan regression fixtures (F*). stripDanglingHeredocOpeners removed; F1-F4 cover fail-open axes.
# See hooks/lib/bash-write-targets.js (isSplitArtifactHeredocLine). Concatenated after JS_FIXTURES_REGRESSION, before JS_PREDICATES.
JS_FIXTURES_ROUND4="$(cat <<'JSEOF'
// The here-doc opener is piped into a shell, so it is NOT trailing and the
// payload rides its body. Every expanding frame must keep this WRITE.
const F1BODY    = "cat <<'X' | bash" + NL + 'rm -rf docs' + NL + 'X' + NL;
const F1BODY_SH = "cat <<'X' | sh"   + NL + 'rm -rf docs' + NL + 'X' + NL;
// Dispatcher prefix that keeps segment 1 the sanctioned dispatch (so layer-1
// provenance clears) while the payload rides a later segment.
const DPFX = DISPATCH + ' --title x && ';
function nestSubstBody(depth, body) {
  let s = 'echo hi' + NL + body;
  for (let i = 0; i < depth; i++) s = 'echo $(' + s + ')';
  return s;
}

Object.assign(FIX, {
  // F1 — write IS the here-doc opener, across every expanding frame.
  F1a: 'echo $(echo hi' + NL + F1BODY + ')',
  F1b: '(echo hi' + NL + F1BODY + ')',
  F1c: 'diff <(echo hi' + NL + F1BODY + ') /dev/null',
  F1d: 'echo $(echo hi' + NL + F1BODY_SH + ')',
  F1e: nestSubstBody(3, F1BODY),
  // DISPATCH twins: clearance must NOT demote a non-trailing opener.
  F1f: DPFX + 'echo $(echo hi' + NL + F1BODY + ')',
  F1g: DPFX + '(echo hi' + NL + F1BODY + ')',
  F1h: DPFX + 'diff <(echo hi' + NL + F1BODY + ') /dev/null',
  F1i: DPFX + 'echo $(echo hi' + NL + F1BODY_SH + ')',
  F1j: DPFX + nestSubstBody(3, F1BODY),

  // F2 — quote-blind `'<<'`: the old regex saw a here-doc operator inside a
  // single-quoted word and rewrote the line, dropping the real `rm -rf`.
  F2a: 'echo $(echo hi' + NL + "echo '<<' ; rm -rf 'docs')",
  F2b: '(echo hi' + NL + "echo '<<' ; rm -rf 'docs')",
  F2c: DPFX + 'echo $(echo hi' + NL + "echo '<<' ; rm -rf 'docs')",

  // F3 — here-STRING (`<<<`) is not a here-doc opener at all.
  F3a: 'echo $(echo hi' + NL + "bash <<<'rm -rf docs')",
  F3b: DPFX + 'echo $(echo hi' + NL + "bash <<<'rm -rf docs')",

  // F4 — pins condition 2 of isSplitArtifactHeredocLine in the REAL dispatch
  // shape (`--body "$( <complete heredoc> <injected line> )"`, same frame as
  // W1-W5/Y5): a real write BEFORE a trailing opener must still be judged.
  // F4d/F4e are the EVIL twins proving dispatch clearance is what decides.
  F4a: DISPATCH + nlInjSubst("rm -rf docs; cat <<'EOF2'"),
  F4b: DISPATCH + nlInjSubst("git commit -m x; cat <<'EOF2'"),
  F4c: DISPATCH + nlInjSubst("echo x " + GT + " /tmp/pwn; cat <<'EOF2'"),
  F4d: EVIL + nlInjSubst("rm -rf docs; cat <<'EOF2'"),
  F4e: EVIL + nlInjSubst("git commit -m x; cat <<'EOF2'"),

  // TP* — TOP-LEVEL `cat <<'X' | bash` (round-4 finding 82df8d25). TP1-TP3/TP6
  // are a KNOWN PRE-EXISTING FAIL-OPEN, byte-identical on HEAD baseline
  // 633935d2, so their rows assert the measured READ. TP4/TP5 are the WRITE
  // controls that bound it. TP3t/TP6t (EVIL) and TP3n/TP6n (no dispatcher at
  // all) are the CPR-ORTH controls: same shape without clearance.
  TP1: "cat <<'X' | bash" + NL + 'rm -rf docs' + NL + 'X',
  TP2: "cat <<'X' | sh"   + NL + 'git push --force' + NL + 'X',
  TP3: DISPATCH + ' --verdict none && ' + "cat <<'X' | bash" + NL + 'rm -rf docs' + NL + 'X',
  TP4: "cat <<'X' | bash",                                   // single line, no body
  TP5: "bash <<'X'" + NL + 'rm -rf docs' + NL + 'X',         // interpreter heredoc
  TP6: DISPATCH + ' --body "$(' + "cat <<'X' | bash" + NL + 'rm -rf docs' + NL + 'X' + NL + ')"',
  TP3t: EVIL + ' --verdict none && ' + "cat <<'X' | bash" + NL + 'rm -rf docs' + NL + 'X',
  TP3n: "cat <<'X' | bash" + NL + 'rm -rf docs' + NL + 'X',
  TP6t: EVIL + ' --body "$(' + "cat <<'X' | bash" + NL + 'rm -rf docs' + NL + 'X' + NL + ')"',
  TP6n: 'echo --body "$(' + "cat <<'X' | bash" + NL + 'rm -rf docs' + NL + 'X' + NL + ')"',
});
JSEOF
)"
