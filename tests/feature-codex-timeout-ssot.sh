#!/usr/bin/env bash
# tests/feature-codex-timeout-ssot.sh
# Tests: bin/lib/codex-timeout.sh, bin/lib/codex-core.sh, bin/review-plan-codex, bin/github-issues/review-survey-verdict-codex.sh
# Tags: scope:common, codex, timeout, ssot, config-resolution, regression-guard, pwsh-not-required, TL2
#
# WHY: three codex call sites each hardcoded a 300 s default and resolved
# CODEX_TIMEOUT_SECS independently. One measured test-review round finished in
# 184 s while three other rounds of the same payload were killed at 300 s, so the
# default was raised to 900 s and folded into ONE owner, bin/lib/codex-timeout.sh.
# The constant deliberately does NOT live in bin/lib/codex-core.sh: that library
# runs `export SYSTEM_OPS_APPROVED=1` at source time, and the issue-dedupe path
# (bin/github-issues/review-survey-verdict-codex.sh) must not inherit it.
# This file tests timeout RESOLUTION only. It never invokes the codex CLI.
#
# TL3 gap (what this test does NOT catch):
# - Whether the real `timeout` / bin/run-with-timeout.sh wrapper actually kills a
#   live codex process at the resolved value (here only the resolved number is read)
# - Whether the developer's real $AGENTS_CONFIG_DIR/.env is picked up by an
#   unpinned invocation — every case here pins AGENTS_CONFIG_DIR at a fixture
# - Whether sourcing codex-core.sh inside a real reviewer script has no other
#   side effect than the SYSTEM_OPS_APPROVED export
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="$(command -v bash)"

LIB_TIMEOUT="$AGENTS_DIR/bin/lib/codex-timeout.sh"
LIB_CORE="$AGENTS_DIR/bin/lib/codex-core.sh"
SRC_PLAN="$AGENTS_DIR/bin/review-plan-codex"
SRC_SURVEY="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
SOURCES=("$LIB_TIMEOUT" "$LIB_CORE" "$SRC_PLAN" "$SRC_SURVEY")

# Fixture isolation (rules/test/fixture-isolation.md): never resolve the live
# session, and never let a child read the developer's real config .env.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_TIMEOUT_SECS

ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'codextmo')"
trap 'cd / 2>/dev/null || true; rm -rf "$ROOT" 2>/dev/null || true' EXIT
mkdir -p "$ROOT/noenv" "$ROOT/withenv" "$ROOT/alone/lib" "$ROOT/stub" "$ROOT/cwd"

# The config file is written by this script, inside mktemp -d — never the repo's.
printf 'CODEX_TIMEOUT_SECS=777\n' > "$ROOT/withenv/.env"
FIX_NOENV="$ROOT/noenv"
FIX_ENV="$ROOT/withenv"

cd "$ROOT/cwd" || exit 1

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

# resolve <lib> <config-dir> [value] — sources the library in a fresh bash and echoes
# codex_timeout_resolve's answer. Omitting [value] leaves CODEX_TIMEOUT_SECS unset
# in the child (env -u), so "unset" and "set" rows differ only in that variable.
resolve() {
    local lib="$1" cfg="$2" val="${3-__UNSET__}"
    if [ "$val" = "__UNSET__" ]; then
        env -u CODEX_TIMEOUT_SECS AGENTS_CONFIG_DIR="$cfg" \
            "$BASH_BIN" -c 'source "$0"; codex_timeout_resolve' "$lib"
    else
        env CODEX_TIMEOUT_SECS="$val" AGENTS_CONFIG_DIR="$cfg" \
            "$BASH_BIN" -c 'source "$0"; codex_timeout_resolve' "$lib"
    fi
}

# const <lib> <config-dir> — echoes the constant the library publishes.
const() {
    env -u CODEX_TIMEOUT_SECS AGENTS_CONFIG_DIR="$2" \
        "$BASH_BIN" -c 'source "$0"; printf %s "$CODEX_TIMEOUT_SECS_DEFAULT"' "$1"
}

