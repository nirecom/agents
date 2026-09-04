#!/usr/bin/env bash
# Tests: hooks/lib/display-only-mask.js, hooks/lib/unrecognized-exec-check.js, hooks/preuse-auto-approve/script-body-scan.js
# Tags: script-body-scan, display-only-mask, classifier, table-driven, unit, security, protection-fix, scope:issue-specific, pwsh-not-required
# #2170 ROUND-11: maskDisplayOnlySegments and the two detectors that consume it.
#   M1 = the function itself, pinned on its exact output string (unit table)
#   M2 = the OVER-BLOCKING direction it exists to fix: an interpreter or shell name in
#        an echo/printf ARGUMENT is text, so the line must stay approvable
#   M3 = the DANGEROUS direction it must not open: a command substitution inside an
#        echo/printf argument really executes, so it must still be caught

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - a real shell's own parse of these lines (the mask is a textual pre-pass, not a parser)
# - real PreToolUse dispatch, and the permission prompt a `suspect` verdict produces
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
export AGENTS_DIR
MASK="$(cd "$(dirname "$0")/feature-2170-round11-display-mask" && pwd)/mask-driver.js"
PRED="$(cd "$(dirname "$0")/feature-2170-round3-predicates" && pwd)/pred-driver.js"
SCAN="$(cd "$(dirname "$0")/feature-2170-script-body-scan" && pwd)/scan-driver.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

# Fixture isolation per rules/test/fixture-isolation.md.
TMPROOT_RAW="$(mktemp -d)"
trap 'rm -rf "$TMPROOT_RAW"' EXIT
to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
TMPROOT="$(to_node_path "$TMPROOT_RAW")"
export TMPDIR="$TMPROOT" TEMP="$TMPROOT" TMP="$TMPROOT"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow" WORKFLOW_PLANS_DIR="$TMPROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export MSYS2_ARG_CONV_EXCL='/tmp'

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}
run_table() {
    local prefix="$1" driver="$2" mode="$3" name input want
    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        assert_eq "$prefix-$name" "$want" "$(node "$driver" "$mode" "$(trim "$input")" 2>&1)"
    done
}

# --- M1: the mask function, pinned on its exact output ------------------------
# `~` is the column separator here (not `|`), because a pipe is one of the segment
# separators under test. Expected values are JSON-quoted, so a blanked segment ("")
# and a surviving run of spaces are both visible in the assertion text.
echo "--- M1: maskDisplayOnlySegments output table ---"
run_mask_table() {
    local name input want
    while IFS='~' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="$(trim "$want")"
        assert_eq "M1-$name" "$want" "$(node "$MASK" --mask "$(trim "$input")" 2>&1)"
    done
}
run_mask_table <<'TABLE'
# Provably inert: command word is echo/printf and the segment carries no substitution.
plain-echo            ~ echo hello world              ~ ""
plain-printf          ~ printf 'hi there'             ~ ""
echo-holds-shell-flag ~ echo sh -c harmless           ~ ""
echo-holds-script-path~ echo bash /abs/danger.sh      ~ ""
printf-holds-altshell ~ printf 'run zsh /tmp/x.sh'    ~ ""
leading-whitespace    ~   echo hi                     ~ ""
exe-suffix            ~ echo.exe hi                   ~ ""
uppercase-name        ~ ECHO hi                       ~ ""
# NOT display-only: the command word is something else, or echo is an argument.
other-command         ~ ls -la                        ~ "ls -la"
echo-as-argument      ~ foo echo bar                  ~ "foo echo bar"
longer-word           ~ echoes hi                     ~ "echoes hi"
# `(?=\s)` is required, so a bare `echo` with no operand is not a display-only segment.
bare-echo-no-operand  ~ echo                          ~ "echo"
# Segment-wise, not line-wise: only the echo/printf halves are blanked, and every
# separator survives so the surviving halves stay at the command position their own
# anchors expect.
echo-then-command     ~ echo hi; ls -la               ~ "; ls -la"
command-then-echo     ~ ls -la; echo hi               ~ "ls -la;"
both-halves-display   ~ echo a; echo b                ~ ";"
and-separator         ~ echo one && node /tmp/e.js    ~ "&& node /tmp/e.js"
pipe-separator        ~ echo a | grep b               ~ "| grep b"
# A backtick is NOT a segment separator, so the whole line is one segment — and
# SUBSTITUTION_RE sees the backtick and refuses to blank it.
backtick-substitution ~ echo `date`                   ~ "echo `date`"
TABLE
# `$(` splits on its own `(`, so the echo half is blanked while the substitution BODY
# survives — and it survives immediately after `(`, which is a command position for
# every consumer's CMD_POS anchor. That is the property M3 depends on.
assert_eq "M1-dollar-substitution-body-survives" '"(date)"' "$(node "$MASK" --mask 'echo $(date)' 2>&1)"

