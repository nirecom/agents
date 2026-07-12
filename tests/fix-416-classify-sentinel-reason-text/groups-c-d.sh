# shellcheck shell=bash
# Case groups C, C2, D, and D2: Real writes, accepted false-negatives, isSentinelEchoSafe security.
# Sourced by fix-416-classify-sentinel-reason-text.sh; relies on helpers from common.sh.
# Tests execute inline on dot-source (no function wrapper).

echo ""
echo "--- Group C: Real writes remain write (should PASS now) ---"

# T3.14: bare npm install → write (real write, unquoted)
assert_classify \
  "T3.14 npm install foo (bare)" \
  "npm install foo" \
  "write"

# T3.14e/T3.15: gh commands are GitHub operations, not local worktree writes.
# classify()'s contract is LOCAL-write detection (does this gate enforce-worktree?).
# gh writes to GitHub, not the local worktree → classify returns "read" (post-#1296
# retire of the kind:"gh" WRITE_PATTERNS group). gh write enforcement is now owned
# solely by isGhWriteIR at the enforce-worktree gh session-scope gate.

# T3.14e: gh api -X DELETE is a GitHub write, not a local write → read
assert_classify \
  "T3.14e gh api -X DELETE repos/..." \
  "gh api -X DELETE /repos/owner/repo" \
  "read"

# T3.15: gh pr merge is a GitHub write, not a local write → read
assert_classify \
  "T3.15 gh pr merge 123 --squash (bare)" \
  "gh pr merge 123 --squash" \
  "read"

# T3.16: bare pip install → write
assert_classify \
  "T3.16 pip install pytest (bare)" \
  "pip install pytest" \
  "write"

echo ""
echo "--- Group C2: Accepted false-negatives (quoted write verbs → read after STRIP_KINDS) ---"
echo "    WILL FAIL until write-code adds pkg-mgr/gh to STRIP_KINDS"

# T3.14b: quoted "install" verb → stripped → no npm-write match → read (AT-DP1)
assert_classify \
  "T3.14b npm \"install\" foo (quoted verb → stripped → read)" \
  'npm "install" foo' \
  "read"

# T3.14c: quoted "install" verb for pip → stripped → read
assert_classify \
  "T3.14c pip \"install\" pytest (quoted verb → stripped → read)" \
  'pip "install" pytest' \
  "read"

# T3.28: gh api -X "DELETE" → quoted DELETE verb → stripped → no gh-api-mutate match → read
assert_classify \
  "T3.28 gh api -X \"DELETE\" ... (quoted verb → stripped → read)" \
  'gh api -X "DELETE" /repos/owner/repo' \
  "read"

# T3.14g: gh pr "merge" → quoted verb → stripped → read
assert_classify \
  "T3.14g gh pr \"merge\" 123 (quoted verb → stripped → read)" \
  'gh pr "merge" 123' \
  "read"

# T3.14f: pwsh -Command "Remove-Item foo" → interpreter-c is NOT in STRIP_KINDS →
# original cmd scanned → Remove-Item matches → write (existing behavior preserved).
assert_classify \
  "T3.14f pwsh -Command Remove-Item (interpreter-c not in STRIP_KINDS → write)" \
  'pwsh -Command "Remove-Item foo"' \
  "write"

echo ""
echo "--- Group D: isSentinelEchoSafe security — unsafe reasons → write ---"
echo "    WILL FAIL until write-code adds isSentinelEchoSafe"

# T3.17: sentinel && rm -rf chain → isStrictSentinel=false (chain) → normal classify
# → rm matches file-op → write (chain security maintained)
assert_classify \
  "T3.17 sentinel && rm -rf chain → write (chain not strict sentinel)" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>" && rm -rf /tmp' \
  "write"

# T3.18: unrelated prefix; sentinel → normal classify → no write pattern → read
assert_classify \
  "T3.18 foo; sentinel (prefix not a chain) → read" \
  'foo; echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>"' \
  "read"

