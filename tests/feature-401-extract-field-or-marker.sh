#!/bin/bash
# tests/feature-401-extract-field-or-marker.sh
# Tests: bin/github-issues/lib/extract-field.sh
# Tags: github, issues, bin, tests, scope:issue-specific, layer:TL1
#
# extract_field_or_marker() — an unrecorded field yields the explicit marker
# "(no <Field> recorded)" instead of borrowing the issue title or the body's
# first line (#2098 replaced the fabricating fallback with a marker).

set -u

# TL3 gap (what this test does NOT catch):
# - The function is sourced into THIS shell, so issue-to-history.sh's own
#   `source` line and any stale deployed ~/.claude/ copy stay unexercised.
# - GitHub's hosted form decides whether a body arrives empty at all.
# Closest-to-action mitigation: bin/check-verification-gate.sh has no category
# for bin/github-issues/** (pwsh-required, hook-registration,
# skill-orchestration, installer, merge-base-suspect), so nothing auto-prompts;
# the subprocess half is covered by feature-401-issue-to-history-shapes.sh
# (TL2), the hosted-form half by the plan's S10 manual render check.

PASS=0
FAIL=0

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTRACT_LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPFILES=()
cleanup() {
    for f in "${TMPFILES[@]:-}"; do [ -n "${f:-}" ] && rm -rf "$f"; done
}
trap cleanup EXIT

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Source library (file must exist for any test to pass)
if [ ! -f "$EXTRACT_LIB" ]; then
    fail "extract-field.sh not found at $EXTRACT_LIB"
    echo ""
    echo "Passed: $PASS / $((PASS + FAIL))"
    exit 1
fi

# shellcheck disable=SC1090
. "$EXTRACT_LIB"

if ! declare -f extract_field_or_marker >/dev/null 2>&1; then
    fail "extract_field_or_marker function not defined"
fi

# Helper: invoke the subject if defined; otherwise return empty + non-zero so
# tests fail predictably instead of silently passing.
call_extract() {
    if declare -f extract_field_or_marker >/dev/null 2>&1; then
        extract_field_or_marker "$@"
    else
        printf ''
        return 127
    fi
}

# -----------------------------------------------------------------------------
# F1: English Background:/Changes: headers present → extracted normally
# -----------------------------------------------------------------------------
BODY="Background: Existing background text
Changes: Existing changes text"
export BODY
got_bg="$(call_extract Background)"
got_ch="$(call_extract Changes)"
if [ "$got_bg" = "Existing background text" ] && [ "$got_ch" = "Existing changes text" ]; then
    pass "F1: existing headers → extracted normally, no marker used"
else
    fail "F1: expected 'Existing background text'/'Existing changes text', got '$got_bg'/'$got_ch'"
fi

# -----------------------------------------------------------------------------
# F2: No headers + plain body → Background = marker, NOT the (legacy) title arg
# The extra "my-title" positional is the OLD signature's 2nd argument, passed on
# purpose: extract_field_or_marker(field) reads only $1, so bash ignores it.
# This fixes "callers on the old signature do not break"; it does NOT verify
# propagation. Regression cover for title-borrowing lives in
# tests/feature-401-issue-to-history-shapes.sh NG1.
# -----------------------------------------------------------------------------
BODY="just some plain body text with no field markers"
export BODY
got="$(call_extract Background "my-title" "my-body")"
if [ "$got" = "(no Background recorded)" ]; then
    pass "F2: no headers → Background yields the explicit marker"
else
    fail "F2: expected '(no Background recorded)', got '$got'"
fi
if [ "$got" != "my-title" ] && [ "${got#*my-title}" = "$got" ]; then
    pass "F2b: legacy 2nd positional (title) never leaks into the output"
else
    fail "F2b: legacy title argument leaked into output: '$got'"
fi

