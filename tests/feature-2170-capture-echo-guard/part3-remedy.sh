#!/usr/bin/env bash
# Tests: hooks/block-capture-echo/remedy.js, install/settings-allow-commands.txt
# Tags: capture-echo-guard, remedy-wording, ssot-match, degradation, scope:issue-specific, pwsh-not-required
# Section C — remedy degradation (TL2: reads the real SSOT file and real fixtures).
# The remedy is ADVISORY: it never changes whether a command is rejected, only the
# wording. Branches are classified by two independent wording markers so the test
# does not hard-code a sentence: bare (branch a), scratchpad (branch b), both (c).
# SSOT matching must be by ABSOLUTE PATH IDENTITY, never basename — the negatives
# below (/tmp/, .. disguise, relative, interpreter mismatch) are the whole point.

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - how the wording renders inside a real Claude Code permission prompt
# - whether an author who follows a printed recipe actually gets past the guard
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
export AGENTS_DIR
DRIVER="$(cd "$(dirname "$0")" && pwd)/remedy-driver.js"
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

TMPDIR_C="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_C"' EXIT

# Classify remedy output into a branch token. The pre-implementation
# MODULE_MISSING / EXPORT_MISSING / THREW: signatures pass through unchanged so the
# expected failure stays legible instead of being mangled into "neither".
classify() {
    local out="$1"
    case "$out" in
        MODULE_MISSING|EXPORT_MISSING|THREW:*) printf '%s' "$out"; return ;;
    esac
    local low bare=0 scratch=0
    low="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
    case "$low" in *bare*) bare=1 ;; esac
    case "$low" in *scratchpad*) scratch=1 ;; esac
    if [ "$bare" -eq 1 ] && [ "$scratch" -eq 1 ]; then printf 'both'
    elif [ "$bare" -eq 1 ]; then printf 'bare-only'
    elif [ "$scratch" -eq 1 ]; then printf 'scratchpad-only'
    else printf 'neither'
    fi
}

# Pre-implementation tokens pass through so an absent module never disguises itself
# as a wording assertion failure.
has_substr() {
    case "$1" in
        MODULE_MISSING|EXPORT_MISSING|THREW:*) printf '%s' "$1" ;;
        *"$2"*) printf 'yes' ;;
        *) printf 'no' ;;
    esac
}

# run_remedy <config-dir | --unset> <innerCommandText>
run_remedy() {
    if [ "$1" = "--unset" ]; then
        env -u AGENTS_CONFIG_DIR node "$DRIVER" "$2" 2>&1
    else
        env AGENTS_CONFIG_DIR="$1" node "$DRIVER" "$2" 2>&1
    fi
}

CONFIG_REAL="$AGENTS_DIR"

# --- C-1: absolute-path SSOT hit with interpreter agreement (branch a) --------
OUT="$(run_remedy "$CONFIG_REAL" 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"')"
assert_eq "C-1a-ssot-hit-branch" "bare-only" "$(classify "$OUT")"
assert_eq "C-1b-names-matched-entry" "yes" "$(has_substr "$OUT" "workflow-plans-dir")"

# --- C-2..C-6: identity negatives, one table ---------------------------------
# Every row is a near-miss of the C-1 hit: same basename, same directory, or the same
# file under a different interpreter. All must fall to branch b, so the match is by
# absolute-path identity and nothing weaker. The `|` column separator keeps compound
# commands out of this table — C-17 carries those.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}
run_classify_table() {
    local cfg="$1" name input want
    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        assert_eq "$name" "$want" "$(classify "$(run_remedy "$cfg" "$(trim "$input")")")"
    done
}
run_classify_table "$CONFIG_REAL" <<'TABLE'
C-2-basename-collision-tmp     | bash /tmp/workflow-plans-dir                                 | scratchpad-only
C-3-dotdot-disguise            | bash "$AGENTS_CONFIG_DIR/bin/../../tmp/workflow-plans-dir"   | scratchpad-only
C-4-relative-never-cwd-resolved | bash workflow-plans-dir                                     | scratchpad-only
C-5-interpreter-mismatch       | node "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"             | scratchpad-only
C-6a-absent-relative           | bash bin/compute-staged-tests-token.js                       | scratchpad-only
C-6b-absent-absolute           | node "$AGENTS_CONFIG_DIR/bin/compute-staged-tests-token.js"  | scratchpad-only
TABLE