# code_hits <awk-condition> — prints `path:line: text` for every NON-comment
# source line matching the condition. Comment lines are excluded on purpose and
# only here: codex-timeout.sh's header narrates the historical 300 s ceiling, and
# that sentence must survive (G1c proves the exclusion is that narrow).
code_hits() { awk "!/^[[:space:]]*#/ && $1 { print FILENAME \":\" FNR \": \" \$0 }" "${SOURCES[@]}"; }

# ---------------------------------------------------------------------------
# N1: the canonical default is 900, read by sourcing the library itself.
# ---------------------------------------------------------------------------
assert_eq "N1: CODEX_TIMEOUT_SECS_DEFAULT published by codex-timeout.sh" \
    "900" "$(const "$LIB_TIMEOUT" "$FIX_NOENV")"

# ---------------------------------------------------------------------------
# N2: no process env, config dir without a .env → the default.
# ---------------------------------------------------------------------------
assert_eq "N2: unset env + config dir with no .env resolves to the default" \
    "900" "$(resolve "$LIB_TIMEOUT" "$FIX_NOENV")"

# ---------------------------------------------------------------------------
# N3: process env wins over the default.
# ---------------------------------------------------------------------------
assert_eq "N3: process env CODEX_TIMEOUT_SECS=1234 resolves to 1234" \
    "1234" "$(resolve "$LIB_TIMEOUT" "$FIX_NOENV" 1234)"

# ---------------------------------------------------------------------------
# N4: the .env layer. Previously unverified: the whole point of the SSOT is that
#     one key in one file moves every codex call site.
# ---------------------------------------------------------------------------
assert_eq "N4: fixture .env CODEX_TIMEOUT_SECS=777 resolves to 777" \
    "777" "$(resolve "$LIB_TIMEOUT" "$FIX_ENV")"

# ---------------------------------------------------------------------------
# N5: precedence — process env beats .env (bin/get-config-var's contract).
# ---------------------------------------------------------------------------
assert_eq "N5: process env 1234 beats fixture .env 777" \
    "1234" "$(resolve "$LIB_TIMEOUT" "$FIX_ENV" 1234)"

# ---------------------------------------------------------------------------
# N6: the re-export path. A script that sources codex-core.sh must get the same
#     constant AND the same resolved value, or the two libraries have drifted.
# ---------------------------------------------------------------------------
n6_const="$(const "$LIB_CORE" "$FIX_ENV")"
n6_resolved="$(resolve "$LIB_CORE" "$FIX_ENV")"
assert_eq "N6a: codex-core.sh re-exports the same constant as codex-timeout.sh" \
    "$(const "$LIB_TIMEOUT" "$FIX_ENV")" "$n6_const"
assert_eq "N6b: codex-core.sh resolves the same .env value as codex-timeout.sh" \
    "$(resolve "$LIB_TIMEOUT" "$FIX_ENV")" "$n6_resolved"

# ---------------------------------------------------------------------------
# E-table: non-integer / malformed values fall back to the default. Table-driven
# per skills/_shared/test-design/parser-regex-tests.md. Run against the config
# dir WITHOUT a .env so the fallback lands on the default and not on 777.
# `<empty>` is the literal empty string; `<sp>` marks a significant space.
# ---------------------------------------------------------------------------
while IFS='|' read -r name input want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    input="$(printf '%s' "$input" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ "$input" = "<empty>" ] && input=""
    input="${input//<sp>/ }"
    got="$(resolve "$LIB_TIMEOUT" "$FIX_NOENV" "$input")"
    assert_eq "E: $name" "$want" "$got"
done <<'TABLE'
empty-string        | <empty>  | 900
alphabetic          | abc      | 900
negative            | -5       | 900
decimal             | 12.5     | 900
leading-whitespace  | <sp>123  | 900
trailing-whitespace | 456<sp>  | 900
scientific-notation | 9e2      | 900
non-ascii-digits    | ٩٠٠      | 900
zero-passthrough    | 0        | 0
TABLE
# `zero-passthrough` asserts the ACTUAL current behavior: "0" matches the ^[0-9]+$
# guard, so it survives. GNU timeout reads 0 as "no time limit", making this row a
# documented escape hatch (an operator wanting an unbounded codex round sets 0), not
# a bug. If the guard is ever tightened to reject 0, this row is where that is re-decided.

