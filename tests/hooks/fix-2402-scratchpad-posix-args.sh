#!/usr/bin/env bash
# Tests: hooks/preuse-auto-approve/scratchpad-script.js, hooks/lib/claude-scratchpad-base.js
# Tags: scratchpad-allow, pre-tool-use, fix-2402, TL2, scope:issue-specific
# #2402 N1: POSIX drive-letter paths (/c/...) in SCRATCHPAD and in the bash operand
#   must be normalized before path.resolve/realpathSync (Git Bash / MSYS2 hosts).
# #2402 N2: `bash <scratchpad>.sh <literal args>` is auto-approved; any arg the shell
#   would rewrite ($, backtick, glob, leading ~) is not; argvRaw is fail-closed.
# Fixture isolation per rules/test/fixture-isolation.md: TMPDIR/TEMP/TMP pinned to an
# isolated root, so os.tmpdir()-derived claude base never touches the real one.

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - whether Claude Code's real PreToolUse wiring delivers a /c/... operand to the hook
#   and honours the resulting allow (tests/hooks/TL3-hook-scratchpad-auto-approve.sh T3)
# - whether a real `bash <script> <arg>` turn is auto-approved end to end (TL3 T2)
# - the SCRATCHPAD form the live harness exports: Git Bash rewrites /c/... env values
#   to C:/... when spawning node, so this file forces MSYS_NO_PATHCONV=1 to reach the
#   unconverted form; which form a real hook process sees is only observable at TL3.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

# shellcheck source=../lib/harness.sh
. "$(dirname "$0")/../lib/harness.sh"
command -v node >/dev/null 2>&1 || exit 77

T_SCRIPT="hooks/preuse-auto-approve/scratchpad-script.js"
T_BASE="hooks/lib/claude-scratchpad-base.js"

check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

TMPROOT_RAW="$(make_tmp)"
trap 'rm -rf "$TMPROOT_RAW"' EXIT
TMPROOT="$(np "$TMPROOT_RAW")"
AGENTS_NODE="$(np "$AGENTS_DIR")"
DRIVER="$AGENTS_NODE/tests/hooks/feature-2170-capture-echo-guard/scratchpad-driver.js"

export TMPDIR="$TMPROOT" TEMP="$TMPROOT" TMP="$TMPROOT"
harness_isolate "$TMPROOT_RAW/iso"

BASE="$TMPROOT/claude"
SLUG="c--fixture-project"
SESS="2402aaaa-bbbb-cccc-dddd-eeeeffff0001"
OTHER="2402aaaa-bbbb-cccc-dddd-eeeeffff0002"
SP="$BASE/$SLUG/$SESS/scratchpad"
mkdir -p "$SP" "$BASE/$SLUG/$OTHER/scratchpad"
printf 'echo hi\n' >"$SP/probe.sh"

# MSYS_NO_PATHCONV=1 on every node spawn: without it Git Bash silently rewrites a
# /c/... env value or argument to C:/..., and every POSIX-form case would pass vacuously.
drv() {
    local sp="$1"; shift
    run_with_timeout 30 env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
        MSYS_NO_PATHCONV=1 AGENTS_DIR="$AGENTS_NODE" SCRATCHPAD="$sp" \
        node "$DRIVER" "$@" 2>&1
}