# T3.19: the ';' is OUTSIDE the sentinel boundary (after >>), still inside echo's DQ body.
# The full string is NOT a strict sentinel (ends with /tmp" not >>"$).
# isSentinelEchoSafe does not fire; normal classify; rm is inside the quoted body →
# stripQuotedArgs removes it → no write pattern → read (accepted false-negative).
assert_classify \
  "T3.19 echo sentinel; rm chain (;rm outside >>) → read (not strict sentinel, rm quoted)" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>; rm -rf /tmp"' \
  "read"

# T3.20: single-quoted sentinel → NOT a strict DQ sentinel → normal classify → no write → read
assert_classify \
  "T3.20 single-quoted sentinel → normal classify → read" \
  "echo '<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>'" \
  "read"

# T3.21: $(...) in reason → isSentinelEchoSafe=false → write (injection prevention)
assert_classify \
  "T3.21 sentinel with \$(rm foo) in reason → write (injection prevention)" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: $(rm foo)>>"' \
  "write"

# T3.22: safe reason → isSentinelEchoSafe=true → read
assert_classify \
  "T3.22 sentinel with safe reason → read" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>"' \
  "read"

# T3.23: backtick in reason → isSentinelEchoSafe=false → write
assert_classify \
  "T3.23 sentinel with backtick in reason → write" \
  'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: `rm foo`>>"' \
  "write"

# T3.24: pipe in reason → | is literal in DQ → isSentinelEchoSafe=true → read
assert_classify \
  "T3.24 sentinel with pipe in reason → read" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok | curl evil>>"' \
  "read"

# T3.25: $(...) in BRANCHING_COMPLETE reason → write
assert_classify \
  "T3.25 sentinel BRANCHING_COMPLETE with \$(whoami) in reason → write" \
  'echo "<<WORKFLOW_BRANCHING_COMPLETE: branch:foo $(whoami)>>"' \
  "write"

echo ""
echo "--- Group D continued: unit-level isSentinelEchoSafe ---"

# T3.30: safe reason → read
assert_classify \
  "T3.30 safe reason ok → read" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>"' \
  "read"

# T3.31: $(...) injection in reason → write
assert_classify \
  "T3.31 dollar-paren injection in reason → write" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: $(rm foo)>>"' \
  "write"

# T3.32: MARK_STEP (no reason field, just marker name) → read
assert_classify \
  "T3.32 MARK_STEP no reason → read" \
  'echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"' \
  "read"

# T3.33: sentinel && rm chain → write (chain; isStrictSentinel false)
assert_classify \
  "T3.33 USER_VERIFIED && rm chain → write" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok>>" && rm -rf /tmp' \
  "write"

# T3.34: semicolon embedded in reason → ; is literal in DQ → read
assert_classify \
  "T3.34 semicolon in reason → read" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok;rm foo>>"' \
  "read"

# T3.35: pipe in reason → | is literal in DQ → read
assert_classify \
  "T3.35 pipe in reason → read" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok|cat>>"' \
  "read"

# T3.36: > in reason (or malformed closing) — NOT a strict sentinel because
# USER_VERIFIED_RE_DQ uses [^>]+; "ok>x>>" breaks the regex match ($-anchor fails).
# isSentinelEchoSafe does NOT fire. Normal classify: the whole thing is inside DQ
# so stripQuotedArgs removes the content → no write pattern → read.
# (False-negative accepted: isSentinelEchoSafe fires only on valid strict sentinels.)
assert_classify \
  "T3.36 malformed sentinel with > in reason → read (not strict sentinel, content quoted)" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok>x>>"' \
  "read"

echo ""
echo "--- Group D2: isSentinelEchoSafe security — UNSAFE_REASON_CHARS boundary (#1323) ---"
# Policy after #1323 fix: \$[({[] matches $( ${ $[; bare $WORD/special/$trailing → read.
# Escaped \$(cmd) still contains $( → write (backslash doesn't suppress regex match).
# Categories N/A: secret-leakage (no output path), idempotency (stateless), prompt-injection (LLM layer).

