#!/usr/bin/env bash
# tests/feature-530-promotion-callsite-conditions.sh
# Tests: skills/worktree-end/SKILL.md, skills/session-close/SKILL.md, skills/issue-close-finalize/SKILL.md, bin/worktree-notes-triage/resolve.js
# Tags: notes-promotion, worktree-notes, skill-orchestration, static, prompt-contract, TL1, scope:issue-specific
#
# Issue #530 — the three promotion callsites are NOT interchangeable. Each one
# runs under a different condition, and getting the condition wrong is invisible
# until a live session either promotes twice or never promotes at all:
#
#   WE-11 (worktree-end)          unconditional, path from --worktree
#   SC-8  (session-close)         after the Final Report, only if entries remain
#   ICF   (issue-close-finalize)  residual pass, NOT under --from-session
#                                 (session-close owns that run — see SC-8)
#
# This test pins each condition to its own block so a copy-paste between the
# three cannot pass. It is a companion to
# tests/feature-530-notes-promotion-protocol.sh, which checks the shared
# protocol file itself.
#
# TL1 (static): the subject is prompt text plus the caller-name enum in
# bin/worktree-notes-triage/resolve.js.
#
# RED before write-code: none of the three blocks exists yet, so groups A–D fail
# with "no block found"; group E skips (resolve.js absent).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

WE_MD="$AGENTS_DIR/skills/worktree-end/SKILL.md"
SC_MD="$AGENTS_DIR/skills/session-close/SKILL.md"
ICF_MD="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"
RESOLVE_JS="$AGENTS_DIR/bin/worktree-notes-triage/resolve.js"