# -----------------------------------------------------------------------------
# F3: Empty body → Changes = marker; legacy 3rd positional (fallback body) is
# passed on purpose and must not surface (see F2's note).
# -----------------------------------------------------------------------------
BODY=""
export BODY
legacy_body="$(printf '## \xe8\x83\x8c\xe6\x99\xaf\n\xe6\x9c\xac\xe6\x96\x87\xe3\x83\x86\xe3\x82\xb9\xe3\x83\x88\n')"
legacy_first_line="$(printf '%s\n' "$legacy_body" | grep -v '^#' | awk 'NF{print; exit}')"
got="$(call_extract Changes "title-x" "$legacy_body")"
if [ "$got" = "(no Changes recorded)" ]; then
    pass "F3: empty body → Changes yields the explicit marker"
else
    fail "F3: expected '(no Changes recorded)', got '$got'"
fi
if [ -n "$legacy_first_line" ] && [ "${got#*"$legacy_first_line"}" = "$got" ]; then
    pass "F3b: legacy 3rd positional (body first line) never leaks into the output"
else
    fail "F3b: legacy body first line leaked into output: '$got'"
fi

# -----------------------------------------------------------------------------
# F4: Empty body → Background = marker
# -----------------------------------------------------------------------------
BODY=""
export BODY
got="$(call_extract Background "only-title" "")"
if [ "$got" = "(no Background recorded)" ]; then
    pass "F4: empty body → Background yields the explicit marker"
else
    fail "F4: expected '(no Background recorded)', got '$got'"
fi

# -----------------------------------------------------------------------------
# F5: symmetry (CPR-ORTH) — all four canonical fields produce their own marker
# and exit 0. Table-driven per skills/_shared/test-design/parser-regex-tests.md.
# -----------------------------------------------------------------------------
BODY=""
export BODY
F5_OUTPUTS=()
while IFS='|' read -r name field want; do
    name="$(trim "${name:-}")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    field="$(trim "$field")"
    want="$(trim "$want")"
    got="$(call_extract "$field")"
    rc=$?
    F5_OUTPUTS+=("$got")
    if [ "$got" = "$want" ] && [ "$rc" -eq 0 ]; then
        pass "$name: $field → $want (rc=0)"
    else
        fail "$name: expected '$want' rc=0, got '$got' rc=$rc"
    fi
done <<'TABLE'
F5-background | Background | (no Background recorded)
F5-changes    | Changes    | (no Changes recorded)
F5-cause      | Cause      | (no Cause recorded)
F5-fix        | Fix        | (no Fix recorded)
TABLE

# -----------------------------------------------------------------------------
# F6: normalization (CPR-UNV) — a lowercase field name still yields the
# canonical spelling in the marker.
# -----------------------------------------------------------------------------
BODY=""
export BODY
got="$(call_extract cause)"
if [ "$got" = "(no Cause recorded)" ]; then
    pass "F6: lowercase 'cause' → canonical '(no Cause recorded)'"
else
    fail "F6: expected '(no Cause recorded)', got '$got'"
fi

# -----------------------------------------------------------------------------
# F7: grep-ability — every marker produced by F5 matches the documented ERE
# (the recipe in extract-field.sh / rules/github-issues.md).
# -----------------------------------------------------------------------------
MARKER_ERE='\(no (Background|Changes|Cause|Fix) recorded\)'
f7_miss=0
if [ "${#F5_OUTPUTS[@]}" -ne 4 ]; then
    f7_miss=1
fi
for out in "${F5_OUTPUTS[@]:-}"; do
    printf '%s\n' "$out" | grep -qE "$MARKER_ERE" || f7_miss=1
done
if [ "$f7_miss" -eq 0 ]; then
    pass "F7: all four markers match the documented grep ERE"
else
    fail "F7: at least one marker does not match '$MARKER_ERE' (outputs: ${F5_OUTPUTS[*]:-none})"
fi

# -----------------------------------------------------------------------------
# F8: unknown field name is rejected — no fifth marker form can exist.
# stdout empty, stderr names the error, exit status 2.
# -----------------------------------------------------------------------------
BODY=""
export BODY
F8_ERR="$(mktemp)"
TMPFILES+=("$F8_ERR")
f8_out="$(call_extract Notes 2>"$F8_ERR")"
f8_rc=$?
f8_err="$(cat "$F8_ERR")"
if [ "$f8_rc" -eq 2 ]; then
    pass "F8a: unknown field name → exit status 2"