# --- C-7..C-10: degradation to generic combined guidance (branch c) ----------
OUT="$(run_remedy --unset 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"')"
assert_eq "C-7-config-dir-unset" "both" "$(classify "$OUT")"

MISSING_CFG="$TMPDIR_C/cfg-missing"
mkdir -p "$MISSING_CFG/install"
OUT="$(run_remedy "$MISSING_CFG" 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"')"
assert_eq "C-8-ssot-file-missing" "both" "$(classify "$OUT")"

CORRUPT_CFG="$TMPDIR_C/cfg-corrupt"
mkdir -p "$CORRUPT_CFG/install" "$CORRUPT_CFG/bin"
printf '\x00\x01\x02 not a path list \xfe' >"$CORRUPT_CFG/install/settings-allow-commands.txt"
OUT="$(run_remedy "$CORRUPT_CFG" 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"')"
assert_eq "C-9-ssot-file-corrupt" "both" "$(classify "$OUT")"

NOT_A_DIR="$TMPDIR_C/not-a-dir"
printf 'x' >"$NOT_A_DIR"
OUT="$(run_remedy "$NOT_A_DIR" 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"')"
assert_eq "C-10-config-dir-not-a-directory" "both" "$(classify "$OUT")"

# --- C-11: buildRemedy never throws (fail-open to generic wording) -----------
OUT="$(env AGENTS_CONFIG_DIR="$CONFIG_REAL" MALFORMED_HIT=1 node "$DRIVER" '' 2>&1)"
throw_token() {
    case "$1" in
        THREW:*) printf 'threw' ;;
        MODULE_MISSING|EXPORT_MISSING) printf '%s' "$1" ;;
        *) printf 'no-throw' ;;
    esac
}
assert_eq "C-11-never-throws" "no-throw" "$(throw_token "$OUT")"

# --- C-12: unresolvable inner command still yields actionable guidance -------
OUT="$(run_remedy "$CONFIG_REAL" 'if')"
guided_token() {
    case "$(classify "$1")" in
        scratchpad-only|both) printf 'guided' ;;
        *) classify "$1" ;;
    esac
}
assert_eq "C-12-unresolvable-inner" "guided" "$(guided_token "$OUT")"

# --- C-13..C-15: SSOT entries are untrusted input (C7) -----------------------
# branchA pastes the matched entry into `bash "$AGENTS_CONFIG_DIR/<entry>"`, a template
# only sound for plain, contained, relative entries. An absolute or traversing entry
# makes the guidance name a DIFFERENT file than the SSOT list sanctions, so none of
# them may reach branchA.
RECIPE='Reissue it as a single bare command:'

# A POSIX-style absolute entry ("/tmp/evil") is spelled entirely from the ENTRY_RE
# charset, so the whole list survives the gate and the entry is dropped INDIVIDUALLY by
# isContainedEntry (path.resolve puts it outside configDir on POSIX and Windows alike).
# No entry matches, so the remedy falls to branch b.
ABS_CFG="$TMPDIR_C/cfg-abs-entry"
mkdir -p "$ABS_CFG/install" "$ABS_CFG/bin"
printf '#!/usr/bin/env bash\necho ok\n' >"$ABS_CFG/bin/good"
printf '/tmp/evil\nbin/good\n' >"$ABS_CFG/install/settings-allow-commands.txt"
OUT="$(run_remedy "$ABS_CFG" 'bash /tmp/evil')"
assert_eq "C-13a-absolute-entry-no-bare-recipe" "no" "$(has_substr "$OUT" "$RECIPE")"
assert_eq "C-13b-absolute-entry-falls-back" "scratchpad-only" "$(classify "$OUT")"
# Positive control for the PER-ENTRY drop: the contained sibling sharing the list with
# "/tmp/evil" still reaches branch a, so the rejection above is that one entry and not
# a silently emptied list.
OUT="$(run_remedy "$ABS_CFG" 'bash "$AGENTS_CONFIG_DIR/bin/good"')"
assert_eq "C-13c-contained-sibling-still-matches" "bare-only" "$(classify "$OUT")"
assert_eq "C-13d-contained-sibling-names-itself" "yes" "$(has_substr "$OUT" "bin/good")"

