#!/usr/bin/env bash
# tests/hooks/feature-2265-allow-command-list.sh
# Tests: hooks/lib/allow-command-list.js, install/settings-allow-commands.txt, install/path-exposed-commands.txt
# Tags: hook, bash-guard, allow, allow-command-list, shebang, fail-closed, ssot, scope:issue-specific, pwsh-not-required, TL2

set -uo pipefail

# WHY (#2265). The two list files are the SSOT for which agents scripts bash-guard may answer
# with permissionDecision "allow". This module is the only reader: it validates each entry,
# resolves the interpreter from the shebang, and computes the bare PATH-exposed names. allow
# skips the prompt, so every failure here must mean "no allow targets" -- never a throw
# (the hook would fail open to passThrough anyway) and never a widened target set.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"

PROBE="$(np "$AGENTS_DIR/tests/hooks/feature-2265-allow-command-list/probe.js")"
TMPROOT="$(make_tmp)" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"

# check <name> <want> <got>: harness.sh's assert_eq is unnamed, so failures here say which row.
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}
probe() { run_with_timeout 30 node "$PROBE" "$@" 2>/dev/null; }

# mkroot <dir> <allow-list-lines...>: a fixture agents root with the given allow list and an
# empty PATH list; callers add scripts and the PATH list themselves.
mkroot() {
    local d="$1"; shift
    mkdir -p "$d/install" "$d/bin/sub"
    printf '%s\n' "$@" > "$d/install/settings-allow-commands.txt"
    : > "$d/install/path-exposed-commands.txt"
}
script() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" 'true' > "$1"; }

# ---------------------------------------------------------------------------------------------
# E1: the five entry-rejection classes. A rejected entry must never reach `entries` -- its
# metacharacter or escape would widen what the path normalizer considers "ours".
case_begin "entry-rejection" "hooks/lib/allow-command-list.js"
e1_row() {
    local name="$1" bad="$2" root="$TMPROOT/e1-$1" got
    mkroot "$root" "# fixture" "$bad"
    script "$root/bin/ok" '#!/usr/bin/env bash'
    got="$(probe load "$(np "$root")")"
    case "$got" in
        "<"*) fail "E1/$name: loadAllowTargets answers without throwing" "$got" ;;
        *"$bad"*) fail "E1/$name: the rejected entry is absent from entries" "$got" ;;
        *) pass "E1/$name: the rejected entry [$bad] is absent from entries" ;;
    esac
}
e1_row dotdot       'bin/../bin/ok'
e1_row absolute     '/bin/ok'
e1_row space        'bin/o k'
e1_row glob-meta    'bin/o*'
e1_row backslash    'bin\ok'
case_end

# E2: rejection is per-entry OR whole-list, but never silent widening -- pin that a list of
# only valid entries still loads, so E1 cannot pass vacuously on a loader that returns nothing.
case_begin "entry-valid-baseline" "hooks/lib/allow-command-list.js"
E2="$TMPROOT/e2"
mkroot "$E2" "# comment" "" "bin/a-tool" "bin/sub/b-tool   " "bin/c.js"
check "E2: comments, blank lines and trailing whitespace are ignored; valid entries load" \
    "entries=bin/a-tool,bin/c.js,bin/sub/b-tool;bare=" "$(probe load "$(np "$E2")")"
E2C="$TMPROOT/e2crlf"
mkdir -p "$E2C/install"
printf 'bin/a-tool\r\nbin/c.js\r\n' > "$E2C/install/settings-allow-commands.txt"
: > "$E2C/install/path-exposed-commands.txt"
check "E2: a CRLF list loads the same entries (no trailing \\r on an entry)" \
    "entries=bin/a-tool,bin/c.js;bare=" "$(probe load "$(np "$E2C")")"
case_end