# The accepted --caller enum. Group E cross-checks this against resolve.js once
# that file exists; groups A–C use it as the per-callsite expectation.
EXPECTED_CALLERS="issue-close-finalize,session-close,worktree-end"

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/np-callsite-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Print the markdown section containing the first line carrying `needle`:
# nearest preceding heading through the line before the next same-or-shallower
# heading. Exit 1 when the needle is absent.
extract_section_containing() {
    awk -v needle="$2" '
        function depth_of(l,   d) { d = 0; while (substr(l, d + 1, 1) == "#") d++; return d }
        { line[NR] = $0 }
        END {
            target = 0
            for (i = 1; i <= NR; i++) if (index(line[i], needle) > 0) { target = i; break }
            if (target == 0) exit 1
            start = 0
            for (i = target; i >= 1; i--) if (line[i] ~ /^#+ /) { start = i; break }
            if (start == 0) start = 1
            d0 = depth_of(line[start])
            end = NR
            for (i = start + 1; i <= NR; i++) {
                if (line[i] ~ /^#+ / && depth_of(line[i]) <= d0) { end = i - 1; break }
            }
            for (i = start; i <= end; i++) print line[i]
        }
    ' "$1"
}

# Load the block for one caller into $BLOCK. Returns 1 (and reports the failure)
# when the callsite is absent or the extracted block looks unscoped.
BLOCK=""
load_block() {
    local label="$1" path="$2" caller="$3" lines
    BLOCK=""
    if [ ! -f "$path" ]; then
        fail "$label: ${path#"$AGENTS_DIR/"} missing"
        return 1
    fi
    if ! BLOCK="$(extract_section_containing "$path" "--caller $caller")"; then
        fail "$label: no block containing '--caller $caller' in ${path#"$AGENTS_DIR/"}"
        return 1
    fi
    lines="$(printf '%s\n' "$BLOCK" | wc -l | tr -d '[:space:]')"
    # A block far larger than a step is a sign the heading scan ran off the end;
    # every scoped grep below would then be a false green.
    if [ "${lines:-0}" -gt 40 ]; then
        fail "$label: extracted block is $lines lines — scoping looks broken"
        return 1
    fi
    return 0
}

block_has()  { printf '%s\n' "$BLOCK" | grep -qF -- "$1"; }
block_hasE() { printf '%s\n' "$BLOCK" | grep -qE -- "$1"; }

# ===========================================================================
# Group A — WE-11: unconditional, worktree-anchored
# ===========================================================================
group_we11() {
    load_block "A" "$WE_MD" "worktree-end" || return
    local missing="" forbidden=""

    block_has '--caller worktree-end' || missing="$missing --caller=worktree-end"
    block_has '--worktree'            || missing="$missing --worktree"
    # "unconditional" is the whole point of WE-11: the worktree is about to be
    # deleted, so there is no later run to defer to.
    block_hasE 'unconditional|無条件' || missing="$missing unconditional-marker"

    # Conditional markers belong to SC-8 / ICF, not here.
    block_hasE 'only when|only if'  && forbidden="$forbidden only-when"
    block_hasE '(^|[^-])\bif\b'     && forbidden="$forbidden bare-if"
    block_has '--from-session'   && forbidden="$forbidden --from-session"

    if [ -z "$missing" ] && [ -z "$forbidden" ]; then
        pass "A: WE-11 promotes unconditionally from --worktree, with no conditional markers"
    else
        fail "A: WE-11 condition wrong" "missing:${missing:-none} forbidden:${forbidden:-none}"
    fi
}

# ===========================================================================
# Group B — SC-8: after the Final Report, only if entries remain
# ===========================================================================
group_sc8() {
    load_block "B" "$SC_MD" "session-close" || return
    local missing=""

    block_has '--caller session-close' || missing="$missing --caller=session-close"
    block_has '--session-id'           || missing="$missing --session-id"
    # Ordering: SC-8 runs AFTER the Final Report is emitted.
    if block_hasE 'Final Report|送出後'; then
        block_hasE 'after|後' || missing="$missing after-marker"
    else
        missing="$missing final-report-ordering"
    fi
    # Conditionality: only when something is still unpromoted.
    block_hasE 'remain|残|only|if ' || missing="$missing remaining-entries-condition"

    if [ -z "$missing" ]; then
        pass "B: SC-8 runs after the Final Report, keyed on --session-id, only if entries remain"
    else
        fail "B: SC-8 condition wrong" "missing:$missing"
    fi
}

# ===========================================================================
# Group C — ICF residual: not under --from-session (SC-8 owns that run)
# ===========================================================================
group_icf() {
    load_block "C" "$ICF_MD" "issue-close-finalize" || return
    local missing=""

    block_has '--caller issue-close-finalize' || missing="$missing --caller=issue-close-finalize"
    block_has '--issue'                       || missing="$missing --issue"
    # The exclusion must be explicit: --from-session runs are session-close's.
    if block_has '--from-session'; then
        block_hasE 'only|unless|以外' || missing="$missing from-session-exclusion-word"
    else
        missing="$missing --from-session"
    fi
    block_has 'SC-8' || missing="$missing SC-8-handoff-reference"

    if [ -z "$missing" ]; then
        pass "C: ICF residual pass excludes --from-session runs and points at SC-8"
    else
        fail "C: ICF residual condition wrong" "missing:$missing"
    fi
}

# ===========================================================================
# Group D — no callsite asks the user
# ===========================================================================
group_no_ask() {
    local hits="" entry label path caller found=0
    for entry in "WE-11|$WE_MD|worktree-end" \
                 "SC-8|$SC_MD|session-close" \
                 "ICF|$ICF_MD|issue-close-finalize"; do
        label="${entry%%|*}"
        path="$(printf '%s' "$entry" | cut -d'|' -f2)"
        caller="${entry##*|}"
        [ -f "$path" ] || continue
        if BLOCK="$(extract_section_containing "$path" "--caller $caller")"; then
            found=$((found + 1))
            block_has 'AskUserQuestion' && hits="$hits $label"
        fi
    done
    # Without this guard D would pass vacuously while all three blocks are still
    # missing — the exact false green this suite exists to prevent.
    if [ "$found" -ne 3 ]; then
        fail "D: only $found/3 promotion callsite blocks found — cannot assert AskUserQuestion absence"
    elif [ -z "$hits" ]; then
        pass "D: no promotion callsite block contains AskUserQuestion"
    else
        fail "D: AskUserQuestion still present in block(s):$hits"
    fi
}

# ===========================================================================
# Group E — the --caller values used above are exactly the enum resolve.js takes
# ===========================================================================
group_caller_enum_matches_resolve() {
    if [ ! -f "$RESOLVE_JS" ]; then
        skip "E: caller enum cross-check (resolve.js not yet implemented)"
        return
    fi
    local actual
    actual="$(run_with_timeout 30 node -e '
      (function () {
        const m = require(process.argv[1]);
        const v = m.CALLERS || m.ACCEPTED_CALLERS || m.VALID_CALLERS;
        if (!Array.isArray(v)) { process.stdout.write("NO_EXPORT"); return; }
        process.stdout.write(v.slice().sort().join(","));
      })();
    ' "$(nodepath "$RESOLVE_JS")" 2>&1)"
    if [ "$actual" = "$EXPECTED_CALLERS" ]; then
        pass "E: resolve.js accepts exactly {$EXPECTED_CALLERS}"
    else
        fail "E: caller enum drift" "resolve.js='$actual' expected='$EXPECTED_CALLERS'"
    fi
}

group_we11
group_sc8
group_icf
group_no_ask
group_caller_enum_matches_resolve

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
