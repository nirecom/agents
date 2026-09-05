# Tests: hooks/enforce-worktree/shared-cmd-utils.js, hooks/enforce-worktree/universal-target-allow.js, hooks/lib/command-ir.js
# Tags: enforce-worktree, sequencing, fail-closed, parser, table-driven, scope:issue-specific
# M15 — hasCommandSequencing()'s `ir.parseFailure` fail-closed arm, and what that
# arm costs its consumer at universal-target-allow.js Guard 2. The sibling
# predicate in the same source file is covered by cases-hasheredoc-predicate.sh.
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh.

run_M15() {
    # M15 (review round 4) — the `if (ir.parseFailure) return true;` arm of
    # hasCommandSequencing (shared-cmd-utils.js). Every other case in this suite
    # reaches the separators arm below it, so deleting the fail-closed line — or
    # flipping it to `return false` — left the suite green while the one command
    # class whose write targets NO extractor can trust rode the broad
    # outside-session-scope allow. parse() reports parseFailure on an unclosed
    # quote span; the heredoc strip runs FIRST, so an unclosed quote left behind
    # after a stripped heredoc must still reach the arm.
    local label cmd want got
    # Separator is '~': the payloads carry quotes, ';' and '&&'.
    while IFS='~' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(run_with_timeout 30 node -e '
const m=require(process.argv[1]);
if(typeof m.hasCommandSequencing!=="function"){process.stdout.write("MISSING_EXPORT");}
else process.stdout.write(String(m.hasCommandSequencing(process.argv[2])));
' "$SCU" "$(printf '%b' "$cmd")" 2>/dev/null)"
        if [ "$got" = "$want" ]; then pass "M15 $label → $want"
        else fail "M15 $label: want '$want', got '$got'"; fi
    done <<'TABLE'
# label                    ~ command                                            ~ sequencing?
# --- FAIL-CLOSED: parse() reports parseFailure and records ZERO separators ------
unclosed-double-quote      ~ echo "unclosed                                     ~ true
unclosed-single-quote      ~ echo 'unclosed                                     ~ true
unclosed-ansic-quote       ~ echo $'unclosed                                    ~ true
unclosed-with-redirect     ~ echo hi > out.txt "unclosed                        ~ true
unclosed-after-heredoc     ~ cat <<'EOF' > o.txt\nfoo; bar\nEOF\necho "unclosed ~ true
# --- the arm must NOT fire on well-formed input (no over-blocking) --------------
closed-double-quote        ~ echo "closed"                                      ~ false
closed-single-quote        ~ echo 'closed'                                      ~ false
plain-command              ~ echo hi                                            ~ false
heredoc-body-only-operator ~ cat <<'EOF' > o.txt\nfoo; bar\nEOF\n               ~ false
# --- real sequencing still reports true, through the separators arm ------------
real-semicolon             ~ echo a; echo b                                     ~ true
real-and-chain             ~ echo a && echo b                                   ~ true
real-or-chain              ~ echo a || echo b                                   ~ true
TABLE

    # Non-vacuity: prove the unclosed-quote rows really take the parseFailure arm
    # and not the separators arm they share a verdict with. `true/0` is the arm
    # under test; `false/1` is the separators arm the control row takes.
    got="$(run_with_timeout 30 node -e '
const {parse}=require(process.argv[1]);
const {stripHeredocBody}=require(process.argv[2]);
process.stdout.write(process.argv.slice(3).map(function (c) {
  const ir = parse(stripHeredocBody(c));
  return String(ir.parseFailure) + "/" + String(ir.separators.length);
}).join(","));
' "$IRJS" "$AN/hooks/lib/strip-quoted-args.js" 'echo "unclosed' 'echo a; echo b' 'echo hi' 2>/dev/null)"
    if [ "$got" = "true/0,false/1,false/0" ]; then
        pass "M15 precondition: the unclosed-quote row is parseFailure with ZERO separators (the fail-closed arm, not the separators arm)"
    else fail "M15 precondition: want 'true/0,false/1,false/0', got '$got'"; fi

    # What the arm COSTS its consumer: universal-target-allow.js Guard 2 must not
    # hand an unparseable command the Guard 5 broad allow, even when the only
    # target it could extract sits outside session scope. The control differs by
    # ONE character (the closing quote), so the abstain is attributable to the
    # parse failure and to nothing else about the command or its target.
    local UTA="$AN/hooks/enforce-worktree/universal-target-allow.js"
    got="$(run_with_timeout 30 node -e '
const {checkUniversalTargetAllow}=require(process.argv[1]);
const root=process.argv[2];
const roots=new Set([root]);
process.stdout.write(process.argv.slice(3).map(function (c) {
  return checkUniversalTargetAllow("Bash", { command: c }, roots, root).verdict;
}).join(","));
' "$UTA" "$MAIN_N" "echo hi > $TMP_N/m15-fc.txt \"closed\"" "echo hi > $TMP_N/m15-fc.txt \"unclosed" 2>/dev/null)"
    if [ "$got" = "allow,abstain" ]; then
        pass "M15 Guard 2 consumer: the parse failure ABSTAINS where the same command with a closed quote is ALLOWED"
    else fail "M15 Guard 2 consumer: want 'allow,abstain', got '$got'"; fi
}
