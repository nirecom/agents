# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, dispatch-provenance, scope:issue-specific
# JS chunk 2/4: fixture table extensions for Sections 11-19 (codex gaps C1-C4/C8/C9 and H1-H3). Appended via Object.assign.
JS_FIXTURES_EXT="$(cat <<'JSEOF'

// ---------------------------------------------------------------------------
// Sections 11-16 — codex-review coverage gaps C1/C2/C3/C4/C8/C9.
// Appended as their own block (Object.assign) so the fixture table above and
// its 89 rows stay byte-identical.
// ---------------------------------------------------------------------------
const BT = String.fromCharCode(96);          // backtick
const CR = String.fromCharCode(13);
const CRLF = CR + NL;

// C1 — VERBATIM production shape: the real /issue-create dispatch, written with
// physical backslash line continuations so `--body "$(cat <<'EOF'` and the
// closing `)" \` genuinely land on their own physical lines. This is the exact
// input class #2064 is about; nothing here may be normalised away.
const CONT = ' ' + BS + NL;
const V1 = DISPATCH + CONT
  + '  --verdict reopen --target 1599' + CONT
  + '  --' + CONT
  + '  --title "T"' + CONT
  + '  --body "$(cat <<' + "'EOF'" + NL
  + 'body line 1' + NL
  + 'body line 2' + NL
  + 'EOF' + NL
  + ')"' + CONT
  + '  --label severity:high';

// C9 — CRLF twin of HDBODY / nlInjSubst.
const HDBODY_CRLF = ' -- --title "T" --body "$(cat <<' + "'EOF'" + CRLF
  + 'body line' + CRLF + 'EOF' + CRLF + ')" --label severity:high && echo ""';
function nlInjSubstCrlf(inj) {
  return ' --body "$(cat <<' + "'EOF'" + CRLF + 'hi' + CRLF + 'EOF' + CRLF + inj + CRLF + ')"';
}

// C8 — nesting ladders. `nestBare` nests unquoted `$( ... )`; `nestDq` nests a
// DQ-wrapped substitution at every level.
function nestBare(n, core) { let s = core; for (let i = 0; i < n; i++) s = 'echo $(' + s + ')'; return s; }
function nestDq(n) { let s = 'echo hi'; for (let i = 0; i < n; i++) s = 'echo "$(' + s + ')"'; return s; }

