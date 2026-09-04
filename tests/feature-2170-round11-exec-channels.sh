#!/usr/bin/env bash
# Tests: hooks/lib/unrecognized-exec-check.js, hooks/preuse-auto-approve/script-body-scan.js
# Tags: script-body-scan, classifier, table-driven, security, protection-fix, alt-shell, nested-scripts, scope:issue-specific, pwsh-not-required
# #2170 ROUND-11: two execution channels the body scan used to miss, one section each.
#   K1 = a script handed to zsh / dash / ksh. script-body-scan follows `bash`/`sh` into
#        the child; nothing follows the other shells, so the child body is never read.
#   K2 = `bash <target>` spellings NESTED_SCRIPT_RE's operand shape never enumerated:
#        an extensionless BARE relative name, an extensionless ABSOLUTE path, and the
#        child arriving on STDIN through a redirect.

set -uo pipefail

# Both directions are pinned in each section: an over-blocking regression costs every
# self-documenting scratchpad script its auto-approval, which is a failure too.
#
# TL3 gap (what this test does NOT catch):
# - real PreToolUse dispatch of these command strings through a live Claude Code session
# - whether a real zsh/dash/ksh is present on the host (the predicate classifies TEXT)
# - the permission prompt a `suspect` verdict is supposed to produce
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
# MSYS/Git-Bash rewrites an argv element that STARTS with `/` into a Windows path
# before node sees it, which would silence every POSIX-spelled row below. Only the
# `/tmp` prefix is excluded, so the driver path and AGENTS_DIR still convert — which
# is why the directory-qualified shell rows are spelled `/tmp/bin/zsh` rather than
# `/bin/zsh` (same shape, same regex arm, and portable on this host).
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

# --- K1: zsh / dash / ksh are unrecognized execution channels -----------------
# DANGEROUS direction. ALT_SHELL_RE carries the same three quoting arms as PWSH_RE, so
# a bare name, a directory-qualified path and both quoted spellings are one channel.
echo "--- K1: alternate shells at command position (correctly hit) ---"
run_table "K1" "$PRED" --exec <<'TABLE'
zsh-script            | zsh /tmp/evil.sh                     | hit
dash-script           | dash /tmp/evil.sh                    | hit
ksh-script            | ksh /tmp/evil.sh                     | hit
zsh-dir-qualified     | /tmp/bin/zsh /tmp/evil.sh            | hit
dash-dir-qualified    | /tmp/usr/bin/dash /tmp/evil.sh       | hit
ksh-windows-dir       | C:/tools/ksh.exe /tmp/evil.sh        | hit
zsh-exe-suffix        | zsh.exe /tmp/evil.sh                 | hit
zsh-dq-spaced-path    | "C:/Program Files/zsh/zsh.exe" -x    | hit
zsh-sq-bare-name      | 'zsh' /tmp/evil.sh                   | hit
dash-sq-spaced-path   | 'C:/Program Files/dash/dash.exe' x   | hit
zsh-after-and         | ls && zsh /tmp/evil.sh               | hit
ksh-after-semicolon   | pwd; ksh /tmp/evil.sh                | hit
zsh-bare-no-operand   | zsh                                  | hit
TABLE
# The `|` column separator cannot carry a pipe, so the piped spelling gets its own row.
assert_eq "K1-zsh-after-pipe" "hit" "$(node "$PRED" --exec 'cat f | zsh' 2>&1)"

# Both-direction negatives (protection-fix-tests.md Pattern 4). ALT_SHELL_RE anchors on
# CMD_POS and ends on `(?=\s|$)`, so a shell NAME that is a longer word, an argument, or
# a file extension must stay approvable — over-blocking here makes the scratchpad
# auto-approve useless.
echo "--- K1-neg: alternate-shell names outside command position (correctly miss) ---"
run_table "K1neg" "$PRED" --exec <<'TABLE'
zsh-word-prefix       | zshfoo bar                           | miss
dash-word-prefix      | dashboard build                      | miss
ksh-word-prefix       | kshell start                         | miss
zsh-as-argument       | ls /tmp/zsh                          | miss
ksh-as-extension      | ls report.ksh                        | miss
dash-inside-longer    | which mydash                         | miss
TABLE

