#!/usr/bin/env bash
# tests/fix-1679-write-detect-false-positives.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/patterns.js, hooks/enforce-worktree/bash-write-scope.js
# Tags: enforce-worktree, classify, write-patterns, security, TL1, pwsh-not-required, scope:issue-specific
# Serial: static-detector false positive retained for declaration parity — the two `rm -rf /tmp/x` hits are inert heredoc table data, never executed

# Issue #1679 — four write-detection heuristics false-positive on read-only
# commands from the main worktree: (1) isExoticExecWriteIR/looksDynamic rejects
# ANY `$`/backtick under eval/xargs/find; (2) isInterpreterCWriteIR's raw
# pre-checks run BEFORE quote-stripping; (3) isCommandSubstWriteIR recurses into
# `$(...)` without the outer Group-A gh context; (4) the here-doc/here-string/
# pwsh-here WRITE_PATTERNS are raw-regex scanned, so quoted PROSE is blocked.

set -uo pipefail

# FP1679-* rows assert the POST-FIX contract → RED before the fix (expected).
# FC1679-* rows are fail-closed security pins → GREEN before AND after the fix.
# PR/SC/SS rows verify the three propagation consumers of these predicates.
# GA rows verify the Group-A gh integration path end to end at the module layer.

PASS=0; FAIL=0; SKIP=0

# TL3 gap (what this test does NOT catch): whether classify.js /
# bash-write-targets.js is actually loaded by the real enforce-worktree.js hook
# process, and whether that process's module resolution finds the same files as
# the direct require() calls here. Closest-to-action mitigation: checked at
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: hook-registration
# Git Bash / MSYS2 rewrites POSIX-looking argv into Windows paths before exec,
# which would corrupt the raw command strings under test. No-op elsewhere.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
if command -v cygpath >/dev/null 2>&1; then WT="$(cygpath -m "$AGENTS_DIR")"; else WT="$AGENTS_DIR"; fi

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# ---------------------------------------------------------------------------
# Node bridges. Every bridge guards typeof/throw and prints ERROR:* rather than
# crashing, so a missing export records a clean FAIL (fail-before-fix posture).
# ---------------------------------------------------------------------------