# A DRIVE-LETTER absolute entry is the other failure mode: the `:` is outside ENTRY_RE's
# charset, so the gate discards the WHOLE list (fail-safe) before containment is ever
# consulted, and the remedy degrades to the generic branch. The literal is hard-coded
# rather than derived from the host so the branch under test is the same everywhere —
# a POSIX-shaped temp path would take the C-13 route instead.
WABS_CFG="$TMPDIR_C/cfg-winabs-entry"
mkdir -p "$WABS_CFG/install" "$WABS_CFG/bin"
printf '#!/usr/bin/env bash\necho ok\n' >"$WABS_CFG/bin/good"
printf 'C:/tmp/evil\nbin/good\n' >"$WABS_CFG/install/settings-allow-commands.txt"
OUT="$(run_remedy "$WABS_CFG" 'bash C:/tmp/evil')"
assert_eq "C-14a-host-absolute-entry-no-bare-recipe" "no" "$(has_substr "$OUT" "$RECIPE")"
assert_eq "C-14b-host-absolute-entry-degrades" "both" "$(classify "$OUT")"
# Contrast control against C-13c: the SAME contained sibling, on a list carrying an
# off-charset entry, loses its recipe too. That is what "whole-list discard" means, and
# it is the observable that separates this branch from C-13's per-entry drop.
OUT="$(run_remedy "$WABS_CFG" 'bash "$AGENTS_CONFIG_DIR/bin/good"')"
assert_eq "C-14c-whole-list-discarded-sibling-degrades" "both" "$(classify "$OUT")"

# ENTRY_RE is a charset gate that admits "..", so isContainedEntry is what keeps a
# traversing entry out of branchA: "../evilhome/evil" resolves outside configDir and
# is dropped per-entry, leaving no match and degrading to branch b.
TRAV_CFG="$TMPDIR_C/cfg-traversal-entry"
mkdir -p "$TRAV_CFG/install" "$TMPDIR_C/evilhome"
printf '#!/usr/bin/env bash\necho x\n' >"$TMPDIR_C/evilhome/evil"
EVILHOME="$(cd "$TMPDIR_C/evilhome" && pwd)"
command -v cygpath >/dev/null 2>&1 && EVILHOME="$(cygpath -m "$TMPDIR_C/evilhome")"
mkdir -p "$TRAV_CFG/bin"
printf '#!/usr/bin/env bash\necho ok\n' >"$TRAV_CFG/bin/good"
printf '../evilhome/evil\nbin/good\n' >"$TRAV_CFG/install/settings-allow-commands.txt"
OUT="$(run_remedy "$TRAV_CFG" "bash $EVILHOME/evil")"
assert_eq "C-15a-traversal-entry-no-bare-recipe" "no" "$(has_substr "$OUT" "$RECIPE")"
assert_eq "C-15b-traversal-entry-degrades" "scratchpad-only" "$(classify "$OUT")"
# Containment is filtered PER ENTRY, not by discarding the whole list: the contained
# sibling on the very same list must still resolve to branch a.
OUT="$(run_remedy "$TRAV_CFG" 'bash "$AGENTS_CONFIG_DIR/bin/good"')"
assert_eq "C-15c-contained-sibling-still-matches" "bare-only" "$(classify "$OUT")"

# --- C-16: the recipe reproduces the invocation, arguments included (C1) ------
# branchA renders the hit's remaining argv after the entry, so the author is told to
# reissue the command that was actually blocked. Only bare shell words the shell
# cannot rewrite (SAFE_ARG_RE) may be pasted verbatim; anything else degrades.
OUT="$(run_remedy "$CONFIG_REAL" 'bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --target outline --advance')"
assert_eq "C-16a-registered-with-safe-args-branch-a" "bare-only" "$(classify "$OUT")"
assert_eq "C-16b-recipe-keeps-arguments" "yes" "$(has_substr "$OUT" "--target outline --advance")"
# An argument carrying an expansion would be re-expanded (or mis-expanded) if pasted,
# so the whole invocation degrades rather than handing back a misleading recipe.
OUT="$(run_remedy "$CONFIG_REAL" 'bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --target outline --advance')"
assert_eq "C-16c-unsafe-arg-degrades" "scratchpad-only" "$(classify "$OUT")"
assert_eq "C-16d-unsafe-arg-no-bare-recipe" "no" "$(has_substr "$OUT" "$RECIPE")"