else
    fail "F8a: expected exit status 2, got $f8_rc"
fi
if [ -z "$f8_out" ]; then
    pass "F8b: unknown field name → stdout empty (no marker emitted)"
else
    fail "F8b: expected empty stdout, got '$f8_out'"
fi
if printf '%s\n' "$f8_err" | grep -q "unknown field name"; then
    pass "F8c: unknown field name → stderr explains the rejection"
else
    fail "F8c: expected 'unknown field name' on stderr, got '$f8_err'"
fi

# -----------------------------------------------------------------------------
# F9: the literal #2094 shape — the field LABEL is present but its value is
# empty (the template `value:` prefill submitted untouched). extract_field's
# regex matches such a line yet captures nothing, so this is a different code
# path from "no label at all" (F2/F4) and needs its own cover at the lowest
# layer that can fail. Table-driven over all four fields (CPR-ORTH).
# -----------------------------------------------------------------------------
INCIDENT_2094_BODY=$'### Cause\n\nCause: \n\n### Fix\n\nFix: '
TASK_2094_BODY=$'### Background\n\nBackground: \n\n### Changes\n\nChanges: '
while IFS='|' read -r name kind field want; do
    name="$(trim "${name:-}")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    kind="$(trim "$kind")"; field="$(trim "$field")"; want="$(trim "$want")"
    if [ "$kind" = "INCIDENT" ]; then BODY="$INCIDENT_2094_BODY"; else BODY="$TASK_2094_BODY"; fi
    export BODY
    got="$(call_extract "$field")"
    rc=$?
    if [ "$got" = "$want" ] && [ "$rc" -eq 0 ]; then
        pass "$name: empty-valued '$field:' label → $want (rc=0)"
    else
        fail "$name: expected '$want' rc=0, got '$got' rc=$rc"
    fi
done <<'TABLE'
F9-cause      | INCIDENT | Cause      | (no Cause recorded)
F9-fix        | INCIDENT | Fix        | (no Fix recorded)
F9-background | TASK     | Background | (no Background recorded)
F9-changes    | TASK     | Changes    | (no Changes recorded)
TABLE

# -----------------------------------------------------------------------------
# F10: classifier counterpart (CPR-ORTH / test-design.md "Classifier / guard
# cases") — F2-F9 pin the marker verdict; F10 pins the OTHER verdict, that a
# populated field passes through unchanged and emits no marker at all. Without
# it a function that returned the marker unconditionally would still be green.
# -----------------------------------------------------------------------------
MARKER_ERE='\(no (Background|Changes|Cause|Fix) recorded\)'
while IFS='|' read -r name body field want; do
    name="$(trim "${name:-}")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    field="$(trim "$field")"
    want="$(trim "$want")"
    BODY="$(trim "$body")"
    export BODY
    got="$(call_extract "$field")"
    rc=$?
    if [ "$got" = "$want" ] && [ "$rc" -eq 0 ]; then
        pass "$name: populated $field survives verbatim (rc=0)"
    else
        fail "$name: expected '$want' rc=0, got '$got' rc=$rc"
    fi
    if printf '%s\n' "$got" | grep -qE "$MARKER_ERE"; then
        fail "${name}b: a marker was emitted for a populated $field: '$got'"
    else
        pass "${name}b: no marker is emitted for a populated $field"
    fi
done <<'TABLE'
F10-background | Background: real background text | Background | real background text
F10-changes    | Changes: real changes text       | Changes    | real changes text
F10-cause      | Cause: real cause text           | Cause      | real cause text
F10-fix        | Fix: real fix text               | Fix        | real fix text
TABLE

# -----------------------------------------------------------------------------
# F11: secret leakage (test-design.md Security cases / OWASP ASVS V8). The old
# signature's title/body arguments were copied into the output; the new one must
# not read them at all. A unique canary in both legacy slots must appear on
# NEITHER stdout NOR stderr.
# -----------------------------------------------------------------------------
BODY=""
export BODY
CANARY="ZZ-canary-4f19b7c2-do-not-leak-ZZ"
F11_ERR="$(mktemp)"
TMPFILES+=("$F11_ERR")
f11_out="$(call_extract Background "$CANARY" "$CANARY" 2>"$F11_ERR")"
f11_err="$(cat "$F11_ERR")"
if [ "$f11_out" = "(no Background recorded)" ]; then
    pass "F11a: canary-bearing legacy args still yield the canonical marker"