# classify_ir <cmd> → "read"|"write"
classify_ir() {
  run_with_timeout 30 node -e "
    const {classify}=require('${WT}/hooks/lib/bash-write-patterns');
    const {parse}=require('${WT}/hooks/lib/command-ir');
    try { process.stdout.write(classify(parse(process.argv[1]))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# pred <fnName> <cmd> → "true"|"false"|"ERROR:*" (bash-write-targets exports)
pred() {
  run_with_timeout 30 node -e "
    const m=require('${WT}/hooks/lib/bash-write-targets');
    const {parse}=require('${WT}/hooks/lib/command-ir');
    const fn=m[process.argv[2]];
    if (typeof fn !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    try { process.stdout.write(String(fn(parse(process.argv[1])))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$2" "$1" 2>/dev/null
}

# detect_pred <cmd> → "null" | predicate name (hooks/enforce-worktree/write-detector.js)
detect_pred() {
  run_with_timeout 30 node -e "
    const {detectWritePredicate}=require('${WT}/hooks/enforce-worktree/write-detector');
    const {parse}=require('${WT}/hooks/lib/command-ir');
    try {
      const r = detectWritePredicate(parse(process.argv[1]));
      process.stdout.write(r === null ? 'null' : String(r.name));
    } catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# seg_exotic <cmd> → "true"|"false". Replays the per-segment isExoticExecWriteIR
# early-false branch that isEverySegmentExcluded / areAllWriteSegmentsOutsideSessionScope
# both run (bash-write-scope.js). "true" means the branch fires and the caller
# fails closed before any target is ever collected.
seg_exotic() {
  run_with_timeout 30 node -e "
    const {parse}=require('${WT}/hooks/lib/command-ir');
    const {isExoticExecWriteIR}=require('${WT}/hooks/lib/bash-write-targets');
    try {
      const ir=parse(process.argv[1]);
      let hit=false;
      for (const seg of (ir.segments||[])) {
        const segIr={rawText:seg.rawText,segments:[seg],parseFailure:false,cmd0:seg.cmd0,cmd0Raw:seg.cmd0Raw||'',argv:seg.argv,argvRaw:seg.argvRaw||[],redirects:seg.redirects,kind:seg.kind,separators:[]};
        if (isExoticExecWriteIR(segIr)) hit=true;
      }
      process.stdout.write(String(hit));
    } catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" 2>/dev/null
}

# every_seg_excluded <cmd> → "true"|"false" (isEverySegmentExcluded, pattern '**')
every_seg_excluded() {
  run_with_timeout 30 node -e "
    const {parse}=require('${WT}/hooks/lib/command-ir');
    const s=require('${WT}/hooks/enforce-worktree/bash-write-scope');
    if (typeof s.isEverySegmentExcluded !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    try { process.stdout.write(String(s.isEverySegmentExcluded(parse(process.argv[1]), process.argv[2], ['**']))); }
    catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" "$2" 2>/dev/null
}

# all_out_of_scope <cmd> <repoRoot> → "true"|"false" (areAllWriteSegmentsOutsideSessionScope)
all_out_of_scope() {
  run_with_timeout 30 node -e "
    const {parse}=require('${WT}/hooks/lib/command-ir');
    const s=require('${WT}/hooks/enforce-worktree/bash-write-scope');
    const {normalizeForCompare}=require('${WT}/hooks/enforce-worktree/git-repo-detection');
    if (typeof s.areAllWriteSegmentsOutsideSessionScope !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
    try {
      const root=process.argv[2];
      const roots=new Set([normalizeForCompare(root)]);
      process.stdout.write(String(s.areAllWriteSegmentsOutsideSessionScope(parse(process.argv[1]), root, roots)));
    } catch (e) { process.stdout.write('ERROR:threw'); }
  " -- "$1" "$2" 2>/dev/null
}

# ===========================================================================
# (4) WRITE_PATTERNS heredoc / here-string / pwsh-here on quoted PROSE.
# The `<<'EOF'` / `<<<` / `@'…'@` text is INSIDE a double-quoted argument, so it
# is data, not a redirection operator. classify() must return "read".
# ===========================================================================
echo "=== FP (4): quoting-shape WRITE_PATTERNS on quoted prose → classify read ==="
while IFS='^' read -r name cmd want; do
  case "$name" in ''|'#'*) continue ;; esac
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'T4_TABLE'
FP1679-A classify: supervisor-report --detail with <<'EOF' prose^node "$ACD/bin/supervisor-report" --detail "used <<'EOF' heredoc in the script" --reporter x^read
FP1679-B classify: --detail mentioning the <<< here-string operator^node bin/supervisor-report --detail "the <<< operator is a here-string"^read
FP1679-C classify: --detail mentioning pwsh @'here'@ syntax^node bin/x --detail "uses @'here'@ syntax"^read
FP1679-E classify: bash -c body quoting <<EOF prose^bash -c 'echo "see <<EOF in docs"'^read
T4_TABLE

# ===========================================================================
# (2) isInterpreterCWriteIR — raw pre-checks before quote-stripping.
# FP rows: the reject-trigger character sequence lives inside a quoted string in
# the -c body. FC rows: a LIVE construct or a real write in the body.
# ===========================================================================
echo "=== (2) isInterpreterCWriteIR — FP read bodies / FC write bodies ==="
while IFS='^' read -r name cmd want; do
  case "$name" in ''|'#'*) continue ;; esac
  assert_eq "$name" "$want" "$(pred isInterpreterCWriteIR "$cmd")"
done <<'T2_TABLE'
FP1679-E: bash -c sq body quoting <<EOF prose^bash -c 'echo "see <<EOF in docs"'^false
FP1679-F: bash -c sq body quoting <<< operator^bash -c 'echo "the <<< operator"'^false
FP1679-G: bash -c body carrying a literal dollar-quote pair^bash -c 'grep -n "x$'"'"'y" file'^false
FP1679-G2: bash -c dq body quoting <<EOF prose^bash -c "echo \"see <<EOF in docs\""^false
FP1679-G3: bash -c dq body quoting <<< operator^bash -c "echo \"the <<< operator\""^false
FC1679-K: bash -c sq body with a LIVE backtick substitution^bash -c 'echo "use `id` backtick"'^true
FC1679-K2: bash -c dq body with a LIVE backtick substitution^bash -c "echo \"use `id` backtick\""^true
FC1679-K3: bash -c dq body with a real rm write^bash -c "rm -f \"my file\""^true
FC1679-L: bash -c sq body with a real rm write^bash -c 'rm -f README.md'^true
FC1679-M: bash -c ANSI-C quoted body (fail-closed pin)^bash -c $'rm foo'^true
T2_TABLE

# ===========================================================================
# (1) isExoticExecWriteIR — looksDynamic over-broad `$`/backtick reject.
# FP rows: statically-known, read-only env-emitting helpers under eval, and
# read commands under xargs / find -exec whose ARGUMENT carries a read cmdsubst.
# FC rows: opaque, mixed, arbitrary-executable, multi-segment, redirect-bearing
# and genuinely dynamic bodies must all stay fail-closed WRITE.
# ===========================================================================
echo "=== (1) isExoticExecWriteIR — FP static reads / FC fail-closed writes ==="
while IFS='^' read -r name cmd want; do
  case "$name" in ''|'#'*) continue ;; esac
  assert_eq "$name" "$want" "$(pred isExoticExecWriteIR "$cmd")"
done <<'T1_TABLE'
FP1679-J: eval "$(ssh-agent -s)"^eval "$(ssh-agent -s)"^false
FP1679-K: eval "$(fnm env --use-on-cd)"^eval "$(fnm env --use-on-cd)"^false
FP1679-K2: eval "$(direnv hook bash)"^eval "$(direnv hook bash)"^false
FP1679-L: xargs grep with a read cmdsubst argument^find . -name '*.js' | xargs grep -n "$(git rev-parse --abbrev-ref HEAD)"^false
FP1679-M: find -exec grep with a read cmdsubst argument^find . -name '*.log' -exec grep -l "$(date +%F)" {} \;^false
FC1679-A: eval "$DYNAMIC" (opaque variable body)^eval "$DYNAMIC"^true
FC1679-B: eval mixed cmdsubst + opaque variable^eval "$(cat /tmp/x)$UNKNOWN"^true
FC1679-C: eval of an interpreter outside any allowlist^eval "$(bash /tmp/x.sh)"^true
FC1679-D: eval of python3^eval "$(python3 gen.py)"^true
FC1679-D2: eval of node -e writing a file^eval "$(node -e 'require("fs").writeFileSync("x","y")')"^true
FC1679-D3: eval of perl -e unlinking a file^eval "$(perl -e 'unlink "x"')"^true
FC1679-D4: eval of ruby -e writing a file^eval "$(ruby -e 'File.write("x","y")')"^true
FC1679-D5: eval of an arbitrary absolute-path executable^eval "$(/opt/tool/gen.sh)"^true
FC1679-D6: eval of cat over an attacker-controllable file^eval "$(cat /tmp/kv)"^true
FC1679-D7: eval of git rev-parse (not an env emitter)^eval "$(git rev-parse --show-toplevel)"^true
FC1679-D8: eval of a MULTI-segment body hiding an rm^eval "$(ssh-agent -s; rm -f f)"^true
FC1679-D9: eval of an allowlisted emitter carrying a redirect^eval "$(fnm env > out)"^true
FC1679-D10: eval of fnm with a non-env subcommand^eval "$(fnm install 22)"^true
FC1679-D11: static write appended after an allowlisted cmdsubst^eval "$(fnm env) && rm -f x"^true
FC1679-E: eval body with a live backtick substitution^eval "$(echo hi `id`)"^true
FC1679-F: eval of an arithmetic expansion (not a cmdsubst)^eval "$((1+2))"^true
FC1679-G: eval of a static body carrying a redirect write^eval "echo x > out"^true
FC1679-N: xargs with an opaque variable command^echo f | xargs $CMD^true
FC1679-O: find -exec with an opaque variable command^find . -exec $CMD {} \;^true
FC1679-P: find -delete^find . -delete^true
T1_TABLE

# ===========================================================================
# (3) isCommandSubstWriteIR — recursion loses the outer Group-A gh context.
# Multi-line shapes are held in heredoc-assigned variables (a `^` table is
# line-oriented and cannot carry an embedded newline).
# ===========================================================================
echo "=== (3) isCommandSubstWriteIR — FP gh body heredocs / FC real inner writes ==="

CMD_FP_D="$(cat <<'XEOF'
gh issue create --title "t" --body "$(cat <<'EOF'
hello
EOF
)"
XEOF
)"

CMD_FC_H="$(cat <<'XEOF'
gh issue create --body "$(bash <<'EOF'
rm -rf /tmp/x
EOF
)"
XEOF
)"

CMD_FC_I="$(cat <<'XEOF'
gh issue create --body "$(cat <<EOF
$(rm -f x)
EOF
)"
XEOF
)"

