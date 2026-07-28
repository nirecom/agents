# tests/feature-1640-count-subagents/lib.sh
# Shared harness + fixture vocabulary for tests/feature-1640-count-subagents.sh.
# Sourced by that dispatcher — not executable standalone, and not picked up by
# tests/run-all.sh (which globs tests/*.sh at the top level only).
#
# Extracted from the entry file purely for the HARD 500-line limit in
# rules/coding/file-split.md; the case bodies all stay in the entry file. Same
# arrangement as tests/feature-1180-commit-lang-check/lib.sh.
#
# Provides: AGENTS_DIR, SCRIPT, TMPROOT (+ EXIT trap), PASS/FAIL/SKIP counters,
# assert_eq / skip_case / run_with_timeout / native_path / run_cli / node_m /
# summary / type_count / has_summary / deny_read, the SID_*/AGENT_UUID/SECRET_TITLE
# fixture constants, and the rec / content / title / new_root record builders.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$AGENTS_DIR/bin/count-subagents"

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

skip_case() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() { "$AGENTS_DIR/bin/run-with-timeout.sh" "$@"; }

native_path() { (cd "$1" 2>/dev/null && (pwd -W 2>/dev/null || pwd)) || printf '%s' "$1"; }

ISO_HOME="$TMPROOT/iso-home"
mkdir -p "$ISO_HOME"
ISO_HOME_NATIVE="$(native_path "$ISO_HOME")"

# Standard invocation: both isolation overrides, every time. Sets CLI_RC / CLI_OUT
# (merged) and CLI_STDOUT / CLI_STDERR (split).
run_cli() {
    local ef
    ef="$(mktemp "$TMPROOT/stderr.XXXXXX")"
    CLI_RC=0
    CLI_STDOUT="$(HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        run_with_timeout 60 node "$SCRIPT" "$@" 2>"$ef")" || CLI_RC=$?
    CLI_STDERR="$(cat "$ef")"
    CLI_OUT="$CLI_STDOUT
$CLI_STDERR"
}

# Direct module access, same isolation. Sets NODE_RC / NODE_OUT.
node_m() { # <js>
    NODE_RC=0
    NODE_OUT="$(cd "$AGENTS_DIR" && HOME="$ISO_HOME" USERPROFILE="$ISO_HOME_NATIVE" \
        run_with_timeout 60 node -e "$1" 2>&1)" || NODE_RC=$?
}

# `<key>=<value>` out of the summary line.
summary() { # <key>
    local line
    line="$(grep -F -- 'subagent-summary:' <<< "$CLI_OUT" | head -1)"
    [ -n "$line" ] || { printf 'NO-SUMMARY'; return 0; }
    local v
    v="$(grep -oE "$1=[0-9]+" <<< "$line" | head -1 | cut -d= -f2)"
    printf '%s' "${v:-NO-KEY}"
}

# The `<count>  <subagent_type>` row for one type. `NO-ROW` is only reported when the tool
# actually produced a report — an absent type must never be indistinguishable from an
# absent run (no vacuous pass).
type_count() { # <type>
    local v
    v="$(grep -E "^[0-9]+[[:space:]]+$1$" <<< "$CLI_STDOUT" | head -1 | awk '{print $1}')"
    if [ -n "$v" ]; then printf '%s' "$v"
    elif grep -qF -- 'subagent-summary:' <<< "$CLI_OUT"; then printf 'NO-ROW'
    else printf 'NO-REPORT'; fi
}

# Whether a summary line was printed at all. Paired into rows that would otherwise pass
# on a run that produced no output.
has_summary() {
    if grep -qF -- 'subagent-summary:' <<< "$CLI_OUT"; then printf 'summary-printed'
    else printf 'no-summary-line'; fi
}

# POSIX denial with proof it took effect. chmod is advisory on MSYS/Windows and ignored
# for root, so a naive `chmod 000` would produce a false PASS.
deny_read() { # <path>
    chmod 000 "$1" 2>/dev/null || return 1
    if [ -d "$1" ]; then
        ls "$1" >/dev/null 2>&1 && { chmod 755 "$1" 2>/dev/null || true; return 1; }
    else
        head -c 1 "$1" >/dev/null 2>&1 && { chmod 644 "$1" 2>/dev/null || true; return 1; }
    fi
    return 0
}

# ---- fixture vocabulary ------------------------------------------------------

SID_A='11111111-2222-3333-4444-555555555555'
SID_B='66666666-7777-8888-9999-aaaaaaaaaaaa'
SID_C='bbbbbbbb-cccc-dddd-eeee-ffffffffffff'
AGENT_UUID='99999999-8888-7777-6666-555555555555'
SECRET_TITLE='ZZPRIVATETITLEMARKERZZ'

# An assistant record carrying one tool_use block with a subagent_type input.
rec() { # <sessionId> <subagent_type> <tool-name> <block-id>
    printf '{"type":"assistant","sessionId":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"%s","input":{"subagent_type":"%s"}}]}}\n' \
        "$1" "$4" "$3" "$2"
}
# A plain content record: makes the file classify as `real`, never `stub`.
content() { printf '{"type":"user","sessionId":"%s","message":{"role":"user","content":"hello"}}\n' "$1"; }
# A title-only record: the whole file being these is what makes it a `stub`.
title() { printf '{"type":"custom-title","sessionId":"%s","customTitle":"%s"}\n' "$1" "$2"; }

new_root() { local p; p="$(mktemp -d "$TMPROOT/proj.XXXXXX")"; printf '%s' "$p"; }