# /c/... drive-letter form. Not `cygpath -u`: that yields the /tmp mount alias for a
# path under %TEMP%, which is not the drive-letter shape #2402 is about.
to_drive_posix() {
    local m d
    m="$(np "$1")"
    case "$m" in
        [A-Za-z]:/*) d="${m%%:*}"; printf '/%s%s' "${d,,}" "${m#?:}" ;;
        *) printf '%s' "$m" ;;
    esac
}

msys_host() {
    command -v cygpath >/dev/null 2>&1 && cygpath -u "C:/" 2>/dev/null | grep -q '^/c/'
}

# --- Group A: POSIX drive-letter normalization (N1) --------------------------
if msys_host; then
    SP_POSIX="$(to_drive_posix "$SP")"

    case_begin "A0-fixture-node-sees-posix-form" "$T_BASE"
    got="$(run_with_timeout 30 env MSYS_NO_PATHCONV=1 SCRATCHPAD="$SP_POSIX" node -e 'process.stdout.write(process.env.SCRATCHPAD)')"
    check "A0-fixture-node-sees-posix-form" "$SP_POSIX" "$got"
    case_end

    case_begin "A1-allow-posix-scratchpad-and-operand" "$T_SCRIPT"
    check "A1-allow-posix-scratchpad-and-operand" "allow" "$(drv "$SP_POSIX" --invoke "bash $SP_POSIX/probe.sh")"
    case_end

    # A1b/A1c separate the two call sites: operand-only vs SCRATCHPAD-only POSIX form.
    case_begin "A1b-allow-posix-operand-only" "$T_SCRIPT"
    check "A1b-allow-posix-operand-only" "allow" "$(drv "$SP" --invoke "bash $SP_POSIX/probe.sh")"
    case_end

    case_begin "A1c-allow-posix-scratchpad-only" "$T_BASE"
    check "A1c-allow-posix-scratchpad-only" "allow" "$(drv "$SP_POSIX" --invoke "bash $SP/probe.sh")"
    case_end

    case_begin "A2-root-kind-path-from-posix-scratchpad" "$T_BASE"
    want_root="$(drv "$SP" --root)"
    case "$want_root" in
        path:*) pass "A2-precondition-mixed-form-root-is-path" ;;
        *) fail "A2-precondition-mixed-form-root-is-path" "got=$want_root" ;;
    esac
    check "A2-root-kind-path-from-posix-scratchpad" "$want_root" "$(drv "$SP_POSIX" --root)"
    case_end

    case_begin "A3-legacy-target-rejects-other-session" "$T_BASE"
    check "A3-legacy-target-rejects-other-session" "false" \
        "$(drv "$SP_POSIX" --legacy-target "$BASE/$SLUG/$OTHER/scratchpad/f.txt")"
    check "A3b-legacy-target-accepts-own-session" "true" \
        "$(drv "$SP_POSIX" --legacy-target "$SP/f.txt")"
    case_end
else
    skip "Group A (POSIX path): MSYS-form cygpath not available"
fi

# --- Group B: literal args are allowed (N2) ----------------------------------
case_begin "B1-allow-no-args" "$T_SCRIPT"
check "B1-allow-no-args" "allow" "$(drv "$SP" --invoke "bash $SP/probe.sh")"
case_end

case_begin "B2-allow-one-literal-arg" "$T_SCRIPT"
check "B2-allow-one-literal-arg" "allow" "$(drv "$SP" --invoke "bash $SP/probe.sh some_literal_arg")"
case_end

case_begin "B3-allow-two-literal-args" "$T_SCRIPT"
check "B3-allow-two-literal-args" "allow" "$(drv "$SP" --invoke "bash $SP/probe.sh first_arg second_arg")"
case_end

# --- Group C: args the shell would rewrite are denied (N2 boundary) ----------
case_begin "C1-deny-dollar-arg" "$T_SCRIPT"
check "C1-deny-dollar-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh '\$VAR'")"
case_end

case_begin "C2-deny-backtick-arg" "$T_SCRIPT"
check "C2-deny-backtick-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh \`cmd\`")"
case_end

case_begin "C3-deny-glob-arg" "$T_SCRIPT"
check "C3-deny-glob-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh *.txt")"
case_end

case_begin "C4-deny-tilde-arg" "$T_SCRIPT"
check "C4-deny-tilde-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh ~/foo")"
case_end

# bash expands `~` only at token start; a mid-token `~` (8.3 short names like RUNNER~1)
# is literal and must not be refused.
case_begin "C5-allow-mid-token-tilde-arg" "$T_SCRIPT"
check "C5-allow-mid-token-tilde-arg" "allow" "$(drv "$SP" --invoke "bash $SP/probe.sh arg~middle")"
check "C5b-allow-quoted-mid-token-tilde-arg" "allow" "$(drv "$SP" --invoke "bash $SP/probe.sh \"some~arg\"")"
case_end

case_begin "C6-deny-question-glob-arg" "$T_SCRIPT"
check "C6-deny-question-glob-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh 'file?.sh'")"
case_end

case_begin "C7-deny-bracket-arg" "$T_SCRIPT"
check "C7-deny-bracket-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh '[abc]'")"
case_end

# C7b: closing bracket alone (no opening bracket) — tests ] independently from [
case_begin "C7b-deny-close-bracket-only-arg" "$T_SCRIPT"
check "C7b-deny-close-bracket-only-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh 'abc]def'")"
case_end

case_begin "C8-deny-brace-arg" "$T_SCRIPT"
check "C8-deny-brace-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh '{a,b}'")"
case_end

# C8b: closing brace alone (no opening brace) — tests } independently from {
case_begin "C8b-deny-close-brace-only-arg" "$T_SCRIPT"
check "C8b-deny-close-brace-only-arg" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh 'abc}def'")"
case_end

# A newline anywhere in the command text is a shell command separator — the
# parser treats it as whitespace and would parse whoami as a safe extra argument,
# but bash would execute it as a second command.
_NL=$'\n'
case_begin "C9-deny-newline-in-cmdtext" "$T_SCRIPT"
check "C9-deny-newline-in-cmdtext" "deny" "$(drv "$SP" --invoke "bash $SP/probe.sh safe_arg${_NL}whoami")"
case_end

# --- Group E: argvRaw is fail-closed (stubbed IR, M14 require.cache pattern) --
# The stub isolates the argvRaw guard: containment, repo exclusion and realpath are
# forced to pass, so E0 (well-formed argvRaw) must allow and E1..E3 must deny.
E_JS='
const path = require("path");
const fs = require("fs");
const [agentsDir, mode] = process.argv.slice(1);
const fixturePath = path.join(agentsDir, "tests/hooks/TL3-hook-scratchpad-auto-approve.sh");
const seg = { cmd0: "bash", cmd0Raw: "bash", argv: [fixturePath], redirects: [], rawText: "bash " + fixturePath };
if (mode === "valid") seg.argvRaw = [fixturePath];
if (mode === "empty") seg.argvRaw = [];
if (mode === "nonstring") seg.argvRaw = [42];
if (mode === "argv2-length-mismatch") { seg.argv = [fixturePath, "arg1"]; seg.argvRaw = [fixturePath]; }
if (mode === "argv2-nonstring") { seg.argv = [fixturePath, "arg1"]; seg.argvRaw = [fixturePath, 42]; }
if (mode === "argv2-unsafe-dollar") { seg.argv = [fixturePath, "$VAR"]; seg.argvRaw = [fixturePath, "$VAR"]; }
if (mode === "argv2-unsafe-backtick") { seg.argv = [fixturePath, "`cmd`"]; seg.argvRaw = [fixturePath, "`cmd`"]; }
if (mode === "argv2-unsafe-glob") { seg.argv = [fixturePath, "*.txt"]; seg.argvRaw = [fixturePath, "*.txt"]; }
if (mode === "argv2-unsafe-bracket") { seg.argv = [fixturePath, "[a-z]"]; seg.argvRaw = [fixturePath, "[a-z]"]; }
const stub = (rel, overrides) => {
  const f = require.resolve(path.join(agentsDir, rel));
  const real = require(f);
  require.cache[f] = { id: f, filename: f, loaded: true, exports: Object.assign({}, real, overrides) };
};
stub("hooks/block-clearance-token-write/bash-scan/scan.js", {
  parseWithSubstitutionSpans: () => ({ parseFailure: false, segments: [seg], separators: [] }),
});
stub("hooks/lib/claude-scratchpad-base.js", {
  getCurrentSessionScratchpadRootNorm: () => ({ kind: "path", root: path.dirname(fixturePath) }),
  isRepoExcluded: () => false,
});
fs.realpathSync = (p) => p;
const { isAllowedScratchpadInvocation } = require(path.join(agentsDir, "hooks/preuse-auto-approve/scratchpad-script.js"));
process.stdout.write(isAllowedScratchpadInvocation("bash " + fixturePath) ? "allow" : "deny");
'
e_run() { run_with_timeout 30 env MSYS_NO_PATHCONV=1 node -e "$E_JS" "$AGENTS_NODE" "$1" 2>&1; }

case_begin "E0-control-valid-argvraw-allows" "$T_SCRIPT"
check "E0-control-valid-argvraw-allows" "allow" "$(e_run valid)"
case_end

case_begin "E1-deny-argvraw-length-mismatch" "$T_SCRIPT"
check "E1-deny-argvraw-length-mismatch" "deny" "$(e_run empty)"
case_end

case_begin "E2-deny-argvraw-non-string" "$T_SCRIPT"
check "E2-deny-argvraw-non-string" "deny" "$(e_run nonstring)"
case_end

case_begin "E3-deny-argvraw-undefined" "$T_SCRIPT"
check "E3-deny-argvraw-undefined" "deny" "$(e_run undefined)"
case_end

# E4/E5: multi-element argv; argvRaw must match in both length and element types.
case_begin "E4-deny-argvraw-length-mismatch-multi-argv" "$T_SCRIPT"
check "E4-deny-argvraw-length-mismatch-multi-argv" "deny" "$(e_run argv2-length-mismatch)"
case_end

case_begin "E5-deny-argvraw-nonstring-multi-argv" "$T_SCRIPT"
check "E5-deny-argvraw-nonstring-multi-argv" "deny" "$(e_run argv2-nonstring)"
case_end

# E6-E9: well-formed argvRaw but arg[1] contains an UNRESOLVABLE_CHARS member.
# These stub out argvRaw fail-closed and containment so the denial is solely from
# the UNRESOLVABLE_CHARS loop — mutation of any member is caught independently.
case_begin "E6-deny-argvraw-unsafe-dollar" "$T_SCRIPT"
check "E6-deny-argvraw-unsafe-dollar" "deny" "$(e_run argv2-unsafe-dollar)"
case_end

case_begin "E7-deny-argvraw-unsafe-backtick" "$T_SCRIPT"
check "E7-deny-argvraw-unsafe-backtick" "deny" "$(e_run argv2-unsafe-backtick)"
case_end

case_begin "E8-deny-argvraw-unsafe-glob" "$T_SCRIPT"
check "E8-deny-argvraw-unsafe-glob" "deny" "$(e_run argv2-unsafe-glob)"
case_end

case_begin "E9-deny-argvraw-unsafe-bracket" "$T_SCRIPT"
check "E9-deny-argvraw-unsafe-bracket" "deny" "$(e_run argv2-unsafe-bracket)"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