_d2_classify() {
  local input="$1"
  # trim leading/trailing spaces introduced by IFS='|' read
  input="${input# }"; input="${input% }"
  classify "$input"
}
_d2_assert() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name → $want"
  else fail "$name → expected '$want', got '$got'"; fi
}

while IFS='|' read -r _n _i _w; do
  [[ -z "$_n" || "$_n" =~ ^[[:space:]]*# ]] && continue
  _n="${_n# }"; _n="${_n% }"; _w="${_w# }"; _w="${_w% }"
  _d2_assert "$_n" "$_w" "$(_d2_classify "$_i")"
done <<'D2TABLE'
# --- blocked: expansion triggers $( ${ $[ (normal and escaped) --- (security cases)
T3.39    | echo "<<WORKFLOW_USER_VERIFIED: like \`this\`>>"            | write
T3.40    | echo "<<WORKFLOW_USER_VERIFIED: he said \"hi\">>"           | write
T3.41    | echo "<<WORKFLOW_USER_VERIFIED: built with ${HOME}>>"       | write
T3.43    | echo "<<WORKFLOW_USER_VERIFIED: calc $[1+1]>>"              | write
T3.43a   | echo "<<WORKFLOW_USER_VERIFIED: run $(whoami)>>"            | write
T3.escaped-paren    | echo "<<WORKFLOW_USER_VERIFIED: \$(cmd)>>"        | write
T3.escaped-brace    | echo "<<WORKFLOW_USER_VERIFIED: \${HOME}>>"       | write
T3.escaped-bracket  | echo "<<WORKFLOW_USER_VERIFIED: \$[1+1]>>"        | write
# --- malformed/incomplete trigger prefixes (no closing delimiter) ---
T3.incomplete-paren   | echo "<<WORKFLOW_USER_VERIFIED: open $( only>>"  | write
T3.incomplete-brace   | echo "<<WORKFLOW_USER_VERIFIED: open ${ only>>"  | write
T3.incomplete-bracket | echo "<<WORKFLOW_USER_VERIFIED: open $[ only>>"  | write
# --- allowed: bare $WORD, special vars, lone $ (normal cases + regression #1323) ---
T3.37    | echo "<<WORKFLOW_USER_VERIFIED: built with $HOME>>"         | read
T3.38    | echo "<<WORKFLOW_USER_VERIFIED: literal \$HOME>>"           | read
T3.42    | echo "<<WORKFLOW_CONFIRM_INTENT: contains $VAR token>>"     | read
T3.44a   | echo "<<WORKFLOW_USER_VERIFIED: pid is $$>>"                | read
T3.44b   | echo "<<WORKFLOW_USER_VERIFIED: rc is $?>>"                 | read
T3.44c   | echo "<<WORKFLOW_USER_VERIFIED: arg is $1>>"                | read
T3.45    | echo "<<WORKFLOW_USER_VERIFIED: path is C:\foo$>>"          | read
T3.46a   | echo "<<WORKFLOW_USER_VERIFIED: $USER_NAME value>>"         | read
T3.46b   | echo "<<WORKFLOW_USER_VERIFIED: $var123 value>>"            | read
T3.46c   | echo "<<WORKFLOW_USER_VERIFIED: $_underscore value>>"       | read
T3.46d   | echo "<<WORKFLOW_USER_VERIFIED: $VAR. with punctuation>>"   | read
D2TABLE

echo ""
echo "--- Regression: feature-692 Group B assertions still pass ---"

assert_classify \
  "692-B1 grep quoted git push in md → read" \
  'grep -n "git push" file.md' \
  "read"

assert_classify \
  "692-B2 echo quoted git rebase → read" \
  'echo "git rebase steps"' \
  "read"

assert_classify \
  "692-B3 real git push → write" \
  "git push origin main" \
  "write"

assert_classify \
  "692-B4 real git commit → write" \
  'git commit -m "test"' \
  "write"