else
    fail "F11a: expected '(no Background recorded)', got '$f11_out'"
fi
if [ "${f11_out#*"$CANARY"}" = "$f11_out" ] && [ "${f11_err#*"$CANARY"}" = "$f11_err" ]; then
    pass "F11b: canary appears on neither stdout nor stderr"
else
    fail "F11b: canary leaked — stdout='$f11_out' stderr='$f11_err'"
fi

# -----------------------------------------------------------------------------
# F12: input injection (test-design.md Security cases / CWE-78). Shell
# metacharacter payloads in the legacy title/body slots must be inert: the
# output stays the bare marker and no sentinel file is created. Payloads are
# single-quoted literals in the heredoc so this test never evaluates them; the
# delimiter is `~` because one payload contains `|`. Side effects are confined
# to INJ_TMP (rules/test/fixture-isolation.md) and the call runs with that dir
# as CWD so a relative sentinel path would land there.
# -----------------------------------------------------------------------------
INJ_TMP="$(mktemp -d)"
TMPFILES+=("$INJ_TMP")
F12_ERR="$(mktemp)"
TMPFILES+=("$F12_ERR")
while IFS='~' read -r name payload; do
    name="$(trim "${name:-}")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    BODY=""
    export BODY
    got="$(cd "$INJ_TMP" && call_extract Fix "$payload" "$payload" 2>"$F12_ERR")"
    err="$(cat "$F12_ERR")"
    if [ "$got" = "(no Fix recorded)" ] && [ -z "$err" ]; then
        pass "$name: payload is inert — stdout is the bare marker, stderr empty"
    else
        fail "$name: stdout='$got' stderr='$err'"
    fi
done <<'TABLE'
F12-cmdsub   ~ $(touch pwned-sentinel)
F12-backtick ~ `touch pwned-sentinel`
F12-semi     ~ ; touch pwned-sentinel
F12-pipe     ~ | touch pwned-sentinel
F12-redirect ~ > pwned-sentinel
F12-andand   ~ && touch pwned-sentinel
TABLE
inj_leftovers="$(find "$INJ_TMP" -mindepth 1 2>/dev/null)"
if [ -z "$inj_leftovers" ]; then
    pass "F12-sentinel: no side-effect file was created by any payload"
else
    fail "F12-sentinel: payload created files in the temp dir: $inj_leftovers"
fi

# -----------------------------------------------------------------------------
# F13: string edge cases (test-design.md Edge cases). An empty field name is not
# one of the four canonical names, so it takes the same rejection contract as
# F8's unknown name; an oversized legacy payload must still bound the output to
# the canonical marker. Table-driven over the rejection contract's three parts.
# -----------------------------------------------------------------------------
BODY=""
export BODY
F13_ERR="$(mktemp)"
TMPFILES+=("$F13_ERR")
f13_out="$(call_extract "" 2>"$F13_ERR")"
f13_rc=$?
f13_err="$(cat "$F13_ERR")"
while IFS='|' read -r name part want; do
    name="$(trim "${name:-}")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    part="$(trim "$part")"; want="$(trim "$want")"
    case "$part" in
        rc)     got="$f13_rc" ;;
        stdout) got="$([ -z "$f13_out" ] && echo empty || echo nonempty)" ;;
        stderr) got="$(printf '%s\n' "$f13_err" | grep -q 'unknown field name' && echo names-error || echo other)" ;;
    esac
    if [ "$got" = "$want" ]; then
        pass "$name: empty field name → $part=$want"
    else
        fail "$name: expected $part=$want, got '$got' (stderr='$f13_err')"
    fi
done <<'TABLE'
F13a | rc     | 2
F13b | stdout | empty
F13c | stderr | names-error
TABLE

