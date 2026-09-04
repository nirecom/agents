#!/usr/bin/env bash
# Tests: hooks/lib/unrecognized-exec-check.js, hooks/preuse-auto-approve/script-body-scan.js
# Tags: script-body-scan, classifier, table-driven, regression, security, protection-fix, scope:issue-specific, pwsh-not-required
# #2170 ROUND-7 regression pins: evasion shapes round 6 missed, plus the over-blocking
# twin. Round 7 closed all three in source; every row now asserts the CORRECT verdict,
# so a regression flips it loudly.
#   H1 = interpreter NAME in unquoted DATA position -> correctly NOT a hit
#   H2 = quoted Windows executable path / `command eval` wrapper -> correctly caught
#   H3 = nested `bash <target>` outside the old NESTED_SCRIPT_RE shape -> correctly followed

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - real PreToolUse dispatch of these command strings through a live Claude Code session
# - whether the permission prompt actually appears when a passthrough is returned
# - Windows-native execution of the quoted pwsh/exe paths pinned in H2
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
export AGENTS_DIR
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
# Standard table-driven runner (skills/_shared/test-design/parser-regex-tests.md).
run_table() {
    local prefix="$1" driver="$2" mode="$3" name input want
    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        assert_eq "$prefix-$name" "$want" "$(node "$driver" "$mode" "$(trim "$input")" 2>&1)"
    done
}

# --- H1: an interpreter name in unquoted DATA position ------------------------
# Over-blocking direction, now correctly handled. INTERPRETER_RE is anchored on CMD_POS
# the same way PWSH_RE/BARE_EXE_RE/EVAL_RE are, so `node` inside `echo node foo` reads as
# data, not as a command word — matching the quoted twin.
# TL3 gap: none — a pure predicate, fully observable at this layer.
echo "--- H1: interpreter name in unquoted data position (correctly miss) ---"
run_table "H1" "$PRED" --exec <<TABLE
echo-node              | echo node foo          | miss
printf-python3         | printf python3         | miss
echo-npx               | echo npx is a runner   | miss
# Both-direction control: the QUOTED spelling of the same data answers identically,
# so the anchor treats both spellings of data alike.
quoted-echo-node       | echo 'node foo'        | miss
quoted-printf-python3  | printf 'python3 x.py'  | miss
TABLE
# The same rows at the body layer, where over-blocking would have cost an ordinary
# self-documenting script its auto-approval.
assert_eq "H1-body-line-echo-node" "safe" "$(node "$SCAN" --line 'echo node foo' 2>&1)"
assert_eq "H1-body-line-echo-node-quoted" "safe" "$(node "$SCAN" --line "echo 'node foo'" 2>&1)"

# --- H2: quoted executable paths and the `command` wrapper --------------------
# DANGEROUS direction, now correctly caught. Quoting a Windows path both makes it
# runnable (spaces) and used to hide it, because PWSH_RE/BARE_EXE_RE built their
# directory prefix from `[^\s;|&'"]*` and a leading `"` stopped the match. `command eval`
# hid `eval` the same way, by occupying the CMD_POS EVAL_RE anchors on. Both spellings
# are now peeled before matching, so the quoted path and the wrapper are hits.
# TL3 gap: only a real Windows session shows the quoted pwsh process actually starting.
echo ""
echo "--- H2: quoted exe paths / command-eval wrapper (correctly hit) ---"
run_table "H2" "$PRED" --exec <<TABLE
quoted-pwsh-path          | "C:/Program Files/PowerShell/7/pwsh.exe" -File evil.ps1 | hit
quoted-exe-path           | "C:/tools/evil.exe" --run                               | hit
command-eval              | command eval echo hi                                    | hit
# PWSH_RE/BARE_EXE_RE carry a SINGLE-quote alternative alongside the double-quote one
# (SQ_DIR / '[^']*\.exe'). A leading ' also defeats DIRECT_EXEC_RE, so these rows can
# only pass through the single-quoted arm — dropping it would silently un-guard the
# spelling a POSIX author reaches for first (CPR-ORTH twin of the quoted rows above).
sq-pwsh-path              | 'C:/Program Files/PowerShell/7/pwsh.exe' -File evil.ps1 | hit
sq-exe-path               | 'C:/tools/evil.exe' --run                               | hit
sq-bare-pwsh-name         | 'pwsh' -Command Get-Process                             | hit
# Both-direction control: unquoted and space-free, the same invocations are caught too —
# so the two spellings of a genuine execution channel now answer alike. (A space-bearing
# path is unreachable unquoted, which is exactly why the quoted form matters.)
bare-pwsh-path            | C:/tools/PowerShell/pwsh.exe -File evil.ps1             | hit
bare-exe-path             | C:/tools/evil.exe --run                                 | hit
bare-eval                 | eval echo hi                                            | hit
TABLE
# Body layer: the same shapes reach lineIsSuspect, which is what auto-approves.
run_table "H2body" "$SCAN" --line <<TABLE
quoted-pwsh-path        | "C:/Program Files/PowerShell/7/pwsh.exe" -File evil.ps1 | suspect
quoted-exe-path         | "C:/tools/evil.exe" --run                               | suspect
command-eval            | command eval echo hi                                    | suspect
bare-exe-path           | C:/tools/evil.exe --run                                 | suspect
bare-eval               | eval echo hi                                            | suspect
sq-pwsh-path            | 'C:/Program Files/PowerShell/7/pwsh.exe' -File evil.ps1 | suspect
sq-exe-path             | 'C:/tools/evil.exe' --run                               | suspect
TABLE