CMD_FC_J="$(cat <<'XEOF'
cat <<'EOF' > README.md
hi
EOF
XEOF
)"

assert_eq "FP1679-D: gh issue create --body \$(cat <<'EOF' … ) → not a local write" \
  "false" "$(pred isCommandSubstWriteIR "$CMD_FP_D")"
assert_eq "FC1679-H: gh issue create --body \$(bash <<'EOF' rm -rf …) → write" \
  "true" "$(pred isCommandSubstWriteIR "$CMD_FC_H")"
assert_eq "FC1679-I: gh issue create --body unquoted heredoc with nested \$(rm -f x) → write" \
  "true" "$(pred isCommandSubstWriteIR "$CMD_FC_I")"
assert_eq "FC1679-J: cat <<'EOF' > README.md (real heredoc redirect) → classify write" \
  "write" "$(classify_ir "$CMD_FC_J")"

# ===========================================================================
# Group A gh integration — the three module-layer signals a gh coordination
# command must clear together before enforce-worktree can fast-allow it.
# ===========================================================================
echo "=== GA: Group-A gh command integration ==="

CMD_GA_A="$(cat <<'XEOF'
gh issue comment 1679 --body "$(cat <<'EOF'
see the heredoc delimiter syntax
EOF
)"
XEOF
)"