# ---------------------------------------------------------------------------------------------
# S1: shebang resolution. Only bash and node are interpreters the self-script allow can pair
# with; anything else -- or no readable first line -- resolves to null (no allow).
case_begin "shebang-resolution" "hooks/lib/allow-command-list.js"
S1="$TMPROOT/s1"
mkroot "$S1" "# fixture"
script "$S1/bin/env-bash"    '#!/usr/bin/env bash'
script "$S1/bin/abs-bash"    '#!/bin/bash'
script "$S1/bin/env-node"    '#!/usr/bin/env node'
script "$S1/bin/abs-node"    '#!/usr/local/bin/node'
script "$S1/bin/env-flags"   '#!/usr/bin/env  node  --no-warnings'
script "$S1/bin/sh"          '#!/bin/sh'
script "$S1/bin/python"      '#!/usr/bin/env python3'
script "$S1/bin/env-only"    '#!/usr/bin/env'
script "$S1/bin/no-shebang"  'echo hi'
printf '#!/usr/bin/env bash\r\ntrue\r\n' > "$S1/bin/crlf-bash"
mkdir -p "$S1/bin/a-dir"
while IFS='~' read -r name entry want; do
    [ -z "$name" ] && continue
    name="${name//[[:space:]]/}"; entry="${entry//[[:space:]]/}"; want="${want//[[:space:]]/}"
    check "S1/$name: interpreterOf" "$want" "$(probe interp "$(np "$S1")" "$entry")"
done <<'TABLE'
env-bash   ~ bin/env-bash   ~ bash
abs-bash   ~ bin/abs-bash   ~ bash
env-node   ~ bin/env-node   ~ node
abs-node   ~ bin/abs-node   ~ node
env-flags  ~ bin/env-flags  ~ node
crlf-bash  ~ bin/crlf-bash  ~ bash
sh         ~ bin/sh         ~ null
python     ~ bin/python     ~ null
env-only   ~ bin/env-only   ~ null
no-shebang ~ bin/no-shebang ~ null
missing    ~ bin/not-there  ~ null
directory  ~ bin/a-dir      ~ null
TABLE
case_end

# ---------------------------------------------------------------------------------------------
# R1: read failure is an EMPTY target set, not a throw. The hook runs on every Bash call with a
# 5s budget; a throw would be caught upstream, but an answer of "nothing is ours" is the contract.
case_begin "read-failure-empty" "hooks/lib/allow-command-list.js"
check "R1a: a root with no install/ directory yields no targets" \
    "entries=;bare=" "$(probe load "$(np "$TMPROOT/no-such-root")")"
R1B="$TMPROOT/r1b"
mkdir -p "$R1B/install/settings-allow-commands.txt"
printf '%s\n' 'x' > "$R1B/install/path-exposed-commands.txt"
check "R1b: an allow list that is a directory yields no targets" \
    "entries=;bare=" "$(probe load "$(np "$R1B")")"
R1C="$TMPROOT/r1c"
mkdir -p "$R1C/install"
printf '%s\n' 'bin/a-tool' > "$R1C/install/settings-allow-commands.txt"
script "$R1C/bin/a-tool" '#!/usr/bin/env bash'
R1C_GOT="$(probe load "$(np "$R1C")")"
case "$R1C_GOT" in
    "<"*) fail "R1c: a missing PATH list does not throw" "$R1C_GOT" ;;
    *";bare=") pass "R1c: a missing PATH list yields no bare names" ;;
    *) fail "R1c: a missing PATH list yields no bare names" "$R1C_GOT" ;;
esac
case_end

# ---------------------------------------------------------------------------------------------
# L1: edge inputs in the allow list itself. Rows use `;` as the line break ("" = a 0-byte file);
# PATH list is `a-tool`. Duplicates PASS THROUGH (bare is a Set); drive-letter and UNC paths are
# DROPPED per entry, and the valid sibling proves the rest of the list still loads.
case_begin "load-targets-edge-cases" "hooks/lib/allow-command-list.js"
L1_ROWS=0
while IFS='|' read -r name content want; do
    [ -z "$name" ] && continue
    L1_ROWS=$((L1_ROWS + 1))
    root="$TMPROOT/l1-$name"
    mkdir -p "$root/install"
    if [ -z "$content" ]; then : > "$root/install/settings-allow-commands.txt"
    else printf '%s\n' "${content//;/$'\n'}" > "$root/install/settings-allow-commands.txt"; fi
    printf '%s\n' 'a-tool' > "$root/install/path-exposed-commands.txt"
    check "L1/$name: loadAllowTargets" "$want" "$(probe load "$(np "$root")")"