# --- C-17: a compound inner command resolves to no single entry point ---------
# resolveInner requires ir.segments.length === 1, so "entry || fallback" no longer
# collapses to segments[0] and hands back a recipe for one half of what was run.
OUT="$(run_remedy "$CONFIG_REAL" 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" || printf fallback')"
assert_eq "C-17a-compound-or-degrades" "scratchpad-only" "$(classify "$OUT")"
assert_eq "C-17b-compound-or-no-bare-recipe" "no" "$(has_substr "$OUT" "$RECIPE")"
assert_eq "C-17c-fallback-branch-not-echoed" "no" "$(has_substr "$OUT" "fallback")"
# A `;` compound degrades the same way (CPR-ORTH: the separator is not the point).
OUT="$(run_remedy "$CONFIG_REAL" 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"; printf tail')"
assert_eq "C-17d-compound-semicolon-degrades" "scratchpad-only" "$(classify "$OUT")"
# Control: the single-segment form of the very same entry still reaches branch a, so
# the degradation above is the compound and not the entry.
OUT="$(run_remedy "$CONFIG_REAL" 'bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"')"
assert_eq "C-17e-single-segment-still-branch-a" "bare-only" "$(classify "$OUT")"

# --- C-18: an SSOT entry that is a SYMLINK out of the config tree -------------
# C-15 covers a lexically traversing entry. Here the entry is lexically impeccable
# ("bin/linked") and the traversal lives in the filesystem instead. isContainedEntry
# realpaths the entry rather than relying on path.resolve alone, so the link is judged
# NOT contained and the remedy degrades instead of handing back a bare recipe naming a
# path whose target is outside the sanctioned tree.
SYM_CFG="$TMPDIR_C/cfg-symlink-entry"
mkdir -p "$SYM_CFG/install" "$SYM_CFG/bin" "$TMPDIR_C/outside-exec"
printf '#!/usr/bin/env bash\necho pwned\n' >"$TMPDIR_C/outside-exec/evil"
printf '#!/usr/bin/env bash\necho ok\n' >"$SYM_CFG/bin/good"
printf 'bin/linked\nbin/good\n' >"$SYM_CFG/install/settings-allow-commands.txt"
if node "$(cd "$(dirname "$0")" && pwd)/mk-symlink.js" "$TMPDIR_C/outside-exec/evil" "$SYM_CFG/bin/linked" file; then
    # The containment verdict now holds through the link: no bare recipe is printed and
    # the remedy degrades to the scratchpad-only branch.
    # TL3 gap: whether an author actually follows the printed recipe.
    OUT="$(run_remedy "$SYM_CFG" 'bash "$AGENTS_CONFIG_DIR/bin/linked"')"
    assert_eq "C-18a-symlinked-entry-no-bare-recipe" "no" "$(has_substr "$OUT" "$RECIPE")"
    assert_eq "C-18b-symlinked-entry-degrades" "scratchpad-only" "$(classify "$OUT")"
    assert_eq "C-18c-escape-target-untouched" "echo pwned" "$(tail -n 1 "$TMPDIR_C/outside-exec/evil")"
    # Paired control: a genuinely contained sibling on the same list gets the normal
    # recipe, so a later fix must keep answering this row exactly as it does now.
    OUT="$(run_remedy "$SYM_CFG" 'bash "$AGENTS_CONFIG_DIR/bin/good"')"
    assert_eq "C-18d-contained-entry-normal-recipe" "bare-only" "$(classify "$OUT")"
    assert_eq "C-18e-contained-entry-names-itself" "yes" "$(has_substr "$OUT" "bin/good")"
else
    # SKIPPED: C-18 (5 cases) when the platform refuses symlink creation.
    # Because: the traversal under test lives in the filesystem, so only a real link
    # exercises isContainedEntry's realpath step; a plain file would test nothing.
    # L3 gap: a symlinked SSOT entry stays unverified on such hosts. The lexical
    # traversal it pairs with is still covered by C-15, and C-18 does run on CI (Linux)
    # and on any Windows host with Developer Mode or admin.
    echo "SKIP: C-18 — platform denied symlink creation (no Developer Mode / admin)"
fi

# Unusable-allowlist degradation (C-19) lives in the sibling part7-remedy-ssot-edges.sh
# (rules/coding/file-split.md Pattern A: this file is at the 300-line WARN threshold).

echo ""
echo "Section C: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