# Edge inputs: the mask feeds guards that must never throw on arbitrary body text.
assert_eq "M1-empty-string" '""' "$(node "$MASK" --mask '' 2>&1)"
for kind in null undefined number array object; do
    assert_eq "M1-nonstring-$kind" '""' "$(node "$MASK" --nonstring "$kind" 2>&1)"
done

# --- M2: over-blocking direction — a name in echo/printf data position ---------
# Without the mask every self-documenting script loses its auto-approval. Each row is a
# real interpreter/shell spelling that a script legitimately PRINTS.
echo ""
echo "--- M2: interpreter names inside echo/printf stay approvable ---"
run_table "M2" "$PRED" --exec <<'TABLE'
echo-sh-dash-c        | echo sh -c harmless                  | miss
echo-bash-script      | echo bash /abs/danger.sh             | miss
printf-zsh-script     | printf 'run zsh /tmp/x.sh'           | miss
echo-node-script      | echo node /tmp/evil.js               | miss
echo-pwsh-script      | echo pwsh /tmp/a.ps1                 | miss
printf-eval           | printf 'eval "$CMD"'                 | miss
echo-exe-path         | echo C:/tools/evil.exe --run         | miss
TABLE
run_table "M2line" "$SCAN" --line <<'TABLE'
echo-sh-dash-c        | echo sh -c harmless                  | safe
echo-bash-script      | echo bash /abs/danger.sh             | safe
printf-zsh-script     | printf 'run zsh /tmp/x.sh'           | safe
TABLE

# --- M3: dangerous direction — a substitution inside echo/printf still runs -----
# The mask is CONSERVATIVE by design: a segment carrying `$(`/backtick is never
# blanked, and the `$(` split leaves the substitution body at a command position. A
# regression that blanked these would let `echo "$(...)"` smuggle any command past the
# scan while reading as harmless display text.
echo ""
echo "--- M3: command substitution inside echo/printf is NOT masked away ---"
run_table "M3" "$PRED" --exec <<'TABLE'
dq-substitution-node  | echo "$(node /tmp/evil.js)"          | hit
printf-substitution   | printf '%s' "$(python3 /tmp/e.py)"   | hit
unquoted-substitution | echo $(npx evil-pkg)                 | hit
TABLE
# The backtick spelling reaches the same verdict one layer out: `commandInvokesUnrecognizedExec`
# anchors on CMD_POS and a backtick is not one of its separators, so it is `lineIsSuspect`
# — the predicate the auto-approve actually calls — that must answer suspect here.
assert_eq "M3-backtick-substitution-line" "suspect" \
    "$(node "$SCAN" --line 'echo `node /tmp/evil.js`' 2>&1)"

# Body layer, where the nested-script enumerator is the consumer: a `bash <child>` hidden
# in a substitution must still be followed, while the same text as a plain echo operand
# must not be. The two rows share one child, so the difference is the masking alone.
MB="$TMPROOT_RAW/mask-bodies"
mkdir -p "$MB"
M="$TMPROOT/mask-bodies"
printf 'winget install evil\n' >"$MB/danger.sh"
printf 'echo "$(bash %s/danger.sh)"\n' "$M" >"$MB/p-substitution.sh"
printf 'echo `bash %s/danger.sh`\n'    "$M" >"$MB/p-backtick.sh"
printf 'echo bash %s/danger.sh\n'      "$M" >"$MB/p-display-only.sh"
printf 'printf "run bash %s/danger.sh"\n' "$M" >"$MB/p-printf-display-only.sh"
printf 'bash %s/danger.sh\n'           "$M" >"$MB/p-real-invocation.sh"
run_table "M3body" "$SCAN" --body <<TABLE
substitution-followed   | $M/p-substitution.sh          | suspect
backtick-followed       | $M/p-backtick.sh              | suspect
# Same child, same spelling of its path — but as display text the scan must not open it.
display-only-not-opened | $M/p-display-only.sh          | safe
printf-display-only     | $M/p-printf-display-only.sh   | safe
# Control: the child IS dangerous, and a real invocation of it is still caught, so the
# two safe rows above are the masking and not a child that stopped being suspect.
real-invocation-caught  | $M/p-real-invocation.sh       | suspect
TABLE

echo ""
echo "==================================================="
echo "feature-2170-round11-display-mask: PASS=$PASS FAIL=$FAIL"
echo "==================================================="
exit "$FAIL"