done <<'TABLE'
empty-file||entries=;bare=
comments-and-blanks-only|# header; ;   ;#no-space-comment;  # indented comment|entries=;bare=
duplicate-entries|bin/a-tool;bin/a-tool|entries=bin/a-tool,bin/a-tool;bare=a-tool
drive-letter-backslash|C:\git\agents\bin\tool;bin/a-tool|entries=bin/a-tool;bare=a-tool
drive-letter-slash|C:/git/agents/bin/tool;bin/a-tool|entries=bin/a-tool;bare=a-tool
unc-backslash|\\server\share\bin\tool;bin/a-tool|entries=bin/a-tool;bare=a-tool
unc-slash|//server/share/bin/tool;bin/a-tool|entries=bin/a-tool;bare=a-tool
TABLE
check "L1: every edge-case row executed (an empty table must not pass)" "7" "$L1_ROWS"
case_end

# ---------------------------------------------------------------------------------------------
# B1: exposedBare = basenames of allow-list entries that ALSO appear in the PATH list. A PATH
# name with no allow-list entry (z-unlisted) and an entry with no PATH shim (c-tool) are out.
case_begin "exposed-bare" "hooks/lib/allow-command-list.js"
B1="$TMPROOT/b1"
mkroot "$B1" "bin/a-tool" "bin/sub/b-tool" "bin/c-tool"
printf '%s\n' '# PATH shims' 'a-tool' 'b-tool' 'z-unlisted' > "$B1/install/path-exposed-commands.txt"
check "B1: exposedBare is the intersection of entry basenames and the PATH list" \
    "entries=bin/a-tool,bin/c-tool,bin/sub/b-tool;bare=a-tool,b-tool" "$(probe load "$(np "$B1")")"
case_end

# ---------------------------------------------------------------------------------------------
# G1: the real lists. Smoke only -- which entries exist is the lists' business, but the entries
# the calling-convention docs name must resolve, and review-code-codex is the one real bare name.
case_begin "real-lists-smoke" "install/settings-allow-commands.txt"
REAL="$(probe load "$(np "$AGENTS_DIR")")"
case "$REAL" in
    *"bin/workflow/next-step"*) pass "G1: the real allow list includes bin/workflow/next-step" ;;
    *) fail "G1: the real allow list includes bin/workflow/next-step" "$REAL" ;;
esac
case "$REAL" in
    *";bare="*"review-code-codex"*) pass "G1: review-code-codex is a real exposed bare name" ;;
    *) fail "G1: review-code-codex is a real exposed bare name" "$REAL" ;;
esac
check "G1: next-step resolves to node" "node" "$(probe interp "$(np "$AGENTS_DIR")" bin/workflow/next-step)"
check "G1: confirm-off resolves to bash" "bash" "$(probe interp "$(np "$AGENTS_DIR")" bin/confirm-off)"
case_end

# G2: the logic's SSOT moved here; the retired generator must not be what this module wraps.
case_begin "ssot-owner" "hooks/lib/allow-command-list.js"
G2_MOD="$AGENTS_DIR/hooks/lib/allow-command-list.js"
if [ ! -f "$G2_MOD" ]; then
    fail "G2: hooks/lib/allow-command-list.js exists" "missing"
elif grep -q "settings-allow-rules" "$G2_MOD"; then
    fail "G2: allow-command-list.js does not depend on install/lib/settings-allow-rules.js" "reference found"
else
    pass "G2: allow-command-list.js does not depend on install/lib/settings-allow-rules.js"
fi
case_end

# TL3 gap: none specific -- the module is pure read-only filesystem work. Whether the host
# honours the allow it feeds is probed by tests/hooks/TL3-hook-bash-guard-envelope.sh.

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