# --- H3: nested targets the enumerator never follows --------------------------
# DANGEROUS direction, now correctly followed. NESTED_SCRIPT_RE used to demand a literal
# `.sh` suffix and a flag alphabet with no operands, so `bash /tmp/evil` (a script needs
# no extension) and `bash -O extglob /tmp/danger.sh` (an option that TAKES an operand)
# both yielded ZERO nested targets. The extension requirement is gone and operand-taking
# options are modelled, so the child is opened and its danger reaches the parent verdict.
# TL3 gap: only a live run would show the child script actually executing.
echo ""
echo "--- H3: nested bash targets outside NESTED_SCRIPT_RE's shape ---"
NEST="$TMPROOT_RAW/nest7"
mkdir -p "$NEST"
N="$TMPROOT/nest7"
printf 'winget install evil\n' >"$NEST/danger.sh"
printf 'winget install evil\n' >"$NEST/evil"
printf 'echo fine\n'           >"$NEST/benign.sh"
printf 'echo fine\n'           >"$NEST/benign"
printf 'bash %s/danger.sh\n'              "$N" >"$NEST/p-plain-danger.sh"
printf 'bash %s/evil\n'                   "$N" >"$NEST/p-noext-danger.sh"
printf 'bash -O extglob %s/danger.sh\n'   "$N" >"$NEST/p-operand-danger.sh"
printf 'bash -O extglob %s/benign.sh\n'   "$N" >"$NEST/p-operand-benign.sh"
printf 'bash %s/benign.sh\n'              "$N" >"$NEST/p-plain-benign.sh"
printf 'bash %s/benign\n'                 "$N" >"$NEST/p-noext-benign.sh"

run_table "H3" "$SCAN" --body <<TABLE
# Positive control: the ordinary spelling of the SAME dangerous child IS followed,
# isolating the enumerator's shape rather than the child's content.
control-plain-danger   | $N/p-plain-danger.sh   | suspect
noext-danger           | $N/p-noext-danger.sh   | suspect
operand-danger         | $N/p-operand-danger.sh | suspect
# Benign counterparts stay approvable for the ordinary reason, pinning the other
# direction so a regression that over-blocks every flagged invocation also shows up here.
benign-plain           | $N/p-plain-benign.sh   | safe
benign-operand         | $N/p-operand-benign.sh | safe
# The extensionless twin of noext-danger: dropping NESTED_SCRIPT_RE's \`.sh\` requirement
# must not turn every extensionless operand into a verdict of its own — the child is
# opened, found innocuous, and the parent stays approvable.
benign-noext           | $N/p-noext-benign.sh   | safe
TABLE

echo ""
echo "==================================================="
echo "feature-2170-round7-evasion-gaps: PASS=$PASS FAIL=$FAIL"
echo "==================================================="
exit "$FAIL"