Object.assign(FIX, {
  // Section 11 — C1 verbatim production fixture
  V1: V1,

  // Section 12 — C2 backtick command substitution
  B1: DISPATCH + ' --title ' + BT + 'cat <<' + "'EOF'" + BT,
  B2: EVIL     + ' --title ' + BT + 'cat <<' + "'EOF'" + BT,
  B3: DISPATCH + ' --title ' + BT + 'rm -rf docs' + BT,
  B4: DISPATCH + ' --title "' + BT + 'cat <<' + "'EOF'" + BT + '"',
  B5: EVIL     + ' --title "' + BT + 'cat <<' + "'EOF'" + BT + '"',
  B6: DISPATCH + ' --title "' + BT + 'rm -rf docs' + BT + '"',

  // Section 13 — C3 heredoc delimiter variants
  D1:  DISPATCH + ' --title "$(cat <<' + "'ENDMARK'" + ')"',
  D2:  EVIL     + ' --title "$(cat <<' + "'ENDMARK'" + ')"',
  D3:  DISPATCH + ' --title "$(cat <<' + "'END-MARK'" + ')"',
  D4:  EVIL     + ' --title "$(cat <<' + "'END-MARK'" + ')"',
  D5:  DISPATCH + ' --title "$(cat <<"END.MARK")"',
  D6:  EVIL     + ' --title "$(cat <<"END.MARK")"',
  D7:  DISPATCH + ' --title "$(cat <<-' + "'EOF'" + ')"',
  D8:  EVIL     + ' --title "$(cat <<-' + "'EOF'" + ')"',
  D9:  DISPATCH + ' --verdict reopen -- --title "T" --body "$(cat <<' + "'END-MARK'"
       + NL + 'b' + NL + 'END-MARK' + NL + ')"',
  D10: EVIL     + ' --verdict reopen -- --title "T" --body "$(cat <<' + "'END-MARK'"
       + NL + 'b' + NL + 'END-MARK' + NL + ')"',
  D11: DISPATCH + ' --verdict reopen -- --title "T" --body "$(cat <<-' + "'EOF'"
       + NL + '\tb' + NL + '\tEOF' + NL + ')"',
  D12: EVIL     + ' --verdict reopen -- --title "T" --body "$(cat <<-' + "'EOF'"
       + NL + '\tb' + NL + '\tEOF' + NL + ')"',

  // Section 14 — C4 nested command substitution
  M1: DISPATCH + ' --title "$(echo $(cat <<' + "'EOF'" + '))"',
  M2: EVIL     + ' --title "$(echo $(cat <<' + "'EOF'" + '))"',
  M3: DISPATCH + ' --body "$(echo $(cat <<' + "'EOF'" + NL + 'hi' + NL + 'EOF' + NL + '))"',
  M4: EVIL     + ' --body "$(echo $(cat <<' + "'EOF'" + NL + 'hi' + NL + 'EOF' + NL + '))"',
  M5: DISPATCH + ' --title "$(echo $(rm -rf docs))"',
  M6: DISPATCH + ' --body "$(echo $(cat <<' + "'EOF'" + NL + 'hi' + NL + 'EOF' + NL
       + 'rm -rf docs' + NL + '))"',

  // Section 15 — C8 substHasNarrowWrite depth / nesting fail-closed
  Z1: DISPATCH + ' --title "$(' + nestBare(8, 'echo hi') + ')"',
  Z2: DISPATCH + ' --title "$(' + nestBare(5, 'rm -rf docs') + ')"',
  Z3: DISPATCH + ' --title "$(' + nestDq(5) + ')"',
  Z4: 'echo hi --title "$(' + nestDq(5) + ')"',

  // Section 16 — C9 CRLF twins
  R1: DISPATCH + ' --verdict reopen --target 1599' + HDBODY_CRLF,
  R2: EVIL     + ' --verdict reopen --target 1599' + HDBODY_CRLF,
  R3: DISPATCH + ' --title x' + CRLF + 'rm -rf /tmp/pwn',
  R4: DISPATCH + ' --title x' + CRLF + 'echo x ' + GT + ' README.md',
  R5: DISPATCH + ' --title x' + CRLF + 'git commit -m x',
  R6: DISPATCH + nlInjSubstCrlf("eval 'rm -rf docs'"),
  R7: DISPATCH + nlInjSubstCrlf('just prose here'),
  R8: 'git status' + CRLF + 'rm /tmp/test-1425-file',
  R9: 'node bin/supervisor-report ' + BS + CRLF + '  --detail ' + BS + CRLF + "  bash -c 'git status'",
});

// ---------------------------------------------------------------------------
// Sections 17-19 — codex test-review HIGH coverage gaps H1/H2/H3 against the
// new dispatch-provenance.js code. Appended as their own Object.assign block so
// every fixture above stays byte-identical.
// ---------------------------------------------------------------------------
// The sanctioned truncated `--body "$(cat <<'EOF'` opener, as a reusable tail.
const TROPEN = ' "$(cat <<' + "'EOF'" + ')"';
const DPATH = '$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-dispatch.sh';