# Body layer: the same channel seen by the scan that actually auto-approves.
echo "--- K1-body: alternate shells inside a script body ---"
run_table "K1body" "$SCAN" --line <<'TABLE'
zsh-script            | zsh /tmp/evil.sh                     | suspect
dash-script           | dash /tmp/evil.sh                    | suspect
ksh-script            | ksh /tmp/evil.sh                     | suspect
zsh-dq-spaced-path    | "C:/Program Files/zsh/zsh.exe" -x    | suspect
zsh-word-prefix       | zshfoo bar                           | safe
zsh-as-argument       | ls /tmp/zsh                          | safe
TABLE
ALT="$TMPROOT_RAW/alt"
mkdir -p "$ALT"
A="$TMPROOT/alt"
printf 'echo fine\n' >"$ALT/child.sh"
printf 'echo start\nzsh %s/child.sh\n' "$A" >"$ALT/b-zsh.sh"
printf 'echo start\ndash %s/child.sh\n' "$A" >"$ALT/b-dash.sh"
printf 'echo start\nksh %s/child.sh\n' "$A" >"$ALT/b-ksh.sh"
# CPR-ORTH control: the SAME child under `bash` is followed, read, and cleared — so the
# three verdicts above are the INTERPRETER and not the child's content.
printf 'echo start\nbash %s/child.sh\n' "$A" >"$ALT/b-bash-control.sh"
run_table "K1bodyfile" "$SCAN" --body <<TABLE
zsh-child     | $A/b-zsh.sh          | suspect
dash-child    | $A/b-dash.sh         | suspect
ksh-child     | $A/b-ksh.sh          | suspect
bash-control  | $A/b-bash-control.sh | safe
TABLE

# --- K2: nested `bash <target>` spellings the enumerator used to skip ---------
# DANGEROUS direction. NESTED_BARE_RE widens the operand to ANY word at COMMAND
# position (so `bash evil` is enumerated), and NESTED_STDIN_RE reads the redirect's
# operand (so `bash < script` is enumerated). Neither target is followable when it is
# relative — an unresolvable target yields "" and the parent answers suspect.
echo ""
echo "--- K2: nested bash targets outside the old operand shape ---"
NEST="$TMPROOT_RAW/nest11"
mkdir -p "$NEST"
N="$TMPROOT/nest11"
printf 'winget install evil\n' >"$NEST/danger.sh"
printf 'winget install evil\n' >"$NEST/danger"
printf 'echo fine\n'           >"$NEST/benign.sh"
printf 'echo fine\n'           >"$NEST/benign"
printf 'bash evil\n'                     >"$NEST/p-bare-relative.sh"
printf 'bash %s/danger\n'          "$N"  >"$NEST/p-noext-absolute.sh"
printf 'bash %s/benign\n'          "$N"  >"$NEST/p-noext-absolute-benign.sh"
printf 'bash < %s/danger.sh\n'     "$N"  >"$NEST/p-stdin-spaced.sh"
printf 'bash<%s/danger.sh\n'       "$N"  >"$NEST/p-stdin-tight.sh"
printf 'bash < %s/benign.sh\n'     "$N"  >"$NEST/p-stdin-benign.sh"
printf 'bash < ./relative.sh\n'          >"$NEST/p-stdin-relative.sh"

run_table "K2" "$SCAN" --body <<TABLE
# Bare extensionless relative name: not absolute, so it can never be resolved and read.
bare-relative        | $N/p-bare-relative.sh          | suspect
# Extensionless ABSOLUTE target: resolvable, opened, and its winget line is what damns it.
noext-absolute       | $N/p-noext-absolute.sh         | suspect
# Stdin redirect, with and without the space — the child is the REDIRECT's operand, so
# no command-position arm ever sees it.
stdin-spaced         | $N/p-stdin-spaced.sh           | suspect
stdin-tight          | $N/p-stdin-tight.sh            | suspect
# A relative stdin operand is unresolvable for the same reason as bare-relative.
stdin-relative       | $N/p-stdin-relative.sh         | suspect
# Both-direction controls: widening the operand must not answer every nested invocation
# suspect. The child is opened, found innocuous, and the parent stays auto-approvable —
# which also proves the rows above reached their verdict by READING the child.
noext-absolute-benign| $N/p-noext-absolute-benign.sh  | safe
stdin-benign         | $N/p-stdin-benign.sh           | safe
TABLE

echo ""
echo "==================================================="
echo "feature-2170-round11-exec-channels: PASS=$PASS FAIL=$FAIL"
echo "==================================================="
exit "$FAIL"