# GA1679-E — same shape, body carrying a LITERAL heredoc-opener-shaped token.
# Since the round-5 quote-aware isInsideSubstitution fix (hooks/lib/strip-quoted-args.js)
# a heredoc nested inside an open `$( )` is no longer stripped: its body must stay
# visible to write-pattern scanning, which is what stops a real opener-piped-to-a-shell
# payload hiding there. The blanket "here-doc" WRITE_PATTERN therefore also matches
# opener-shaped PROSE — an intentionally conservative fail-closed trade-off, not a bug.
CMD_GA_E="$(cat <<'XEOF'
gh issue comment 1679 --body "$(cat <<'EOF'
see the <<EOF syntax
EOF
)"
XEOF
)"

CMD_GA_D="$(cat <<'XEOF'
gh issue comment 1679 --body "$(bash <<'EOF'
rm -rf /tmp/x
EOF
)"
XEOF
)"

CMD_GA_B='gh pr edit 1700 --body "uses <<'"'"'EOF'"'"' in the description"'
CMD_GA_C='gh pr comment 1700 --body "$(git log --oneline -1)"'

assert_eq "GA1679-A classify: gh issue comment heredoc body → read" \
  "read" "$(classify_ir "$CMD_GA_A")"
assert_eq "GA1679-A cmdsubst: gh issue comment heredoc body → false" \
  "false" "$(pred isCommandSubstWriteIR "$CMD_GA_A")"
assert_eq "GA1679-A detect: gh issue comment heredoc body → no write predicate" \
  "null" "$(detect_pred "$CMD_GA_A")"
assert_eq "GA1679-B classify: gh pr edit --body quoting <<'EOF' prose → read" \
  "read" "$(classify_ir "$CMD_GA_B")"
assert_eq "GA1679-B detect: gh pr edit --body quoting <<'EOF' prose → no write predicate" \
  "null" "$(detect_pred "$CMD_GA_B")"