Object.assign(FIX, {
  // Section 17 — H1. Every verb GH_GROUP_A_REGEX accepts, one fixture each.
  // Regex SSOT (patterns.js:86): pr create|edit|close|comment|review,
  // issue create|edit|close|comment, repo create|edit|rename|archive.
  GA1:  'gh pr create --title x --body' + TROPEN,
  GA2:  'gh pr edit 1 --body' + TROPEN,
  GA3:  'gh pr close 1 --comment' + TROPEN,
  GA4:  'gh pr comment 1 --body' + TROPEN,
  GA5:  'gh pr review 1 --body' + TROPEN,
  GA6:  'gh issue create --title x --body' + TROPEN,
  GA7:  'gh issue edit 1 --body' + TROPEN,
  GA8:  'gh issue close 1 --comment' + TROPEN,
  GA9:  'gh issue comment 1 --body' + TROPEN,
  GA10: 'gh repo create foo --description' + TROPEN,
  GA11: 'gh repo edit --description' + TROPEN,
  // rename/archive take no body flag — kind-only rows (no truncated opener).
  GA12: 'gh repo rename newname',
  GA13: 'gh repo archive owner/repo',
  // Destructive verbs deliberately OUTSIDE Group A: must get no provenance and
  // must keep classifying the identical truncated-opener shape as a write.
  GN1: 'gh pr merge 1 --body' + TROPEN,
  GN2: 'gh issue delete 1 --body' + TROPEN,
  GN3: 'gh repo delete owner/repo --body' + TROPEN,

  // Section 18 — H2. loadNarrowWritePredicates narrowness. Each row is a REAL
  // dispatcher command with a narrow write appended (`_T`, top-level segment)
  // or embedded in a `$( ... )` (`_S`), so the dispatcher context is proven not
  // to launder the write. The sanctioned truncated opener rides along on the
  // `_T` shape so the row also shows the clearance being withheld.
  NW1a: DISPATCH + TRUNC_SUBST + ' && Set-Content /tmp/f x',           // isPwshWriteIR
  NW1b: DISPATCH + ' --title "$(Set-Content /tmp/f x)"',
  NW2a: DISPATCH + TRUNC_SUBST + ' && npm install left-pad',           // isPkgMgrWriteIR
  NW2b: DISPATCH + ' --title "$(npm install left-pad)"',
  NW3a: DISPATCH + TRUNC_SUBST + " && sh -c 'rm -rf /tmp/pwn'",        // isInterpreterCWriteIR
  NW3b: DISPATCH + ' --title "$(sh -c ' + "'rm -rf /tmp/pwn'" + ')"',
  NW4a: DISPATCH + TRUNC_SUBST + ' && pwsh -EncodedCommand ZQBjAGgAbwA=', // isEncodedCommandWriteIR
  NW4b: DISPATCH + ' --title "$(pwsh -EncodedCommand ZQBjAGgAbwA=)"',
  NW5a: DISPATCH + TRUNC_SUBST + ' && touch /tmp/f',                   // isExtendedFileOpWriteIR
  NW5b: DISPATCH + ' --title "$(touch /tmp/f)"',

  // Section 19 — H3. Value-taking shell options placed before the script token.
  // segmentDispatchKind resolves the script token by walking argv from the left,
  // so an option VALUE can no longer be mistaken for the script. SOK* are the
  // benign forms that must keep working.
  SO1: 'bash --rcfile "' + DPATH + '" /tmp/evil.sh',
  SO2: 'bash --init-file "' + DPATH + '" /tmp/evil.sh',
  SO3: 'bash --rcfile="' + DPATH + '" /tmp/evil.sh',
  SO4: 'bash -o "' + DPATH + '" /tmp/evil.sh',
  SO5: 'sh --rcfile "' + DPATH + '" /tmp/evil.sh',
  SO6: 'zsh --rcfile "' + DPATH + '" /tmp/evil.sh',
  SO7: 'bash --rcfile "' + DPATH + '" /tmp/evil.sh' + TRUNC_SUBST,
  SO8: 'bash /tmp/evil.sh' + TRUNC_SUBST,
  SOK1: DISPATCH + TRUNC_SUBST,
  SOK2: 'bash -e "' + DPATH + '" --title x' + TRUNC_SUBST,
  SOK3: 'bash -- "' + DPATH + '" --title x' + TRUNC_SUBST,
  SOK4: 'bash --posix -e "' + DPATH + '" --title x',
});
JSEOF
)"