# F14: extremely long legacy title/body — output must stay the bounded marker.
LONG_ARG="$(printf 'x%.0s' $(seq 1 20000))"
while IFS='|' read -r name field want; do
    name="$(trim "${name:-}")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    field="$(trim "$field")"; want="$(trim "$want")"
    BODY=""
    export BODY
    got="$(call_extract "$field" "$LONG_ARG" "$LONG_ARG")"
    if [ "$got" = "$want" ] && [ "${#got}" -eq "${#want}" ]; then
        pass "$name: 20k-char legacy args → bounded marker only (${#got} chars)"
    else
        fail "$name: expected '$want' (${#want} chars), got ${#got} chars: '${got:0:80}'"
    fi
done <<'TABLE'
F14-background | Background | (no Background recorded)
F14-fix        | Fix        | (no Fix recorded)
TABLE

# -----------------------------------------------------------------------------
# F15: field-name case folding (CPR-UNV). F6 pins one lowercase name; the plan's
# normalization contract is "lowercase the argument, map it to one of the four
# canonical spellings", so ANY case mixture must land on the canonical marker.
# Table-driven over the four fields with a different mixture each.
# -----------------------------------------------------------------------------
BODY=""
export BODY
while IFS='|' read -r name field want; do
    name="$(trim "${name:-}")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    field="$(trim "$field")"; want="$(trim "$want")"
    got="$(call_extract "$field")"
    rc=$?
    if [ "$got" = "$want" ] && [ "$rc" -eq 0 ]; then
        pass "$name: '$field' → $want (rc=0)"
    else
        fail "$name: expected '$want' rc=0, got '$got' rc=$rc"
    fi
done <<'TABLE'
F15-upper  | CAUSE      | (no Cause recorded)
F15-title  | Fix        | (no Fix recorded)
F15-mixed  | cAuSe      | (no Cause recorded)
F15-mixed2 | bAckGROUND | (no Background recorded)
F15-upper2 | CHANGES    | (no Changes recorded)
TABLE

# -----------------------------------------------------------------------------
# F16: invalid FIELD NAMES (the live first argument), not the removed legacy
# slots. Each must take F8's complete rejection contract — empty stdout, the
# stderr explanation, rc 2 — so no near-miss name can mint a fifth marker form.
# Payloads are single-quoted heredoc literals (never evaluated here) and the
# call runs inside F16_TMP so a stray redirect would land there, not in the
# worktree. `~` is the delimiter because one payload contains `|`; `@LONG@` is
# substituted with a 5000-char name that the heredoc cannot carry inline.
# -----------------------------------------------------------------------------
F16_TMP="$(mktemp -d)"
TMPFILES+=("$F16_TMP")
F16_ERR="$(mktemp)"
TMPFILES+=("$F16_ERR")
LONG_NAME="$(printf 'C%.0s' $(seq 1 5000))"
while IFS='~' read -r name field; do
    name="$(trim "${name:-}")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    field="$(trim "$field")"
    [ "$field" = "@LONG@" ] && field="$LONG_NAME"
    BODY=""
    export BODY
    got="$(cd "$F16_TMP" && call_extract "$field" 2>"$F16_ERR")"
    rc=$?
    err="$(cat "$F16_ERR")"
    if [ -z "$got" ] && [ "$rc" -eq 2 ] && printf '%s\n' "$err" | grep -q 'unknown field name'; then
        pass "$name: invalid field name → stdout empty, rc 2, stderr names the error"
    else
        fail "$name: stdout='${got:0:60}' rc=$rc stderr='${err:0:80}'"
    fi
done <<'TABLE'
F16-single    ~ C
F16-cmdsub    ~ $(touch pwned-name)
F16-backtick  ~ `touch pwned-name`
F16-semi      ~ Cause; touch pwned-name
F16-pipe      ~ Cause|Fix
F16-glob      ~ *
F16-dotdot    ~ ../Cause
F16-long      ~ @LONG@
TABLE
f16_leftovers="$(find "$F16_TMP" -mindepth 1 2>/dev/null)"
if [ -z "$f16_leftovers" ]; then
    pass "F16-sentinel: no invalid field name created a file"
else
    fail "F16-sentinel: files created: $f16_leftovers"
fi

echo ""
echo "Passed: $PASS / $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