# ---------------------------------------------------------------------------
# F1: get-config-var unreachable. The library is copied ALONE into a temp dir
#     (so its ../get-config-var sibling does not exist) and PATH is scrubbed down
#     to a stub dir holding only `dirname`, which the library needs to locate
#     itself. Both branches of the fallback are covered.
# ---------------------------------------------------------------------------
printf '#!/bin/sh\nd="${1%%/*}"\n[ "$d" = "$1" ] && d=.\n[ -n "$d" ] || d=/\nprintf %%s\\\\n "$d"\n' \
    > "$ROOT/stub/dirname"
chmod +x "$ROOT/stub/dirname"
cp "$LIB_TIMEOUT" "$ROOT/alone/lib/codex-timeout.sh"
LIB_ALONE="$ROOT/alone/lib/codex-timeout.sh"

# Precondition: without this the two F1 rows would prove nothing — they would be
# exercising the normal get-config-var path and passing for the wrong reason.
if PATH="$ROOT/stub" "$BASH_BIN" -c 'command -v get-config-var >/dev/null 2>&1'; then
    fail "F1-pre: get-config-var is still reachable under the scrubbed PATH — F1 proves nothing"
else
    pass "F1-pre: get-config-var is unreachable under the scrubbed PATH"
fi

assert_eq "F1a: no get-config-var + unset env falls back to the default" \
    "900" "$(PATH="$ROOT/stub" "$BASH_BIN" -c 'source "$0"; codex_timeout_resolve' "$LIB_ALONE")"
assert_eq "F1b: no get-config-var + process env 4321 falls back to the process env" \
    "4321" "$(PATH="$ROOT/stub" CODEX_TIMEOUT_SECS=4321 "$BASH_BIN" -c 'source "$0"; codex_timeout_resolve' "$LIB_ALONE")"

# ---------------------------------------------------------------------------
# G1 (CPR-SSOT): across the four sources, the default numeric literal appears in
#     executable code exactly once — on the CODEX_TIMEOUT_SECS_DEFAULT= line —
#     and no reintroduced 300 (or any other timeout literal) sits at a call site.
# ---------------------------------------------------------------------------
run_G1() {
    local hits900 count900 hits300 hitsnum problems=""
    hits900="$(code_hits '$0 ~ /(^|[^0-9])900([^0-9]|$)/')"
    count900="$(printf '%s' "$hits900" | grep -c .)"
    [ "$count900" = "1" ] || problems="$problems [900 appears on $count900 code lines, want 1]"
    printf '%s\n' "$hits900" | grep -q 'codex-timeout\.sh:.*CODEX_TIMEOUT_SECS_DEFAULT=900' ||
        problems="$problems [the single 900 is not the CODEX_TIMEOUT_SECS_DEFAULT= assignment]"
    hits300="$(code_hits '$0 ~ /(^|[^0-9])300([^0-9]|$)/')"
    [ -z "$hits300" ] || problems="$problems [300 reintroduced: $(printf '%s' "$hits300" | head -3)]"
    # Any other timeout-flavoured literal at a call site (e.g. `${CODEX_TIMEOUT_SECS:-600}`).
    hitsnum="$(code_hits '$0 ~ /TIMEOUT/ && $0 ~ /[0-9][0-9]/ && $0 !~ /^CODEX_TIMEOUT_SECS_DEFAULT=/')"
    [ -z "$hitsnum" ] || problems="$problems [second timeout literal: $(printf '%s' "$hitsnum" | head -3)]"
    if [ -z "$problems" ]; then
        pass "G1: the default literal lives on exactly one code line, and no call site carries its own"
    else
        fail "G1: timeout literal is no longer single-sourced;$problems"
    fi
}
run_G1

# ---------------------------------------------------------------------------
# G1c (counter-anchor for G1): the comment exclusion is narrow. The scanner must
#     still SEE 300 in codex-timeout.sh's header prose — otherwise G1's "no 300"
#     result could come from a scanner that reads nothing at all.
# ---------------------------------------------------------------------------
if awk '/^[[:space:]]*#/ && $0 ~ /(^|[^0-9])300([^0-9]|$)/' "$LIB_TIMEOUT" | grep -q .; then
    pass "G1c: the historical 300 s note survives in codex-timeout.sh comments and the scanner sees it"