assert_eq "GA1679-C cmdsubst: gh pr comment --body \$(git log) → false (argpos contract)" \
  "false" "$(pred isCommandSubstWriteIR "$CMD_GA_C")"
assert_eq "GA1679-D cmdsubst: gh issue comment --body \$(bash <<'EOF' rm -rf) → true (fail-closed)" \
  "true" "$(pred isCommandSubstWriteIR "$CMD_GA_D")"
assert_eq "GA1679-E classify: opener-shaped prose in an unstripped heredoc body → read" \
  "read" "$(classify_ir "$CMD_GA_E")"
assert_eq "GA1679-E cmdsubst: opener-shaped prose body → false" \
  "false" "$(pred isCommandSubstWriteIR "$CMD_GA_E")"
assert_eq "GA1679-E detect: opener-shaped prose body → isNewlineInjectedWriteIR (fail-closed)" \
  "isNewlineInjectedWriteIR" "$(detect_pred "$CMD_GA_E")"

# ===========================================================================
# Propagation layer — the three consumers of these predicates. A fix applied
# only to the predicate is worthless if a consumer still fails closed on its
# own copy of the signal.
# ===========================================================================
echo "=== PR/SC/SS: propagation to write-detector and bash-write-scope ==="

CMD_FP_A='node "$ACD/bin/supervisor-report" --detail "used <<'"'"'EOF'"'"' heredoc in the script" --reporter x'
CMD_FC_A='eval "$DYNAMIC"'
CMD_FP_K='eval "$(fnm env --use-on-cd)"'
CMD_FC_D5='eval "$(/opt/tool/gen.sh)"'

assert_eq "PR1679-A: detectWritePredicate(FP1679-A) → null (fast-allow)" \
  "null" "$(detect_pred "$CMD_FP_A")"
assert_eq "PR1679-B: detectWritePredicate(FC1679-A) → a write predicate fires" \
  "isExoticExecWriteIR" "$(detect_pred "$CMD_FC_A")"

assert_eq "SC1679-A: isEverySegmentExcluded's isExoticExecWriteIR branch does NOT fire on FP1679-K" \
  "false" "$(seg_exotic "$CMD_FP_K")"
assert_eq "SC1679-B: isEverySegmentExcluded(FC1679-A) → false (write detected, not excluded)" \
  "false" "$(every_seg_excluded "$CMD_FC_A" "$WT")"

assert_eq "SS1679-A: areAllWriteSegmentsOutsideSessionScope(FP1679-K) → true (no write segments)" \
  "true" "$(all_out_of_scope "$CMD_FP_K" "$WT")"
assert_eq "SS1679-B: areAllWriteSegmentsOutsideSessionScope(FC1679-A) → false" \
  "false" "$(all_out_of_scope "$CMD_FC_A" "$WT")"
assert_eq "SS1679-C: areAllWriteSegmentsOutsideSessionScope(FC1679-D5) → false" \
  "false" "$(all_out_of_scope "$CMD_FC_D5" "$WT")"

# ===========================================================================
# HIGH-1 security pin: stripDoubleQuotedContent must skip SQ spans verbatim.
# A `"` inside a single-quoted argument must NOT open a phantom DQ span that
# swallows a subsequent heredoc opener (classify regression #1679 HIGH-1).
# Without the fix `echo 'a"b' ; python <<EOF\n...\nEOF` → classify=read (bypass).
# ===========================================================================
echo "=== HIGH-1 security pin: stripDQ is SQ-aware (phantom DQ bypass) ==="
CMD_HIGH1_A="$(printf "echo 'a\"b' ; python <<EOF\nopen('README.md','w').write('x')\nEOF")"
CMD_HIGH1_B="$(printf "echo 'a\"b' ; node <<EOF\nrequire('fs').writeFileSync('README.md','x')\nEOF")"
assert_eq "HIGH1-A: echo 'a\"b' prefix must not swallow python <<EOF (classify)" \
  "write" "$(classify_ir "$CMD_HIGH1_A")"
assert_eq "HIGH1-B: echo 'a\"b' prefix must not swallow node <<EOF (classify)" \
  "write" "$(classify_ir "$CMD_HIGH1_B")"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