else
    fail "G1c: no commented 300 found — either the rationale was deleted or the scanner is blind"
fi

# ---------------------------------------------------------------------------
# G2: the issue-dedupe path sources the timeout library DIRECTLY and must not
#     source codex-core.sh (see G5 for why).
# ---------------------------------------------------------------------------
run_G2() {
    local problems=""
    awk '!/^[[:space:]]*#/ && /source .*codex-timeout\.sh/' "$SRC_SURVEY" | grep -q . ||
        problems="$problems [does not source codex-timeout.sh]"
    awk '!/^[[:space:]]*#/ && /codex-core\.sh/' "$SRC_SURVEY" | grep -q . &&
        problems="$problems [pulls in codex-core.sh]"
    awk '!/^[[:space:]]*#/ && /codex_timeout_resolve/' "$SRC_SURVEY" | grep -q . ||
        problems="$problems [does not call codex_timeout_resolve]"
    if [ -z "$problems" ]; then
        pass "G2: review-survey-verdict-codex.sh sources codex-timeout.sh only, and resolves through it"
    else
        fail "G2: dedupe path wiring wrong;$problems"
    fi
}
run_G2

# ---------------------------------------------------------------------------
# G3: codex-core.sh sources codex-timeout.sh — the wiring N6 depends on.
# ---------------------------------------------------------------------------
if awk '!/^[[:space:]]*#/ && /source .*codex-timeout\.sh/' "$LIB_CORE" | grep -q .; then
    pass "G3: codex-core.sh sources codex-timeout.sh (the re-export path)"
else
    fail "G3: codex-core.sh no longer sources codex-timeout.sh — N6's re-export is unsupported"
fi

# ---------------------------------------------------------------------------
# G4: review-plan-codex's timeout invocation goes through codex_timeout_resolve.
# ---------------------------------------------------------------------------
run_G4() {
    local problems=""
    awk '!/^[[:space:]]*#/ && /CODEX_TIMEOUT_SECS_RESOLVED="\$\(codex_timeout_resolve\)"/' "$SRC_PLAN" |
        grep -q . || problems="$problems [no CODEX_TIMEOUT_SECS_RESOLVED=\$(codex_timeout_resolve)]"
    awk '!/^[[:space:]]*#/ && /^timeout "\$CODEX_TIMEOUT_SECS_RESOLVED"/' "$SRC_PLAN" |
        grep -q . || problems="$problems [timeout is not invoked with the resolved value]"
    if [ -z "$problems" ]; then
        pass "G4: review-plan-codex resolves through codex_timeout_resolve and passes it to timeout"
    else
        fail "G4: review-plan-codex call site wrong;$problems"
    fi
}
run_G4

# ---------------------------------------------------------------------------
# G5 (counter-anchor for G2's rationale): codex-core.sh still exports
#     SYSTEM_OPS_APPROVED=1 at source time. That export is the ONLY reason G2
#     forbids the dedupe path from sourcing codex-core.sh. If this export is ever
#     removed, G2's justification is gone and this test must be revisited —
#     G2 would then be guarding a rule with no remaining reason behind it.
# ---------------------------------------------------------------------------
if awk '!/^[[:space:]]*#/ && /^export SYSTEM_OPS_APPROVED=1/' "$LIB_CORE" | grep -q .; then
    pass "G5: codex-core.sh still exports SYSTEM_OPS_APPROVED=1 at source time (G2's rationale holds)"
else
    fail "G5: SYSTEM_OPS_APPROVED export is gone from codex-core.sh — revisit G2's separation rule"
fi

# ---------------------------------------------------------------------------
# G6: all four sources are syntactically valid bash.
# ---------------------------------------------------------------------------
run_G6() {
    local f problems=""
    for f in "${SOURCES[@]}"; do
        "$BASH_BIN" -n "$f" 2>/dev/null || problems="$problems [$(basename "$f")]"
    done
    if [ -z "$problems" ]; then
        pass "G6: all four codex-timeout sources pass bash -n"
    else
        fail "G6: bash -n failed for;$problems"
    fi
}
run_G6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
